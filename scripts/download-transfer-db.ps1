#Requires -Version 5.1

param(
    [Parameter(Mandatory=$true)]
    [string]$source_role_arn,
    
    [Parameter(Mandatory=$true)]
    [string]$source_bucket,
    
    [Parameter(Mandatory=$true)]
    [string]$source_prefix,
    
    [Parameter(Mandatory=$true)]
    [string]$dest_role_arn,
    
    [Parameter(Mandatory=$true)]
    [string]$dest_bucket,
    
    [Parameter(Mandatory=$true)]
    [string]$dest_prefix,
    
    [string]$remote_server,
    [string]$username,
    [string]$password,
    [string]$remote_local_dir = "C:\YOUR_REMOTE-DIR\",
    [string]$local_dir = "C:\YOUR_REMOTE-DIR\",
    [string]$region = "us-east-1",
    [switch]$no_cleanup
)

# Configure logging
$logFile = Join-Path $PSScriptRoot "s3-cross-account-copy.log"
$ErrorActionPreference = "Stop"

function Write-Log {
    param([string]$Message, [string]$Level = "INFO")
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $logMessage = "$timestamp - $Level - $Message"
    Write-Host $logMessage
    Add-Content -Path $logFile -Value $logMessage
}

function Invoke-AWSCommand {
    param(
        [string]$Command,
        [hashtable]$EnvVars = @{}
    )
    
    $originalEnvVars = @{}
    foreach ($key in $EnvVars.Keys) {
        $originalEnvVars[$key] = [Environment]::GetEnvironmentVariable($key)
        [Environment]::SetEnvironmentVariable($key, $EnvVars[$key])
    }
    
    try {
        $output = Invoke-Expression $Command 2>&1
        $exitCode = $LASTEXITCODE
        
        if ($exitCode -ne 0) {
            throw "Command failed with exit code $exitCode. Output: $output"
        }
        
        return $output
    }
    finally {
        foreach ($key in $originalEnvVars.Keys) {
            [Environment]::SetEnvironmentVariable($key, $originalEnvVars[$key])
        }
    }
}

function Assume-Role {
    param([string]$RoleArn, [string]$SessionName = "S3Session")
    
    try {
        Write-Log "Assuming IAM role: $RoleArn"
        
        $assumeRoleCmd = "aws sts assume-role --role-arn `"$RoleArn`" --role-session-name `"$SessionName`""
        $result = Invoke-AWSCommand -Command $assumeRoleCmd
        
        $assumedRole = $result | ConvertFrom-Json
        $credentials = @{
            AccessKeyId = $assumedRole.Credentials.AccessKeyId
            SecretAccessKey = $assumedRole.Credentials.SecretAccessKey
            SessionToken = $assumedRole.Credentials.SessionToken
            Expiration = $assumedRole.Credentials.Expiration
        }
        
        Write-Log "Successfully assumed IAM role"
        return $credentials
    }
    catch {
        Write-Log "Failed to assume role $RoleArn : $($_.Exception.Message)" -Level "ERROR"
        throw
    }
}

