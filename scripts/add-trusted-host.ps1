param(
    [string]$IPAddress = ''
)

# Enhanced logging function
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

# Function to parse trusted hosts string into individual entries
function Get-TrustedHostsEntries {
    param([string]$TrustedHostsString)
    
    if ([string]::IsNullOrEmpty($TrustedHostsString)) {
        return @()
    }
    
    # Split by comma and remove empty/whitespace entries, then trim each entry
    $entries = $TrustedHostsString -split ',' | 
               Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | 
               ForEach-Object { $_.Trim() }
    
    return $entries
}

# Function to check if IP is already in trusted hosts
function Test-IPInTrustedHosts {
    param(
        [string]$IPToCheck,
        [string]$TrustedHostsString
    )
    
    $entries = Get-TrustedHostsEntries $TrustedHostsString
    
    foreach ($entry in $entries) {
        # Exact match check
        if ($entry -eq $IPToCheck) {
            return $true
        }
        
        # Check for IP in wildcard patterns (e.g., "192.168.*")
        if ($entry -like "*`**" -and $IPToCheck -like $entry.Replace('*', '%')) {
            return $true
        }
    }
    
    return $false
}

# Function to clear/kill all PSSessions
function Clear-AllPSSessions {
    Write-Log "Clearing all active PowerShell sessions..." "INFO" "Yellow"
    try {
        $sessions = Get-PSSession
        if ($sessions.Count -gt 0) {
            Write-Log "Found $($sessions.Count) active session(s)" "INFO" "Gray"
            $sessions | Remove-PSSession -ErrorAction Stop
            Write-Log "Successfully cleared all PowerShell sessions" "SUCCESS" "Green"
        } else {
            Write-Log "No active PowerShell sessions found" "INFO" "Gray"
        }
    }
    catch {
        Write-Log "WARNING: Error clearing sessions: $($_.Exception.Message)" "WARNING" "Yellow"
    }
}

# Configuration
$backupDir = "C:\backup"
$dateStamp = Get-Date -Format "yyyy_MM_dd_HH_mm"
$backupFile = "$backupDir\TrustedHosts_$dateStamp.txt"

Write-Log "Starting Trusted Hosts update operation" "INFO" "Cyan"
Write-Log "Target IP: $IPAddress" "INFO" "Cyan"
Write-Log "Backup file: $backupFile" "INFO" "Cyan"

# Validate IP address format
try {
    Write-Log "Validating IP address format..." "INFO" "Gray"
    if ([string]::IsNullOrWhiteSpace($IPAddress)) {
        throw "IP address cannot be empty"
    }
    
    # Basic IP validation (can be IPv4, IPv6, or hostname)
    if ($IPAddress -notmatch '^[a-zA-Z0-9\.\:\-\*]+$') {
        throw "Invalid IP address format: $IPAddress"
    }
    
    Write-Log "IP address format validation passed" "SUCCESS" "Green"
}
catch {
    Write-Log "IP VALIDATION ERROR: $($_.Exception.Message)" "ERROR" "Red"
    exit 1
}

# Clear all active PowerShell sessions before making changes
Clear-AllPSSessions

# Ensure backup directory exists
Write-Log "Checking backup directory existence..." "INFO" "Gray"
if (!(Test-Path $backupDir)) {
    try {
        Write-Log "Creating backup directory: $backupDir" "INFO" "Yellow"
        $null = New-Item -Path $backupDir -ItemType Directory -Force
        Write-Log "Backup directory created successfully" "SUCCESS" "Green"
    }
    catch {
        Write-Log "CRITICAL: Error creating backup directory: $($_.Exception.Message)" "ERROR" "Red"
        Write-Log "Operation aborted - cannot proceed without backup directory" "ERROR" "Red"
        exit 1
    }
} else {
    Write-Log "Backup directory already exists" "INFO" "Gray"
}

