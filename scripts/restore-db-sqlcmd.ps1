param(
    [Parameter(Mandatory=$true)]
    [string]$RemoteServerIP,
    
    [Parameter(Mandatory=$true)]
    [string]$Username,
    
    [Parameter(Mandatory=$false)]
    [string]$RemoteFolderPath,
    
    [Parameter(Mandatory=$false)]
    [string]$FilePrefix,
    
    [Parameter(Mandatory=$false)]
    [string]$DatabaseName
)



# Convert plain text password to SecureString (handles special characters)
Write-Host "[INFO] Converting password to SecureString" -ForegroundColor Green
$passwordFilePath = "Automated-MS-SQL-Backup-Restore-Job\password.txt"
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

# Function for logging
function Write-Log {
    param(
        [string]$Message,
        [string]$Level = "INFO",
        [string]$Color = "White"
    )
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $logMessage = "[$timestamp] [$Level] $Message"
    Write-Host $logMessage -ForegroundColor $Color
}

try {
    Write-Log "Starting database restore process" "INFO" "Cyan"
    Write-Log "Target server: $RemoteServerIP" "INFO" "Cyan"
    Write-Log "Database: $DatabaseName" "INFO" "Cyan"

    # Establish remote session without SSL
    Write-Log "Establishing remote session to $RemoteServerIP (non-SSL)" "INFO" "Gray"
    $Session = New-PSSession -ComputerName $RemoteServerIP -Credential $Credential -ErrorAction Stop
    Write-Log "Connected successfully without SSL" "SUCCESS" "Green"

    # Find the latest backup file
    Write-Log "Searching for latest backup file with prefix: $FilePrefix" "INFO" "Gray"
    $BackupFile = Invoke-Command -Session $Session -ScriptBlock {
        param($RemoteFolderPath, $FilePrefix)
        
        try {
            if (-not (Test-Path $RemoteFolderPath)) {
                throw "Remote folder path does not exist: $RemoteFolderPath"
            }
            
            $BackupFiles = Get-ChildItem -Path $RemoteFolderPath -Filter "$FilePrefix*.BAK" -ErrorAction Stop | 
                           Sort-Object LastWriteTime -Descending | 
                           Select-Object -First 1
        
            if ($BackupFiles) {
                return $BackupFiles.FullName
            } else {
                return $null
            }
        }
        catch {
            throw "Error searching for backup files: $($_.Exception.Message)"
        }
    } -ArgumentList $RemoteFolderPath, $FilePrefix

    if (-not $BackupFile) {
        throw "No backup files found with prefix '$FilePrefix' in $RemoteFolderPath"
    }

    Write-Log "Found backup file: $BackupFile" "SUCCESS" "Green"

    # Restore the database with proper logical file detection
    Write-Log "Starting database restore from $BackupFile" "INFO" "Gray"
    
    $RestoreResult = Invoke-Command -Session $Session -ScriptBlock {
        param($BackupFile, $DatabaseName)
        
        try {
            # Verify backup file exists
            if (-not (Test-Path $BackupFile)) {
                throw "Backup file not found: $BackupFile"
            }

            # Get SQL Server data directory path
            Write-Output "Getting SQL Server data directory..."
            $DataPathResult = Invoke-SqlCmd -Query "SELECT SERVERPROPERTY('InstanceDefaultDataPath') AS DataPath, SERVERPROPERTY('InstanceDefaultLogPath') AS LogPath" -ErrorAction Stop
            $DataDirectory = $DataPathResult.DataPath
            $LogDirectory = $DataPathResult.LogPath
            
            if (-not $DataDirectory -or -not $LogDirectory) {
                # Use default paths if not found
                $DataDirectory = "C:\Program Files\Microsoft SQL Server\MSSQL*.MSSQLSERVER\MSSQL\DATA\"
                $LogDirectory = "C:\Program Files\Microsoft SQL Server\MSSQL*.MSSQLSERVER\MSSQL\DATA\"
                
                # Try to find the actual data directory
                $PossiblePaths = @(
                    "C:\Program Files\Microsoft SQL Server\MSSQL16.MSSQLSERVER\MSSQL\DATA\",
                    "C:\Program Files\Microsoft SQL Server\MSSQL15.MSSQLSERVER\MSSQL\DATA\",
                    "C:\Program Files\Microsoft SQL Server\MSSQL14.MSSQLSERVER\MSSQL\DATA\",
                    "C:\Program Files\Microsoft SQL Server\MSSQL13.MSSQLSERVER\MSSQL\DATA\"
                )
                
                foreach ($path in $PossiblePaths) {
                    if (Test-Path $path) {
                        $DataDirectory = $path
                        $LogDirectory = $path
                        break
                    }
                }
            }
            
            Write-Output "Data directory: $DataDirectory"
            Write-Output "Log directory: $LogDirectory"

            # Create directories if they don't exist
            if (-not (Test-Path $DataDirectory)) {
                Write-Output "Creating data directory: $DataDirectory"
                New-Item -ItemType Directory -Path $DataDirectory -Force | Out-Null
            }
            
            if (-not (Test-Path $LogDirectory)) {
                Write-Output "Creating log directory: $LogDirectory"
                New-Item -ItemType Directory -Path $LogDirectory -Force | Out-Null
            }

            # Get logical file names from backup
            Write-Output "Reading logical file names from backup..."
            $FileList = Invoke-SqlCmd -Query "RESTORE FILELISTONLY FROM DISK = '$BackupFile'" -ErrorAction Stop
            
            $DataFile = $FileList | Where-Object { $_.Type -eq 'D' } | Select-Object -First 1
            $LogFile = $FileList | Where-Object { $_.Type -eq 'L' } | Select-Object -First 1
            
            if (-not $DataFile -or -not $LogFile) {
                throw "Could not find data and log files in backup"
            }
            
            $DataLogicalName = $DataFile.LogicalName
            $LogLogicalName = $LogFile.LogicalName
            
            Write-Output "Data file: $DataLogicalName"
            Write-Output "Log file: $LogLogicalName"

            # Build the restore command with correct paths
            $MdfPath = Join-Path $DataDirectory "$DatabaseName.mdf"
            $LdfPath = Join-Path $LogDirectory "$DatabaseName.ldf"
            
            Write-Output "MDF path: $MdfPath"
            Write-Output "LDF path: $LdfPath"

            $RestoreCommand = @"
            RESTORE DATABASE [$DatabaseName] 
            FROM DISK = '$BackupFile'
            WITH REPLACE, RECOVERY,
            MOVE '$DataLogicalName' TO '$MdfPath',
            MOVE '$LogLogicalName' TO '$LdfPath'
"@
        
            Write-Output "Executing restore command..."
            # Execute the restore command
            Invoke-SqlCmd -Query $RestoreCommand -ErrorAction Stop -QueryTimeout 7200
            return "SUCCESS"
        }
        catch {
            return "ERROR: $($_.Exception.Message)"
        }
    } -ArgumentList $BackupFile, $DatabaseName

    if ($RestoreResult -eq "SUCCESS") {
        Write-Log "Database restore completed successfully!" "SUCCESS" "Green"
    } else {
        throw $RestoreResult
    }
}
catch {
    Write-Log "Error during restore process: $($_.Exception.Message)" "ERROR" "Red"
    
    # More detailed error information
    if ($_.Exception.InnerException) {
        Write-Log "Inner exception: $($_.Exception.InnerException.Message)" "ERROR" "Red"
    }
    
    exit 1
}
finally {
    # Clean up session
    if ($Session) {
        Remove-PSSession $Session -ErrorAction SilentlyContinue
        Write-Log "Remote session closed" "INFO" "Gray"
    }
}

Write-Log "Database restore operation completed" "SUCCESS" "Green"