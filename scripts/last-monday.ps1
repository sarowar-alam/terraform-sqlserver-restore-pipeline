# Get current date
$currentDate = Get-Date
$month = $currentDate.Month
$dayName = $currentDate.DayOfWeek
$year = $currentDate.Year

Write-Host "Current Date: $($currentDate.ToString('yyyy-MM-dd'))"
Write-Host "Day: $dayName, Month: $month, Year: $year"

# Check if today is Monday and the last Monday of the month
$isLastMonday = $false

if ($dayName -eq "Monday") {
    $lastDayOfMonth = (Get-Date -Year $year -Month $month -Day 1).AddMonths(1).AddDays(-1)
    $lastMonday = $lastDayOfMonth
    while ($lastMonday.DayOfWeek -ne "Monday") {
        $lastMonday = $lastMonday.AddDays(-1)
    }
    
    if ($currentDate.Date -eq $lastMonday.Date) {
        Write-Host "This is last Monday of the month, we will execute"
        $isLastMonday = $true
    } else {
        Write-Host "Sorry, let's wait till last Monday!"
    }
} else {
    Write-Host "Sorry, let's wait till last Monday!"
}

# Return boolean value for Jenkins to capture
return $isLastMonday