# Backup current trusted hosts
Write-Log "Starting backup of current trusted hosts..." "INFO" "Cyan"
try {
    $currentTrustedHosts = (Get-Item WSMan:\localhost\Client\TrustedHosts -ErrorAction Stop).Value
    
    if ([string]::IsNullOrEmpty($currentTrustedHosts)) {
        $backupContent = "No trusted hosts configured as of $((Get-Date).ToString())"
        Write-Log "No existing trusted hosts found" "INFO" "Yellow"
    }
    else {
        $backupContent = "$currentTrustedHosts`r`n# Backup created on: $(Get-Date)"
        Write-Log "Current trusted hosts retrieved: $currentTrustedHosts" "INFO" "Yellow"
        
        # Check for duplicate IP before proceeding
        Write-Log "Checking if IP address is already in trusted hosts..." "INFO" "Gray"
        $isDuplicate = Test-IPInTrustedHosts -IPToCheck $IPAddress -TrustedHostsString $currentTrustedHosts
        
        if ($isDuplicate) {
            Write-Log "IP address $IPAddress is already in trusted hosts list" "WARNING" "Yellow"
            Write-Log "No changes needed - operation completed" "INFO" "Green"
            
            # Still create backup even if no changes are made
            $backupContent | Out-File -FilePath $backupFile -Encoding UTF8 -Force
            Write-Log "Backup created at: $backupFile" "INFO" "Green"
            
            # Clear sessions again before exiting
            Clear-AllPSSessions
            exit 0
        } else {
            Write-Log "IP address $IPAddress is not in trusted hosts list - proceeding with addition" "INFO" "Green"
        }
    }
    
    # Create backup file with force to overwrite if exists
    $backupContent | Out-File -FilePath $backupFile -Encoding UTF8 -Force
    Write-Log "Backup completed successfully: $backupFile" "SUCCESS" "Green"
    
    # Verify file was actually created
    if (Test-Path $backupFile) {
        $fileInfo = Get-Item $backupFile
        Write-Log "Backup file verified: $($fileInfo.FullName)" "SUCCESS" "Green"
        Write-Log "File size: $($fileInfo.Length) bytes" "INFO" "Gray"
    } else {
        Write-Log "WARNING: Backup file creation may have failed - file not found" "WARNING" "Yellow"
    }
}
catch [System.Management.Automation.ItemNotFoundException] {
    Write-Log "WSMan TrustedHosts path not found. This might be expected if never configured." "INFO" "Yellow"
    $backupContent = "WSMan TrustedHosts path not found - likely never configured as of $(Get-Date)"
    
    # Create backup file with force
    $backupContent | Out-File -FilePath $backupFile -Encoding UTF8 -Force
    Write-Log "Backup created for non-existent configuration: $backupFile" "INFO" "Yellow"
    
    # Verify file creation
    if (Test-Path $backupFile) {
        Write-Log "Backup file verified" "SUCCESS" "Green"
    }
}
catch [System.UnauthorizedAccessException] {
    Write-Log "ACCESS DENIED: Insufficient permissions to read WSMan configuration" "ERROR" "Red"
    Write-Log "Please run PowerShell as Administrator" "ERROR" "Red"
    exit 1
}
catch {
    Write-Log "UNEXPECTED ERROR during backup: $($_.Exception.Message)" "ERROR" "Red"
    Write-Log "Error type: $($_.Exception.GetType().Name)" "ERROR" "Red"
    exit 1
}

# If we reached here and there are existing trusted hosts, we already checked for duplicates
# If there are no existing trusted hosts, we need to add the IP
if ([string]::IsNullOrEmpty($currentTrustedHosts)) {
    Write-Log "No existing trusted hosts - IP will be added as first entry" "INFO" "Yellow"
}

