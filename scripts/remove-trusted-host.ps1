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

# Function to remove IP from trusted hosts list
function Remove-IPFromTrustedHosts {
    param(
        [string]$IPToRemove,
        [string]$TrustedHostsString
    )
    
    $entries = Get-TrustedHostsEntries $TrustedHostsString
    $updatedEntries = @()
    $removedCount = 0
    
    foreach ($entry in $entries) {
        # Check for exact match (case insensitive)
        if ($entry -eq $IPToRemove) {
            $removedCount++
            Write-Log "Removing IP: $entry" "INFO" "Yellow"
            continue
        }
        
        # Keep entries that don't match the IP to remove
        $updatedEntries += $entry
    }
    
    # Join remaining entries back into comma-separated string
    $newTrustedHosts = $updatedEntries -join ','
    
    return @{
        NewTrustedHosts = $newTrustedHosts
        RemovedCount = $removedCount
    }
}

# Configuration
$backupDir = "C:\backup"
$dateStamp = Get-Date -Format "yyyy_MM_dd_HH_mm"
$backupFile = "$backupDir\TrustedHosts_$dateStamp.txt"

Write-Log "Starting Trusted Hosts removal operation" "INFO" "Cyan"
Write-Log "Target IP to remove: $IPAddress" "INFO" "Cyan"
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
        $backupContent = "No trusted hosts configured as of $((Get-Date).ToString())`r`n# IP removal requested: $IPAddress"
        Write-Log "No existing trusted hosts found - nothing to remove" "WARNING" "Yellow"
        
        # Still create backup
        $backupContent | Out-File -FilePath $backupFile -Encoding UTF8 -Force
        Write-Log "Backup created: $backupFile" "INFO" "Green"
        Write-Log "Operation completed - no IPs to remove" "INFO" "Green"
        exit 0
    }
    else {
        $backupContent = "$currentTrustedHosts`r`n# Backup created on: $(Get-Date)`r`n# IP removal requested: $IPAddress"
        Write-Log "Current trusted hosts retrieved: $currentTrustedHosts" "INFO" "Yellow"
        
        # Check if IP exists in trusted hosts
        Write-Log "Checking if IP address exists in trusted hosts..." "INFO" "Gray"
        $entries = Get-TrustedHostsEntries $currentTrustedHosts
        $ipExists = $false
        
        foreach ($entry in $entries) {
            if ($entry -eq $IPAddress) {
                $ipExists = $true
                break
            }
        }
        
        if (-not $ipExists) {
            Write-Log "IP address $IPAddress not found in trusted hosts list" "WARNING" "Yellow"
            Write-Log "No changes needed - operation completed" "INFO" "Green"
            
            # Still create backup
            $backupContent | Out-File -FilePath $backupFile -Encoding UTF8 -Force
            Write-Log "Backup created at: $backupFile" "INFO" "Green"
            exit 0
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
    $backupContent = "WSMan TrustedHosts path not found - likely never configured as of $(Get-Date)`r`n# IP removal requested: $IPAddress"
    
    # Create backup file with force
    $backupContent | Out-File -FilePath $backupFile -Encoding UTF8 -Force
    Write-Log "Backup created for non-existent configuration: $backupFile" "INFO" "Yellow"
    Write-Log "Operation completed - no IPs to remove" "INFO" "Green"
    exit 0
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

# Remove IP from trusted hosts
Write-Log "Attempting to remove IP address from trusted hosts..." "INFO" "Cyan"
try {
    Write-Log "Removing IP: $IPAddress" "INFO" "Yellow"
    
    # Check if we're running as administrator (required for this operation)
    $isAdmin = ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole] "Administrator")
    if (-not $isAdmin) {
        throw "Administrator privileges required. Please run PowerShell as Administrator."
    }
    
    # Remove the IP from the trusted hosts list
    $removalResult = Remove-IPFromTrustedHosts -IPToRemove $IPAddress -TrustedHostsString $currentTrustedHosts
    
    if ($removalResult.RemovedCount -eq 0) {
        Write-Log "No instances of IP address $IPAddress found to remove" "WARNING" "Yellow"
        Write-Log "Operation completed - no changes made" "INFO" "Green"
        exit 0
    }
    
    Write-Log "Removed $($removalResult.RemovedCount) instance(s) of IP address" "SUCCESS" "Green"
    
    # Update the trusted hosts list
    if ([string]::IsNullOrEmpty($removalResult.NewTrustedHosts)) {
        Write-Log "All trusted hosts removed - setting empty value" "INFO" "Yellow"
        Set-Item WSMan:\localhost\Client\TrustedHosts -Value "" -Force
    } else {
        Set-Item WSMan:\localhost\Client\TrustedHosts -Value $removalResult.NewTrustedHosts -Force
    }
    
    # Verify the update
    $updatedList = (Get-Item WSMan:\localhost\Client\TrustedHosts -ErrorAction Stop).Value
    Write-Log "Update successful! New trusted hosts list: $updatedList" "SUCCESS" "Green"
    
    # Additional verification - check if IP was actually removed
    $finalEntries = Get-TrustedHostsEntries $updatedList
    $ipStillExists = $false
    
    foreach ($entry in $finalEntries) {
        if ($entry -eq $IPAddress) {
            $ipStillExists = $true
            break
        }
    }
    
    if (-not $ipStillExists) {
        Write-Log "IP address $IPAddress confirmed removed from trusted hosts list" "SUCCESS" "Green"
    } else {
        Write-Log "WARNING: IP address may not have been removed completely" "WARNING" "Yellow"
    }
}
catch [System.UnauthorizedAccessException] {
    Write-Log "ACCESS DENIED: Administrator privileges required to modify WSMan configuration" "ERROR" "Red"
    Write-Log "Please run PowerShell as Administrator and try again" "ERROR" "Red"
    Write-Log "Backup was successfully created at: $backupFile" "INFO" "Yellow"
    exit 1
}
catch [System.Management.Automation.PSArgumentException] {
    Write-Log "INVALID INPUT: Error modifying trusted hosts list" "ERROR" "Red"
    Write-Log "Error details: $($_.Exception.Message)" "ERROR" "Red"
    exit 1
}
catch {
    Write-Log "UNEXPECTED ERROR during removal: $($_.Exception.Message)" "ERROR" "Red"
    Write-Log "Error type: $($_.Exception.GetType().Name)" "ERROR" "Red"
    Write-Log "Backup was successfully created at: $backupFile" "INFO" "Yellow"
    exit 1
}

Write-Log "IP removal operation completed successfully!" "SUCCESS" "Green"
Write-Log "Backup location: $backupFile" "INFO" "Gray"
Write-Log "Final trusted hosts: $updatedList" "INFO" "Gray"

# Final verification that backup file exists
if (Test-Path $backupFile) {
    Write-Log "Final verification: Backup file exists at $backupFile" "SUCCESS" "Green"
} else {
    Write-Log "ERROR: Backup file was not created successfully" "ERROR" "Red"
}