function Download-LastModifiedObject {
    param(
        [string]$RoleArn,
        [string]$BucketName,
        [string]$Prefix,
        [string]$LocalDir
    )
    
    try {
        Write-Log "Starting process to download last modified object from s3://$BucketName/$Prefix"
        
        # Validate inputs
        if ([string]::IsNullOrEmpty($RoleArn) -or [string]::IsNullOrEmpty($BucketName) -or 
            [string]::IsNullOrEmpty($Prefix) -or [string]::IsNullOrEmpty($LocalDir)) {
            throw "Missing required parameters: role_arn, bucket_name, prefix, and local_dir are all required"
        }
        
        if (-not $RoleArn.StartsWith('arn:aws:iam::')) {
            throw "Invalid role ARN format: $RoleArn"
        }
        
        # Create local directory if it doesn't exist
        Write-Log "Ensuring local directory exists: $LocalDir"
        if (-not (Test-Path $LocalDir)) {
            New-Item -ItemType Directory -Path $LocalDir -Force | Out-Null
        }
        
        if (-not (Test-Path $LocalDir -PathType Container)) {
            throw "Failed to create or access directory: $LocalDir"
        }
        
        # Assume the IAM role
        $credentials = Assume-Role -RoleArn $RoleArn -SessionName "S3DownloadSession"
        
        # List objects and find the latest one using AWS CLI
        Write-Log "Listing objects in s3://$BucketName/$Prefix"
        
        $envVars = @{
            AWS_ACCESS_KEY_ID = $credentials.AccessKeyId
            AWS_SECRET_ACCESS_KEY = $credentials.SecretAccessKey
            AWS_SESSION_TOKEN = $credentials.SessionToken
        }
        
        $listCmd = "aws s3api list-objects-v2 --bucket `"$BucketName`" --prefix `"$Prefix`" --query 'sort_by(Contents, &LastModified)[-1]'"
        $latestObjectJson = Invoke-AWSCommand -Command $listCmd -EnvVars $envVars
        
        if ([string]::IsNullOrEmpty($latestObjectJson) -or $latestObjectJson -eq "null") {
            throw "No objects found in prefix: s3://$BucketName/$Prefix"
        }
        
        $latestObject = $latestObjectJson | ConvertFrom-Json
        
        Write-Log "Latest object: $($latestObject.Key)"
        Write-Log "Last modified: $($latestObject.LastModified), Size: $($latestObject.Size) bytes"
        
        $objectKey = $latestObject.Key
        $objectName = [System.IO.Path]::GetFileName($objectKey)
        $localPath = Join-Path $LocalDir $objectName
        
        # Check if file already exists
        if (Test-Path $localPath) {
            Write-Log "File already exists at $localPath, it will be overwritten" -Level "WARNING"
        }
        
        # Download the object using AWS CLI
        Write-Log "Downloading $objectKey to $localPath..."
        $downloadCmd = "aws s3 cp `"s3://$BucketName/$objectKey`" `"$localPath`""
        Invoke-AWSCommand -Command $downloadCmd -EnvVars $envVars
        
        # Verify download
        if (Test-Path $localPath) {
            $fileSize = (Get-Item $localPath).Length
            Write-Log "Successfully downloaded: $localPath (Size: $fileSize bytes)"
            return $localPath, $objectName
        }
        else {
            throw "Download failed: File not found at $localPath"
        }
    }
    catch {
        Write-Log "Download error: $($_.Exception.Message)" -Level "ERROR"
        throw
    }
}

function Upload-ToDestinationS3 {
    param(
        [string]$RoleArn,
        [string]$BucketName,
        [string]$Prefix,
        [string]$LocalFilePath
    )
    
    try {
        $credentials = Assume-Role -RoleArn $RoleArn -SessionName "S3UploadSession"
        
        # Extract filename and construct destination key
        $filename = [System.IO.Path]::GetFileName($LocalFilePath)
        $destinationKey = if ($Prefix.TrimEnd('/')) { "$($Prefix.TrimEnd('/'))/$filename" } else { $filename }
        
        # Upload the file using AWS CLI
        Write-Log "Uploading $LocalFilePath to s3://$BucketName/$destinationKey"
        
        $envVars = @{
            AWS_ACCESS_KEY_ID = $credentials.AccessKeyId
            AWS_SECRET_ACCESS_KEY = $credentials.SecretAccessKey
            AWS_SESSION_TOKEN = $credentials.SessionToken
        }
        
        $uploadCmd = "aws s3 cp `"$LocalFilePath`" `"s3://$BucketName/$destinationKey`""
        Invoke-AWSCommand -Command $uploadCmd -EnvVars $envVars
        
        Write-Log "Successfully uploaded to s3://$BucketName/$destinationKey"
        return $destinationKey
    }
    catch {
        Write-Log "AWS API error during upload: $($_.Exception.Message)" -Level "ERROR"
        throw
    }
}

