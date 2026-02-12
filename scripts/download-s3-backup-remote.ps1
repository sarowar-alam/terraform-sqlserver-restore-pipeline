param (
    [string]$RemoteServer,      # Remote server IP
    [string]$Username,          # Remote username
    [string]$S3BucketName,      # S3 bucket name
    [string]$S3Prefix,          # S3 prefix/folder path
    [string]$DBName,            # Database name to match in filename
    [string]$RemoteDirectory    # Remote directory to download to
)


try {

    # Convert plain text password to SecureString (handles special characters)
    Write-Host "[INFO] Converting password to SecureString" -ForegroundColor Green
    $passwordFilePath = "sql-backup-restore-automation\password.txt"
    if (-not (Test-Path $passwordFilePath)) {
        throw "Password file not found at: $passwordFilePath"
    }
    $fileContent = Get-Content $passwordFilePath -Raw
    $password = ($fileContent -replace '[^\x00-\x7F]', '').Trim()
    if ([string]::IsNullOrEmpty($password)) {
        throw "Password file contains no valid ASCII characters after cleaning"
    }
    $securePassword = ConvertTo-SecureString $password -AsPlainText -Force
    Write-Host "Password successfully converted to secure string Where UserName is $Username" -ForegroundColor Green   

    $Credential = New-Object System.Management.Automation.PSCredential ($Username, $securePassword)
 
    Write-Host "[INFO] Connecting to remote server: $RemoteServer" -ForegroundColor Green
    Write-Host "[INFO] Target S3 Bucket: $S3BucketName" -ForegroundColor Green
    Write-Host "[INFO] S3 Prefix: $S3Prefix" -ForegroundColor Green
    Write-Host "[INFO] Database Name Filter: $DBName" -ForegroundColor Green
    Write-Host "[INFO] Remote Download Directory: $RemoteDirectory" -ForegroundColor Green

    # Execute the remote script directly without using Invoke-Expression
    Write-Host "[INFO] Executing remote S3 download operation via WinRM..." -ForegroundColor Cyan

    #######
    # Retry configuration
    $maxRetries = 15
    $retryDelay = 30
    $retryCount = 0
    $connected = $false

    do {
        try {
            $retryCount++
            Write-Host "[INFO] Attempting WinRM connection (Attempt $retryCount/$maxRetries)..." -ForegroundColor Yellow
            
            $result = Invoke-Command -ComputerName $RemoteServer -Credential $Credential -ScriptBlock {
                param ($S3BucketName, $S3Prefix, $DBName, $RemoteDirectory)
                
                $ErrorActionPreference = 'Stop'
                $ProgressPreference = 'SilentlyContinue'
                
                # Function for consistent logging
                function Write-Log {
                    param([string]$Message, [string]$Level = "INFO")
                    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
                    $formattedMessage = "[$timestamp] [$Level] $Message"
                    
                    switch ($Level) {
                        "ERROR" { Write-Host $formattedMessage -ForegroundColor Red }
                        "WARN"  { Write-Host $formattedMessage -ForegroundColor Yellow }
                        "INFO"  { Write-Host $formattedMessage -ForegroundColor Green }
                        "DEBUG" { Write-Host $formattedMessage -ForegroundColor Gray }
                        default { Write-Host $formattedMessage -ForegroundColor White }
                    }
                }

                try {
                    Write-Log "Starting S3 backup download process"

                    # Create remote directory if it doesn't exist
                    Write-Log "Ensuring remote directory exists: $RemoteDirectory"
                    if (-not (Test-Path $RemoteDirectory)) {
                        try {
                            New-Item -ItemType Directory -Path $RemoteDirectory -Force | Out-Null
                            Write-Log "Created directory: $RemoteDirectory" "INFO"
                        } catch {
                            $errorMsg = $_.Exception.Message
                            throw ("Failed to create directory " + $RemoteDirectory + ": " + $errorMsg)
                        }
                    }

                    # List objects in S3 bucket with prefix
                    Write-Log "Listing objects in S3 bucket: $S3BucketName with prefix: $S3Prefix"
                    
                    $listCommand = "aws s3api list-objects-v2 --bucket $S3BucketName --prefix $S3Prefix --query 'Contents[].{Key:Key, Size:Size, LastModified:LastModified}' --output json"
                    Write-Log "Executing: $listCommand" "DEBUG"
                    
                    $s3ObjectsJson = Invoke-Expression $listCommand 2>&1
                    if ($LASTEXITCODE -ne 0) {
                        throw "Failed to list S3 objects. AWS CLI error: $s3ObjectsJson"
                    }

                    if ([string]::IsNullOrEmpty($s3ObjectsJson) -or $s3ObjectsJson -eq "null") {
                        throw "No objects found in S3 bucket $S3BucketName with prefix $S3Prefix"
                    }

                    $s3Objects = $s3ObjectsJson | ConvertFrom-Json
                    Write-Log "Found $($s3Objects.Count) objects in S3 bucket" "INFO"

                    # Filter objects that start with the DB name
                    Write-Log "Filtering objects starting with DB name: $DBName"
                    $filteredObjects = $s3Objects | Where-Object {
                        $_.Key -match "$($DBName)[^/]*$" -and
                        $_.Key -notmatch "/$"  # Exclude directories
                    }

                    if (-not $filteredObjects -or $filteredObjects.Count -eq 0) {
                        throw "No files found starting with DB name: $DBName in the specified S3 location"
                    }

                    Write-Log "Found $($filteredObjects.Count) files matching DB name pattern" "INFO"

                    # Sort by last modified date (newest first) and get the latest
                    $latestBackup = $filteredObjects | Sort-Object LastModified -Descending | Select-Object -First 1
                    
                    Write-Log "Latest backup file: $($latestBackup.Key)" "INFO"
                    Write-Log "Last modified: $($latestBackup.LastModified)" "INFO"
                    Write-Log "Size: $([math]::Round($latestBackup.Size/1MB, 2)) MB" "INFO"

                    # Extract filename from S3 key
                    $fileName = [System.IO.Path]::GetFileName($latestBackup.Key)
                    $localFilePath = Join-Path -Path $RemoteDirectory -ChildPath $fileName

                    # Check if file already exists and compare sizes
                    if (Test-Path $localFilePath) {
                        $existingFile = Get-Item $localFilePath
                        if ($existingFile.Length -eq $latestBackup.Size) {
                            Write-Log "File already exists with same size. Skipping download." "WARN"
                            return $localFilePath
                        } else {
                            Write-Log "File exists but sizes differ. Re-downloading..." "WARN"
                            Remove-Item $localFilePath -Force
                        }
                    }

                    # Download the file
                    Write-Log "Downloading file from S3..." "INFO"
                    
                    $downloadCommand = "aws s3 cp s3://$S3BucketName/$($latestBackup.Key) $localFilePath"
                    Write-Log "Executing: $downloadCommand" "DEBUG"
                    
                    $downloadResult = Invoke-Expression $downloadCommand 2>&1
                    if ($LASTEXITCODE -ne 0) {
                        throw "S3 download failed. Error: $downloadResult"
                    }

                    # Verify download
                    if (-not (Test-Path $localFilePath)) {
                        throw "Download completed but file not found at expected location: $localFilePath"
                    }

                    $downloadedFile = Get-Item $localFilePath
                    if ($downloadedFile.Length -ne $latestBackup.Size) {
                        throw "Download size mismatch. Expected: $($latestBackup.Size) bytes, Actual: $($downloadedFile.Length) bytes"
                    }

                    Write-Log "Download completed successfully!" "INFO"
                    Write-Log "File size: $([math]::Round($downloadedFile.Length/1MB, 2)) MB" "INFO"
                    Write-Log "Location: $localFilePath" "INFO"

                    # Return the downloaded file path
                    $localFilePath

                } catch {
                    $errorMsg = $_.Exception.Message
                    Write-Log "Error in remote execution: $errorMsg" "ERROR"
                    Write-Log "Error details: $($_.ScriptStackTrace)" "DEBUG"
                    throw
                }
            } -ArgumentList $S3BucketName, $S3Prefix, $DBName, $RemoteDirectory
            
            $connected = $true
            Write-Host "[SUCCESS] WinRM connection established on attempt $retryCount" -ForegroundColor Green
            
        } catch [System.Management.Automation.Remoting.PSRemotingTransportException] {
            Write-Host "[WARN] WinRM connection failed on attempt $retryCount $($_.Exception.Message)" -ForegroundColor Yellow
            
            if ($retryCount -lt $maxRetries) {
                Write-Host "[INFO] Waiting $retryDelay seconds before next attempt..." -ForegroundColor Gray
                Start-Sleep -Seconds $retryDelay
            } else {
                Write-Host "[ERROR] Maximum connection attempts ($maxRetries) reached. Giving up." -ForegroundColor Red
                throw
            }
        }
    } while (-not $connected -and $retryCount -le $maxRetries)

    if (-not $connected) {
        throw "Failed to establish WinRM connection after $maxRetries attempts"
    }
    #######

    if ($result) {
        Write-Host "[SUCCESS] Remote operation completed successfully!" -ForegroundColor Green
        Write-Host "[SUCCESS] Downloaded file: $result" -ForegroundColor Green
        return $result
    } else {
        Write-Host "[ERROR] Remote operation completed but no file was returned" -ForegroundColor Red
        exit 1
    }

}
catch [System.Management.Automation.RemoteException] {
    Write-Host "[REMOTE ERROR] $($_.Exception.Message)" -ForegroundColor Red
    exit 1
}
catch [System.Management.Automation.RuntimeException] {
    Write-Host "[RUNTIME ERROR] $($_.Exception.Message)" -ForegroundColor Red
    exit 1
}
catch {
    Write-Host "[UNEXPECTED ERROR] $($_.Exception.GetType().Name): $($_.Exception.Message)" -ForegroundColor Red
    Write-Host "Stack Trace: $($_.ScriptStackTrace)" -ForegroundColor DarkRed
    exit 1
}