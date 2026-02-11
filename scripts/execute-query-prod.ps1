param(
    [Parameter(Mandatory=$true)]
    [string]$RemoteServerIP,
    
    [Parameter(Mandatory=$true)]
    [string]$Username,
    
    [Parameter(Mandatory=$true)]
    [securestring]$Password,  # Changed from string to securestring
    
    [Parameter(Mandatory=$false)]
    [string]$RemoteFolderPath,
    
    [Parameter(Mandatory=$false)]
    [string]$SQLFilePath,
    
    [Parameter(Mandatory=$false)]
    [string]$DatabaseName
)

# Create credential object directly from secure string password
$Credential = New-Object System.Management.Automation.PSCredential ($Username, $Password)

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

# Function to display query results in a formatted table
function Get-QueryResultsAsString {
    param($Results)
    
    $output = ""
    
    if ($Results -and $Results.Count -gt 0) {
        # Convert results to formatted table string
        $tableString = $Results | Format-Table -AutoSize | Out-String -Width 4096
        $tableLines = $tableString.Trim() -split "`r?`n"
        
        # Find the longest line for border width
        $maxWidth = 0
        foreach ($line in $tableLines) {
            if ($line.Length -gt $maxWidth) {
                $maxWidth = $line.Length
            }
        }
        
        # Add padding for borders
        $borderWidth = $maxWidth + 4
        
        # Create title for top border
        $title = " Restore Test "
        $titleLine = "*" * 12 + $title + "*" * (($borderWidth - 12 - $title.Length) + 1)
        
        # Create bottom border
        $bottomBorder = "*" * $borderWidth
        
        # Build the output string
        $output += $titleLine + "`r`n"
        
        foreach ($line in $tableLines) {
            $paddedLine = " * " + $line.PadRight($maxWidth) + " * "
            $output += $paddedLine + "`r`n"
        }
        
        $output += $bottomBorder + "`r`n"
        
    } else {
        # For empty results
        $message = "Query executed successfully (no rows returned)"
        $borderWidth = $message.Length + 4
        
        $title = " Restore Test "
        $titleLine = "*" * 12 + $title + "*" * (($borderWidth - 12 - $title.Length) + 1)
        $bottomBorder = "*" * $borderWidth
        
        $output += $titleLine + "`r`n"
        $output += " * " + $message.PadRight($message.Length) + " * " + "`r`n"
        $output += $bottomBorder + "`r`n"
    }
    
    return $output
}

try {
    Write-Log "Starting SQL script execution process" "INFO" "Cyan"
    Write-Log "Target server: $RemoteServerIP" "INFO" "Cyan"
    Write-Log "Database: $DatabaseName" "INFO" "Cyan"
    Write-Log "SQL file: $SQLFilePath" "INFO" "Cyan"

    # Validate SQL file exists locally
    if (-not (Test-Path $SQLFilePath)) {
        throw "SQL file not found on local machine: $SQLFilePath"
    }

    # Set default remote folder path if not provided
    if ([string]::IsNullOrEmpty($RemoteFolderPath)) {
        $RemoteFolderPath = "C:\Temp\SQLScripts\"
        Write-Log "Using default remote folder path: $RemoteFolderPath" "INFO" "Yellow"
    }

    # Establish remote session
    Write-Log "Establishing remote session to $RemoteServerIP" "INFO" "Gray"
    $Session = New-PSSession -ComputerName $RemoteServerIP -Credential $Credential -ErrorAction Stop
    Write-Log "Connected successfully" "SUCCESS" "Green"

    # Create remote directory if it doesn't exist
    Write-Log "Creating remote directory if needed: $RemoteFolderPath" "INFO" "Gray"
    Invoke-Command -Session $Session -ScriptBlock {
        param($FolderPath)
        if (-not (Test-Path $FolderPath)) {
            New-Item -ItemType Directory -Path $FolderPath -Force | Out-Null
        }
    } -ArgumentList $RemoteFolderPath

    # Copy SQL file to remote server
    $SQLFileName = Split-Path $SQLFilePath -Leaf
    $RemoteSQLFilePath = Join-Path $RemoteFolderPath $SQLFileName
    
    Write-Log "Copying SQL file to remote server: $RemoteSQLFilePath" "INFO" "Gray"
    Copy-Item -Path $SQLFilePath -Destination $RemoteSQLFilePath -ToSession $Session -Force
    Write-Log "File copied successfully" "SUCCESS" "Green"

    # Execute SQL script on remote server and capture results
    Write-Log "Executing SQL script on database: $DatabaseName" "INFO" "Gray"
    Write-Log "----------------------------------------" "INFO" "Gray"
    
    $ExecutionResults = Invoke-Command -Session $Session -ScriptBlock {
        param($RemoteSQLFilePath, $DatabaseName)
        
        try {
            # Verify SQL file exists on remote server
            if (-not (Test-Path $RemoteSQLFilePath)) {
                throw "SQL file not found on remote server: $RemoteSQLFilePath"
            }

            # Read SQL file content
            $SQLContent = Get-Content -Path $RemoteSQLFilePath -Raw -Encoding UTF8
            
            if ([string]::IsNullOrEmpty($SQLContent)) {
                throw "SQL file is empty"
            }

            Write-Output "=== SQL SCRIPT CONTENT ==="
            Write-Output $SQLContent
            Write-Output "========================="
            Write-Output ""

            # Execute SQL script against the specified database and capture results
            Write-Output "Executing SQL script against database: $DatabaseName"
            
            # Use Invoke-SqlCmd with the database context and capture output
            $results = Invoke-SqlCmd -ServerInstance "localhost" -Database $DatabaseName -Query $SQLContent -ErrorAction Stop -OutputSqlErrors $true
            
            # Return both success status and results
            return @{
                Status = "SUCCESS"
                Results = $results
                Message = "SQL script executed successfully"
            }
        }
        catch {
            $errorMessage = $_.Exception.Message
            if ($_.Exception.InnerException) {
                $errorMessage += " | Inner: " + $_.Exception.InnerException.Message
            }
            
            # Return error information
            return @{
                Status = "ERROR"
                Results = $null
                Message = $errorMessage
            }
        }
        finally {
            # Clean up the SQL file from remote server
            if (Test-Path $RemoteSQLFilePath) {
                Remove-Item -Path $RemoteSQLFilePath -Force -ErrorAction SilentlyContinue
                Write-Output "Cleaned up temporary SQL file"
            }
        }
    } -ArgumentList $RemoteSQLFilePath, $DatabaseName

    # Display the results
    if ($ExecutionResults.Status -eq "SUCCESS") {
        Write-Log "SQL script executed successfully!" "SUCCESS" "Green"
        Write-Log "Execution Message: $($ExecutionResults.Message)" "INFO" "Green"
        
        # Display query results if any
        if ($ExecutionResults.Results) {
            $formattedResults = Get-QueryResultsAsString -Results $ExecutionResults.Results
            # Return this string so Jenkins can capture it
            return $formattedResults
        } else {
            $formattedResults = Get-QueryResultsAsString -Results $null
            return $formattedResults
        }
    } else {
        throw $ExecutionResults.Message
    }
}
catch {
    Write-Log "Error during SQL execution process: $($_.Exception.Message)" "ERROR" "Red"
    
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

Write-Log "SQL script execution completed" "SUCCESS" "Green"