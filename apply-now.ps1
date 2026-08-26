[CmdletBinding()]
param([switch]$Elevated)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$pwshPath = 'C:\Program Files\PowerShell\7\pwsh.exe'
$taskName = 'WifiNetworkSwitcher'
$logPath = 'C:\ProgramData\WifiNetworkSwitcher\logs\switch.log'
$transcriptPath = Join-Path $PSScriptRoot 'apply-now-elevated.log'

function Test-IsAdministrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]::new($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Invoke-SelfElevation {
    if (-not (Test-Path -LiteralPath $pwshPath)) { throw "PowerShell 7 was not found at '$pwshPath'." }
    if (Test-Path -LiteralPath $transcriptPath) { Remove-Item -LiteralPath $transcriptPath -Force }
    $quotedScript = '"{0}"' -f $PSCommandPath.Replace('"', '\"')
    try {
        $process = Start-Process -FilePath $pwshPath -Verb RunAs -Wait -PassThru -ArgumentList @(
            '-NoLogo', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $quotedScript, '-Elevated'
        )
        if (Test-Path -LiteralPath $transcriptPath) { Get-Content -LiteralPath $transcriptPath }
        exit $process.ExitCode
    } catch {
        throw "Administrator elevation was cancelled or failed: $($_.Exception.Message)"
    }
}

function Wait-TaskNotRunning {
    param([datetime]$Deadline)
    do {
        $task = Get-ScheduledTask -TaskName $taskName -ErrorAction Stop
        if ($task.State -notin @('Running', 'Queued')) { return $task }
        Start-Sleep -Milliseconds 500
    } while ([DateTime]::UtcNow -lt $Deadline)
    throw "Scheduled task '$taskName' did not become idle within three minutes."
}

if (-not (Test-IsAdministrator)) { Invoke-SelfElevation }
if ($Elevated) { Start-Transcript -LiteralPath $transcriptPath -Force | Out-Null }

try {
    $task = Get-ScheduledTask -TaskName $taskName -ErrorAction Stop
    if ($task.State -in @('Running', 'Queued')) {
        Write-Host "Task '$taskName' is already running; waiting for it to finish before applying the latest configuration..."
        $task = Wait-TaskNotRunning ([DateTime]::UtcNow.AddMinutes(3))
    }

    $beforeRun = (Get-ScheduledTaskInfo -TaskName $taskName -ErrorAction Stop).LastRunTime
    Write-Host "Starting scheduled task '$taskName'..."
    Start-ScheduledTask -TaskName $taskName -ErrorAction Stop

    $deadline = [DateTime]::UtcNow.AddMinutes(3)
    $completed = $false
    do {
        Start-Sleep -Milliseconds 500
        $task = Get-ScheduledTask -TaskName $taskName -ErrorAction Stop
        $info = Get-ScheduledTaskInfo -TaskName $taskName -ErrorAction Stop
        $completed = $info.LastRunTime -gt $beforeRun -and $task.State -ne 'Running'
    } while (-not $completed -and [DateTime]::UtcNow -lt $deadline)

    if (-not $completed) { throw "Task '$taskName' did not finish within three minutes." }
    if ($info.LastTaskResult -ne 0) {
        if (Test-Path -LiteralPath $logPath) {
            Write-Host 'Latest task log:'
            Get-Content -LiteralPath $logPath -Tail 40 | ForEach-Object { Write-Host $_ }
        }
        throw "Task failed with result 0x$('{0:X8}' -f ([uint32]$info.LastTaskResult))."
    }

    Write-Host 'Current Wi-Fi configuration was applied and verified successfully.' -ForegroundColor Green
    Write-Host "Completed at: $($info.LastRunTime)"
    if (Test-Path -LiteralPath $logPath) {
        Write-Host "Log: $logPath"
        Get-Content -LiteralPath $logPath -Tail 12 | ForEach-Object { Write-Host $_ }
    }
    if ($Elevated) { Stop-Transcript | Out-Null }
    exit 0
} catch {
    Write-Error $_ -ErrorAction Continue
    if ($Elevated) { Stop-Transcript | Out-Null }
    exit 1
}