function Check-AwsCliOnRemote {
    param(
        [string]$ServerIp,
        [string]$Username,
        [string]$Password
    )
    
    try {
        Write-Log "Checking AWS CLI on remote server: $ServerIp"
        
        $session = New-PSSession -ComputerName $ServerIp -Credential (New-Object System.Management.Automation.PSCredential($Username, (ConvertTo-SecureString $Password -AsPlainText -Force)))
        
        $result = Invoke-Command -Session $session -ScriptBlock {
            try {
                # Check AWS CLI version
                $version = aws --version 2>&1
                if ($LASTEXITCODE -eq 0) {
                    return @{ Success = $true; Version = $version; Message = "AWS CLI found" }
                }
                
                # Check if AWS CLI is in PATH
                $whereResult = where aws 2>&1
                if ($LASTEXITCODE -eq 0 -and $whereResult -like "*aws.exe*") {
                    return @{ Success = $true; Version = "Found at: $whereResult"; Message = "AWS CLI found in PATH" }
                }
                
                # Check common installation locations
                $commonPaths = @(
                    "C:\Program Files\Amazon\AWSCLI\aws.exe",
                    "C:\Program Files\Amazon\AWSCLIV2\aws.exe",
                    "C:\Program Files (x86)\Amazon\AWSCLI\aws.exe"
                )
                
                foreach ($path in $commonPaths) {
                    if (Test-Path $path) {
                        return @{ Success = $true; Version = "Found at: $path"; Message = "AWS CLI found" }
                    }
                }
                
                return @{ Success = $false; Message = "AWS CLI not found" }
            }
            catch {
                return @{ Success = $false; Message = $_.Exception.Message }
            }
        }
        
        Remove-PSSession $session
        
        if ($result.Success) {
            Write-Log "AWS CLI found on remote server: $($result.Version)"
            return $true
        }
        else {
            Write-Log "AWS CLI not found on remote server: $($result.Message)" -Level "ERROR"
            return $false
        }
    }
    catch {
        Write-Log "Could not check AWS CLI on remote server: $($_.Exception.Message)" -Level "WARNING"
        return $false
    }
}