# Add new IP to trusted hosts
Write-Log "Attempting to add IP address to trusted hosts..." "INFO" "Cyan"
try {
    Write-Log "Adding IP: $IPAddress" "INFO" "Gray"
    
    # Check if we're running as administrator (required for this operation)
    $isAdmin = ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole] "Administrator")
    if (-not $isAdmin) {
        throw "Administrator privileges required. Please run PowerShell as Administrator."
    }
    
    # Add the IP to the trusted hosts list
    Set-Item WSMan:\localhost\Client\TrustedHosts -Value $IPAddress -Concatenate -Force
    # Restart WinRM to apply changes immediately
    Write-Host "Restarting WinRM service..." -ForegroundColor Cyan
    Restart-Service WinRM -Force

    # Remove any active PowerShell remoting sessions
    Write-Host "Clearing any active PowerShell sessions..." -ForegroundColor Cyan
    Get-PSSession | Remove-PSSession -ErrorAction SilentlyContinue


    # Verify the update
    $updatedList = (Get-Item WSMan:\localhost\Client\TrustedHosts -ErrorAction Stop).Value
    Write-Log "Update successful! New trusted hosts list: $updatedList" "SUCCESS" "Green"
    
    # Additional verification - check if IP was actually added
    $finalEntries = Get-TrustedHostsEntries $updatedList
    $ipAdded = $false
    
    foreach ($entry in $finalEntries) {
        if ($entry -eq $IPAddress) {
            $ipAdded = $true
            break
        }
    }
    
    if ($ipAdded) {
        Write-Log "IP address $IPAddress confirmed in trusted hosts list" "SUCCESS" "Green"
    } else {
        Write-Log "WARNING: IP address may not have been added correctly" "WARNING" "Yellow"
    }
    
    # Test network connection to the remote server on WinRM port (5985)
    Write-Log "Testing network connection to $IPAddress on port 5985..." "INFO" "Gray"
    
    $maxRetries = 20
    $retryDelay = 30
    $retryCount = 0
    $connectionSuccessful = $false

    do {
        $retryCount++
        try {
            Write-Log "Attempting connection test to $IPAddress on port 5985 (Attempt $retryCount of $maxRetries)..." "INFO" "Gray"
            
            $connectionTest = Test-NetConnection -ComputerName $IPAddress -Port 5985 -InformationLevel Detailed -ErrorAction Stop
            
            if ($connectionTest.TcpTestSucceeded) {
                Write-Log "SUCCESS: Network connection to $IPAddress on port 5985 is available" "SUCCESS" "Green"
                Write-Log "Ping reply: $($connectionTest.PingSucceeded)" "INFO" "Gray"
                Write-Log "Roundtrip time: $($connectionTest.RoundtripTime)ms" "INFO" "Gray"
                $connectionSuccessful = $true
                break
            } else {
                Write-Log "WARNING: Cannot connect to $IPAddress on port 5985. WinRM may not be accessible." "WARNING" "Yellow"
                Write-Log "Ping result: $($connectionTest.PingSucceeded)" "INFO" "Gray"
            }
        } catch {
            Write-Log "ERROR: Connection test failed: $($_.Exception.Message)" "ERROR" "Red"
        }
        
        # Only wait if we're going to try again
        if ($retryCount -lt $maxRetries -and -not $connectionSuccessful) {
            Write-Log "Waiting $retryDelay seconds before next attempt..." "INFO" "Gray"
            Start-Sleep -Seconds $retryDelay
        }
        
    } while ($retryCount -lt $maxRetries -and -not $connectionSuccessful)

    if (-not $connectionSuccessful) {
        Write-Log "CRITICAL: Failed to establish connection to $IPAddress after $maxRetries attempts" "ERROR" "Red"
    }

}
catch [System.UnauthorizedAccessException] {
    Write-Log "ACCESS DENIED: Administrator privileges required to modify WSMan configuration" "ERROR" "Red"
    Write-Log "Please run PowerShell as Administrator and try again" "ERROR" "Red"
    Write-Log "Backup was successfully created at: $backupFile" "INFO" "Yellow"
    exit 1
}
catch [System.Management.Automation.PSArgumentException] {
    Write-Log "INVALID INPUT: The IP address format may be incorrect: $IPAddress" "ERROR" "Red"
    Write-Log "Please verify the IP address format" "ERROR" "Red"
    exit 1
}
catch {
    Write-Log "UNEXPECTED ERROR during update: $($_.Exception.Message)" "ERROR" "Red"
    Write-Log "Error type: $($_.Exception.GetType().Name)" "ERROR" "Red"
    Write-Log "Backup was successfully created at: $backupFile" "INFO" "Yellow"
    exit 1
}

# Clear all active PowerShell sessions after making changes
Clear-AllPSSessions

Write-Log "Operation completed successfully!" "SUCCESS" "Green"
Write-Log "Backup location: $backupFile" "INFO" "Gray"
Write-Log "Final trusted hosts: $updatedList" "INFO" "Gray"

# Final verification that backup file exists
if (Test-Path $backupFile) {
    Write-Log "Final verification: Backup file exists at $backupFile" "SUCCESS" "Green"
} else {
    Write-Log "ERROR: Backup file was not created successfully" "ERROR" "Red"
}