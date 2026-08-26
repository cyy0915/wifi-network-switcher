[CmdletBinding()]
param(
    [switch]$RestoreDhcp,
    [switch]$RemoveLogs,
    [switch]$RemoveYamlModule,
    [switch]$Elevated
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$pwshPath = 'C:\Program Files\PowerShell\7\pwsh.exe'
$taskName = 'WifiNetworkSwitcher'
$installRoot = Join-Path $env:ProgramData 'WifiNetworkSwitcher'
$configPath = Join-Path $PSScriptRoot 'wifi-network-config.yaml'
$runnerPath = Join-Path $installRoot 'Invoke-WifiNetworkSwitcher.ps1'
$yamlVersion = '0.4.12'
$requestedSwitches = [ordered]@{
    RestoreDhcp = [bool]$RestoreDhcp
    RemoveLogs = [bool]$RemoveLogs
    RemoveYamlModule = [bool]$RemoveYamlModule
}

function Test-IsAdministrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]::new($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Invoke-SelfElevation {
    $arguments = @('-NoLogo', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', ('"{0}"' -f $PSCommandPath.Replace('"', '\"')))
    foreach ($name in @('RestoreDhcp', 'RemoveLogs', 'RemoveYamlModule')) {
        if ($requestedSwitches[$name]) { $arguments += "-$name" }
    }
    $arguments += '-Elevated'
    $transcriptPath = Join-Path $PSScriptRoot 'uninstall-elevated.log'
    if (Test-Path -LiteralPath $transcriptPath) { Remove-Item -LiteralPath $transcriptPath -Force }
    try {
        $process = Start-Process -FilePath $pwshPath -Verb RunAs -Wait -PassThru -ArgumentList $arguments
        if (Test-Path -LiteralPath $transcriptPath) { Get-Content -LiteralPath $transcriptPath }
        exit $process.ExitCode
    } catch {
        throw "Administrator elevation was cancelled or failed: $($_.Exception.Message)"
    }
}

function Wait-TaskIdle {
    $task = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
    if ($null -eq $task) { return }
    $deadline = [DateTime]::UtcNow.AddMinutes(3)
    while ($task.State -eq 'Running' -and [DateTime]::UtcNow -lt $deadline) {
        Start-Sleep -Milliseconds 500
        $task = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
        if ($null -eq $task) { return }
    }
    if ($task.State -eq 'Running') {
        throw 'The network switch task is still running; uninstall aborted rather than interrupting a network change.'
    }
}

if (-not (Test-IsAdministrator)) { Invoke-SelfElevation }
if ($Elevated) { Start-Transcript -LiteralPath (Join-Path $PSScriptRoot 'uninstall-elevated.log') -Force | Out-Null }

try {
    Wait-TaskIdle
    if ($RestoreDhcp) {
        if (-not (Test-Path -LiteralPath $runnerPath)) { throw "Installed runner '$runnerPath' was not found." }
        if (-not (Test-Path -LiteralPath $configPath)) { throw "Configuration '$configPath' was not found." }
        & $pwshPath -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass `
            -File $runnerPath -ConfigPath $configPath -Trigger Uninstall -RestoreDhcp
        if ($LASTEXITCODE -ne 0) { throw "DHCP restore failed with exit code $LASTEXITCODE; uninstall stopped." }
        Write-Host 'IPv4 and DNS were restored to DHCP.'
    }

    if (Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue) {
        Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction Stop
        Write-Host "Removed scheduled task '$taskName'."
    }

    foreach ($file in @('Invoke-WifiNetworkSwitcher.ps1', 'WifiNetworkSwitcher.psm1')) {
        $path = Join-Path $installRoot $file
        if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Force }
    }
    if ($RemoveLogs) {
        $logDirectory = Join-Path $installRoot 'logs'
        if (Test-Path -LiteralPath $logDirectory) {
            Remove-Item -LiteralPath $logDirectory -Recurse -Force
            Write-Host "Removed logs from '$logDirectory'."
        }
    }
    if (Test-Path -LiteralPath $installRoot) {
        $remaining = @(Get-ChildItem -LiteralPath $installRoot -Force)
        if ($remaining.Count -eq 0) { Remove-Item -LiteralPath $installRoot -Force }
    }

    if ($RemoveYamlModule) {
        $answer = Read-Host "Remove global powershell-yaml $yamlVersion? Other scripts may use it. Type REMOVE to confirm"
        if ($answer -eq 'REMOVE') {
            if (Get-Command Uninstall-PSResource -ErrorAction SilentlyContinue) {
                Uninstall-PSResource -Name powershell-yaml -Version $yamlVersion -Scope AllUsers -Confirm:$false -ErrorAction Stop
            } elseif (Get-Command Uninstall-Module -ErrorAction SilentlyContinue) {
                Uninstall-Module -Name powershell-yaml -RequiredVersion $yamlVersion -Force -ErrorAction Stop
            } else {
                throw 'Neither Uninstall-PSResource nor Uninstall-Module is available.'
            }
            Write-Host "Removed powershell-yaml $yamlVersion."
        } else {
            Write-Host 'YAML module removal was not confirmed; module was preserved.'
        }
    }

    Write-Host 'Uninstall completed. Current network settings and the YAML configuration were preserved unless explicitly requested otherwise.'
    if ($Elevated) { Stop-Transcript | Out-Null }
    exit 0
} catch {
    Write-Error $_ -ErrorAction Continue
    if ($Elevated) { Stop-Transcript | Out-Null }
    exit 1
}