function Execute-RemoteDownload {
    param(
        [string]$ServerIp,
        [string]$Username,
        [string]$Password,
        [string]$DestRoleArn,
        [string]$DestBucket,
        [string]$DestPrefix,
        [string]$RemoteLocalDir,
        [string]$Filename
    )
    
    try {
        Write-Log "Connecting to remote server: $ServerIp"
        
        # Assume role to get temporary credentials
        $credentials = Assume-Role -RoleArn $DestRoleArn -SessionName "RemoteCLISession"
        
        $cleanRemoteDir = $RemoteLocalDir.TrimEnd('\')
        $s3SourcePath = "s3://$DestBucket/$($DestPrefix.TrimEnd('/'))/$Filename"
        $localDestPath = "$cleanRemoteDir\$Filename"
        
        Write-Log "Remote Local Directory: $RemoteLocalDir"
        Write-Log "Clean Remote Directory: $cleanRemoteDir"
        Write-Log "S3 Source Path: $s3SourcePath"
        Write-Log "Local Destination Path: $localDestPath"
        
        # Create PowerShell session
        $session = New-PSSession -ComputerName $ServerIp -Credential (New-Object System.Management.Automation.PSCredential($Username, (ConvertTo-SecureString $Password -AsPlainText -Force)))
        
        $result = Invoke-Command -Session $session -ScriptBlock {
            param($AccessKey, $SecretKey, $SessionToken, $S3SourcePath, $LocalDestPath, $CleanRemoteDir)
            
            try {
                # Set environment variables
                $env:AWS_ACCESS_KEY_ID = $AccessKey
                $env:AWS_SECRET_ACCESS_KEY = $SecretKey
                $env:AWS_SESSION_TOKEN = $SessionToken
                $env:AWS_DEFAULT_REGION = "us-east-1"
                
                Write-Output "=== AWS CLI DOWNLOAD SCRIPT ==="
                Write-Output "Date: $(Get-Date)"
                Write-Output "Remote Directory: $CleanRemoteDir"
                Write-Output "Filename: $(Split-Path $LocalDestPath -Leaf)"
                Write-Output "S3 Source: $S3SourcePath"
                Write-Output ""
                
                Write-Output "Checking AWS CLI version..."
                aws --version
                Write-Output ""
                
                Write-Output "Creating directory if it doesn't exist..."
                if (-not (Test-Path $CleanRemoteDir)) {
                    New-Item -ItemType Directory -Path $CleanRemoteDir -Force | Out-Null
                }
                Write-Output ""
                
                Write-Output "Testing AWS credentials..."
                aws sts get-caller-identity
                Write-Output ""
                
                Write-Output "Downloading file from S3..."
                aws s3 cp "$S3SourcePath" "$LocalDestPath" --cli-connect-timeout 300 --cli-read-timeout 600
                
                if ($LASTEXITCODE -eq 0) {
                    Write-Output "SUCCESS: AWS CLI reported download success"
                    Write-Output "Checking if file actually exists..."
                    
                    if (Test-Path $LocalDestPath) {
                        Write-Output "File verification: OK - File exists at destination"
                        Write-Output ""
                        
                        Write-Output "Deleting file from S3 bucket..."
                        aws s3 rm "$S3SourcePath"
                        
                        if ($LASTEXITCODE -eq 0) {
                            Write-Output "SUCCESS: File deleted from S3 bucket"
                            return @{ Success = $true; Message = "Download and deletion successful" }
                        }
                        else {
                            Write-Output "WARNING: File downloaded but could not be deleted from S3"
                            return @{ Success = $true; Message = "Download successful but deletion failed" }
                        }
                    }
                    else {
                        Write-Output "ERROR: AWS CLI reported success but file not found at $LocalDestPath"
                        return @{ Success = $false; Message = "File not found after download" }
                    }
                }
                else {
                    Write-Output "ERROR: AWS CLI download failed with error code $LASTEXITCODE"
                    return @{ Success = $false; Message = "AWS CLI download failed" }
                }
            }
            catch {
                return @{ Success = $false; Message = $_.Exception.Message }
            }
        } -ArgumentList $credentials.AccessKeyId, $credentials.SecretAccessKey, $credentials.SessionToken, $s3SourcePath, $localDestPath, $cleanRemoteDir
        
        Remove-PSSession $session
        
        # Final verification
        $verifySession = New-PSSession -ComputerName $ServerIp -Credential (New-Object System.Management.Automation.PSCredential($Username, (ConvertTo-SecureString $Password -AsPlainText -Force)))
        $verifyResult = Invoke-Command -Session $verifySession -ScriptBlock {
            param($LocalDestPath)
            Test-Path $LocalDestPath
        } -ArgumentList $localDestPath
        Remove-PSSession $verifySession
        
        if ($verifyResult) {
            Write-Log "Remote download completed successfully!"
            Write-Log "File verified: $localDestPath"
            return $true
        }
        else {
            throw "Final verification failed. File not found at $localDestPath"
        }
    }
    catch {
        Write-Log "Remote execution error: $($_.Exception.Message)" -Level "ERROR"
        throw
    }
}

function Copy-S3ObjectAcrossAccounts {
    param(
        [string]$SourceRoleArn,
        [string]$SourceBucket,
        [string]$SourcePrefix,
        [string]$DestRoleArn,
        [string]$DestBucket,
        [string]$DestPrefix,
        [string]$LocalDir,
        [string]$RemoteServer,
        [string]$Username,
        [string]$Password,
        [string]$RemoteLocalDir,
        [bool]$Cleanup
    )
    
    $localFilePath = $null
    try {
        # Step 1: Download from source bucket to local machine
        Write-Log "Step 1: Downloading from source bucket..."
        $localFilePath, $filename = Download-LastModifiedObject -RoleArn $SourceRoleArn -BucketName $SourceBucket -Prefix $SourcePrefix -LocalDir $LocalDir
        
        # Step 2: Upload to destination bucket from local machine
        Write-Log "Step 2: Uploading to destination bucket..."
        $destinationKey = Upload-ToDestinationS3 -RoleArn $DestRoleArn -BucketName $DestBucket -Prefix $DestPrefix -LocalFilePath $localFilePath
        
        # Step 3: If remote server specified, download from destination bucket to remote server
        $remoteSuccess = $null
        if ($RemoteServer -and $Username -and $Password -and $RemoteLocalDir) {
            Write-Log "Step 3: Initiating remote download..."
            $awsCliAvailable = Check-AwsCliOnRemote -ServerIp $RemoteServer -Username $Username -Password $Password
            
            if ($awsCliAvailable) {
                Write-Log "AWS CLI available on remote server, proceeding with remote download..."
                $remoteSuccess = Execute-RemoteDownload -ServerIp $RemoteServer -Username $Username -Password $Password `
                    -DestRoleArn $DestRoleArn -DestBucket $DestBucket -DestPrefix $DestPrefix `
                    -RemoteLocalDir $RemoteLocalDir -Filename $filename
            }
            else {
                throw "AWS CLI not found on remote server. Please install AWS CLI on the remote machine."
            }
        }
        
        # Step 4: Cleanup if requested
        if ($Cleanup -and $localFilePath -and (Test-Path $localFilePath)) {
            Write-Log "Cleaning up local file: $localFilePath"
            Remove-Item $localFilePath -Force
        }
        
        return @{
            Success = $true
            SourceFile = $localFilePath
            DestinationBucket = $DestBucket
            DestinationKey = $destinationKey
            LocalFileCleaned = $Cleanup
            RemoteDownloadSuccess = $remoteSuccess
            Filename = $filename
        }
    }
    catch {
        Write-Log "Cross-account copy failed: $($_.Exception.Message)" -Level "ERROR"
        
        # Don't cleanup on error for debugging
        if ($localFilePath -and (Test-Path $localFilePath)) {
            Write-Log "Local file retained for debugging: $localFilePath"
        }
        
        return @{
            Success = $false
            Error = $_.Exception.Message
            SourceFile = $localFilePath
            RemoteDownloadSuccess = $false
        }
    }
}

# Main execution
try {
    Write-Log "=" * 80
    Write-Log "Starting S3 Cross-Account Copy Process with Remote Download (AWS CLI)"
    Write-Log "=" * 80
    
    # Source info
    Write-Log "SOURCE:"
    Write-Log "  Role ARN: $source_role_arn"
    Write-Log "  Bucket: $source_bucket"
    Write-Log "  Prefix: $source_prefix"
    
    # Destination info
    Write-Log "DESTINATION:"
    Write-Log "  Role ARN: $dest_role_arn"
    Write-Log "  Bucket: $dest_bucket"
    Write-Log "  Prefix: $dest_prefix"
    
    # Remote info if provided
    if ($remote_server) {
        Write-Log "REMOTE SERVER DOWNLOAD:"
        Write-Log "  Server: $remote_server"
        Write-Log "  Username: $username"
        Write-Log "  Remote Directory: $remote_local_dir"
        Write-Log "  Method: AWS CLI with environment variables"
    }
    
    # Common info
    Write-Log "LOCAL TEMP DIR: $local_dir"
    Write-Log "REGION: $region"
    Write-Log "CLEANUP: $(-not $no_cleanup)"
    Write-Log "=" * 80
    
    # Set AWS region if provided
    if ($region) {
        $env:AWS_DEFAULT_REGION = $region.Trim()
    }
    
    # Execute the complete process
    $result = Copy-S3ObjectAcrossAccounts -SourceRoleArn $source_role_arn -SourceBucket $source_bucket -SourcePrefix $source_prefix `
        -DestRoleArn $dest_role_arn -DestBucket $dest_bucket -DestPrefix $dest_prefix `
        -LocalDir $local_dir -RemoteServer $remote_server -Username $username `
        -Password $password -RemoteLocalDir $remote_local_dir -Cleanup (-not $no_cleanup)
    
    Write-Log "=" * 80
    if ($result.Success) {
        Write-Log "Complete process finished successfully!"
        Write-Log "File: $($result.Filename)"
        Write-Log "Destination: s3://$($result.DestinationBucket)/$($result.DestinationKey)"
        
        if ($remote_server) {
            if ($result.RemoteDownloadSuccess) {
                Write-Log "Remote download successful to: $remote_local_dir"
            }
            else {
                Write-Log "Remote download was not attempted or failed" -Level "WARNING"
            }
        }
        
        if ($result.LocalFileCleaned) {
            Write-Log "Local temporary file cleaned up"
        }
    }
    else {
        Write-Log "Process failed: $($result.Error)" -Level "ERROR"
    }
    Write-Log "=" * 80
    
    return $result
}
catch {
    Write-Log "Process failed: $($_.Exception.Message)" -Level "ERROR"
    return @{ Success = $false; Error = $_.Exception.Message }
}

# Final output
if ($result -and $result.Success) {
    Write-Host "`nSuccess! Complete process finished successfully!" -ForegroundColor Green
    Write-Host "File: $($result.Filename)" -ForegroundColor Green
    Write-Host "Destination: s3://$($result.DestinationBucket)/$($result.DestinationKey)" -ForegroundColor Green
    if ($result.RemoteDownloadSuccess) {
        Write-Host "Remote download completed" -ForegroundColor Green
    }
    exit 0
}
else {
    $errorMsg = if ($result) { $result.Error } else { "Process failed" }
    Write-Host "`nProcess failed: $errorMsg" -ForegroundColor Red
    exit 1
}