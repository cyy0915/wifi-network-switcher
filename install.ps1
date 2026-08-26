[CmdletBinding()]
param([switch]$RenderTaskXml, [switch]$Elevated)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$pwshPath = 'C:\Program Files\PowerShell\7\pwsh.exe'
$taskName = 'WifiNetworkSwitcher'
$installRoot = Join-Path $env:ProgramData 'WifiNetworkSwitcher'
$configPath = Join-Path $PSScriptRoot 'wifi-network-config.yaml'
$runnerName = 'Invoke-WifiNetworkSwitcher.ps1'
$moduleName = 'WifiNetworkSwitcher.psm1'
$yamlVersion = '0.4.12'

function Test-IsAdministrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]::new($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Invoke-SelfElevation {
    if (-not (Test-Path -LiteralPath $pwshPath)) { throw "PowerShell 7 was not found at '$pwshPath'." }
    $quotedScript = '"{0}"' -f $PSCommandPath.Replace('"', '\"')
    $transcriptPath = Join-Path $PSScriptRoot 'install-elevated.log'
    if (Test-Path -LiteralPath $transcriptPath) { Remove-Item -LiteralPath $transcriptPath -Force }
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

function Install-YamlModule {
    $allUsersRoots = @(
        (Join-Path $env:ProgramFiles 'PowerShell\Modules'),
        (Join-Path $env:ProgramFiles 'WindowsPowerShell\Modules')
    )
    $installed = @(Get-Module -ListAvailable -Name powershell-yaml |
        Where-Object Version -eq ([version]$yamlVersion) |
        Where-Object {
            $modulePath = $_.Path
            @($allUsersRoots | Where-Object { $modulePath.StartsWith($_, [StringComparison]::OrdinalIgnoreCase) }).Count -gt 0
        })
    if ($installed.Count -eq 0) {
        Write-Host "Installing powershell-yaml $yamlVersion for all users..."
        if (Get-Command Install-PSResource -ErrorAction SilentlyContinue) {
            Install-PSResource -Name powershell-yaml -Version $yamlVersion -Scope AllUsers `
                -Repository PSGallery -TrustRepository -Quiet -ErrorAction Stop
        } elseif (Get-Command Install-Module -ErrorAction SilentlyContinue) {
            Install-Module -Name powershell-yaml -RequiredVersion $yamlVersion -Scope AllUsers `
                -Repository PSGallery -Force -AllowClobber -ErrorAction Stop
        } else {
            throw 'Neither Install-PSResource nor Install-Module is available.'
        }
    }
    $installed = @(Get-Module -ListAvailable -Name powershell-yaml |
        Where-Object Version -eq ([version]$yamlVersion) |
        Where-Object {
            $modulePath = $_.Path
            @($allUsersRoots | Where-Object { $modulePath.StartsWith($_, [StringComparison]::OrdinalIgnoreCase) }).Count -gt 0
        })
    if ($installed.Count -eq 0) { throw "powershell-yaml $yamlVersion was not found in an AllUsers module directory after installation." }
    Import-Module $installed[0].Path -Force -ErrorAction Stop
}

function New-InitialConfiguration {
    Import-Module (Join-Path $PSScriptRoot $moduleName) -Force -ErrorAction Stop
    $interfaces = @(Get-WnsWlanInterfaces)
    if ($interfaces.Count -ne 1) {
        $details = if ($interfaces.Count -eq 0) { '(none found)' } else {
            ($interfaces | ForEach-Object { "  {$($_.InterfaceGuid)}  $($_.Description)" }) -join [Environment]::NewLine
        }
        throw "Expected exactly one physical Native Wi-Fi interface. Candidates:`n$details`nCreate '$configPath' manually with the intended interface GUID, then rerun the installer."
    }
    $guid = '{' + $interfaces[0].InterfaceGuid.ToString() + '}'
    $yaml = @"
version: 1

adapter:
  interfaceGuid: "$guid"

defaults:
  ip:
    mode: dhcp
  dns:
    mode: dhcp

networks: {}

# To enable rules, replace "networks: {}" above with the example mapping below.
# Static-rule examples:
# networks:
#   "Office-WiFi":
#     ip:
#       mode: static
#       address: "192.168.10.20/24"
#       gateway: "192.168.10.1"
#     dns:
#       mode: static
#       servers:
#         - "192.168.10.2"
#         - "1.1.1.1"
#   "Hotel-WiFi":
#     dns:
#       mode: dhcp
#     # ip is inherited from defaults (DHCP).
"@
    [IO.File]::WriteAllText($configPath, $yaml, [Text.UTF8Encoding]::new($false))
    Write-Host "Created initial configuration for '$($interfaces[0].Description)' at '$configPath'."
}

function Protect-InstallDirectory {
    New-Item -ItemType Directory -Path $installRoot -Force | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $installRoot 'logs') -Force | Out-Null
    & icacls.exe $installRoot /inheritance:r /grant:r '*S-1-5-18:(OI)(CI)F' '*S-1-5-32-544:(OI)(CI)F' | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "Failed to secure '$installRoot' with icacls (exit $LASTEXITCODE)." }
}

function Get-SwitcherTaskXml {
    $runnerPath = Join-Path $installRoot $runnerName
    $arguments = '-NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "{0}" -ConfigPath "{1}" -Trigger ScheduledTask' -f $runnerPath, $configPath
    $xmlCommand = [Security.SecurityElement]::Escape($pwshPath)
    $xmlArguments = [Security.SecurityElement]::Escape($arguments)
    $xmlWorkingDirectory = [Security.SecurityElement]::Escape($installRoot)
    $wlanSubscription = [Security.SecurityElement]::Escape(@'
<QueryList><Query Id="0" Path="Microsoft-Windows-WLAN-AutoConfig/Operational"><Select Path="Microsoft-Windows-WLAN-AutoConfig/Operational">*[System[Provider[@Name='Microsoft-Windows-WLAN-AutoConfig'] and EventID=8001]]</Select></Query></QueryList>
'@.Trim())
    $resumeSubscription = [Security.SecurityElement]::Escape(@'
<QueryList><Query Id="0" Path="System"><Select Path="System">*[System[Provider[@Name='Microsoft-Windows-Power-Troubleshooter'] and EventID=1]]</Select></Query></QueryList>
'@.Trim())
    $taskXml = @"
<?xml version="1.0" encoding="UTF-16"?>
<Task version="1.4" xmlns="http://schemas.microsoft.com/windows/2004/02/mit/task">
  <RegistrationInfo>
    <Description>Apply per-SSID IPv4 and DNS settings for the configured Wi-Fi adapter.</Description>
    <URI>\$taskName</URI>
  </RegistrationInfo>
  <Triggers>
    <BootTrigger><Enabled>true</Enabled><Delay>PT15S</Delay></BootTrigger>
    <LogonTrigger><Enabled>true</Enabled><Delay>PT5S</Delay></LogonTrigger>
    <SessionStateChangeTrigger><Enabled>true</Enabled><StateChange>SessionUnlock</StateChange><Delay>PT2S</Delay></SessionStateChangeTrigger>
    <EventTrigger><Enabled>true</Enabled><Subscription>$wlanSubscription</Subscription><Delay>PT2S</Delay></EventTrigger>
    <EventTrigger><Enabled>true</Enabled><Subscription>$resumeSubscription</Subscription><Delay>PT5S</Delay></EventTrigger>
  </Triggers>
  <Principals>
    <Principal id="Author">
      <UserId>S-1-5-18</UserId>
      <RunLevel>HighestAvailable</RunLevel>
    </Principal>
  </Principals>
  <Settings>
    <MultipleInstancesPolicy>Queue</MultipleInstancesPolicy>
    <DisallowStartIfOnBatteries>false</DisallowStartIfOnBatteries>
    <StopIfGoingOnBatteries>false</StopIfGoingOnBatteries>
    <AllowHardTerminate>false</AllowHardTerminate>
    <StartWhenAvailable>true</StartWhenAvailable>
    <RunOnlyIfNetworkAvailable>false</RunOnlyIfNetworkAvailable>
    <IdleSettings><StopOnIdleEnd>false</StopOnIdleEnd><RestartOnIdle>false</RestartOnIdle></IdleSettings>
    <AllowStartOnDemand>true</AllowStartOnDemand>
    <Enabled>true</Enabled>
    <Hidden>false</Hidden>
    <RunOnlyIfIdle>false</RunOnlyIfIdle>
    <WakeToRun>false</WakeToRun>
    <ExecutionTimeLimit>PT3M</ExecutionTimeLimit>
    <Priority>7</Priority>
  </Settings>
  <Actions Context="Author">
    <Exec>
      <Command>$xmlCommand</Command>
      <Arguments>$xmlArguments</Arguments>
      <WorkingDirectory>$xmlWorkingDirectory</WorkingDirectory>
    </Exec>
  </Actions>
</Task>
"@
    return $taskXml
}

function Register-SwitcherTask {
    $taskXml = Get-SwitcherTaskXml
    Register-ScheduledTask -TaskName $taskName -Xml $taskXml -Force -ErrorAction Stop | Out-Null
}

if ($RenderTaskXml) { Get-SwitcherTaskXml; exit 0 }
if (-not (Test-IsAdministrator)) { Invoke-SelfElevation }
if ($Elevated) { Start-Transcript -LiteralPath (Join-Path $PSScriptRoot 'install-elevated.log') -Force | Out-Null }

try {
    if (-not (Test-Path -LiteralPath $pwshPath)) { throw "PowerShell 7 was not found at '$pwshPath'." }
    $version = (& $pwshPath -NoLogo -NoProfile -Command '$PSVersionTable.PSVersion.ToString()').Trim()
    Write-Host "Using PowerShell $version at '$pwshPath'."

    Install-YamlModule
    if (-not (Test-Path -LiteralPath $configPath)) { New-InitialConfiguration }

    Import-Module (Join-Path $PSScriptRoot $moduleName) -Force -ErrorAction Stop
    $configuration = Read-WnsConfiguration -Path $configPath
    Write-Host "Configuration is valid for interface {$($configuration.InterfaceGuid)}."

    Protect-InstallDirectory
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot $runnerName) -Destination (Join-Path $installRoot $runnerName) -Force
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot $moduleName) -Destination (Join-Path $installRoot $moduleName) -Force
    Protect-InstallDirectory

    & $pwshPath -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass `
        -File (Join-Path $installRoot $runnerName) -ConfigPath $configPath -Trigger Validation -ValidateOnly
    if ($LASTEXITCODE -ne 0) { throw "Protected runner validation failed with exit code $LASTEXITCODE." }

    Register-SwitcherTask
    Write-Host "Registered SYSTEM scheduled task '$taskName'."
    $beforeRun = (Get-ScheduledTaskInfo -TaskName $taskName -ErrorAction Stop).LastRunTime
    Start-ScheduledTask -TaskName $taskName -ErrorAction Stop
    $deadline = [DateTime]::UtcNow.AddMinutes(3)
    do {
        Start-Sleep -Milliseconds 500
        $task = Get-ScheduledTask -TaskName $taskName -ErrorAction Stop
        $info = Get-ScheduledTaskInfo -TaskName $taskName -ErrorAction Stop
        $completed = $info.LastRunTime -gt $beforeRun -and $task.State -ne 'Running'
    } while (-not $completed -and [DateTime]::UtcNow -lt $deadline)
    if (-not $completed) { throw 'Initial scheduled task run did not finish within three minutes.' }
    if ($info.LastTaskResult -ne 0) {
        $runLog = Join-Path $installRoot 'logs\switch.log'
        if (Test-Path -LiteralPath $runLog) {
            Write-Host 'Initial task log follows:'
            Get-Content -LiteralPath $runLog -Tail 80 | ForEach-Object { Write-Host $_ }
        } else {
            Write-Host "Initial task did not create the expected log '$runLog'."
        }
        throw "Initial scheduled task run failed with result 0x$('{0:X8}' -f ([uint32]$info.LastTaskResult)). See '$installRoot\logs\switch.log'."
    }
    Write-Host "Installation and initial application completed successfully."
    Write-Host "Task: $taskName"
    Write-Host "Config: $configPath"
    Write-Host "Log: $installRoot\logs\switch.log"
    if ($Elevated) { Stop-Transcript | Out-Null }
    exit 0
} catch {
    Write-Error $_ -ErrorAction Continue
    if ($Elevated) { Stop-Transcript | Out-Null }
    exit 1
}
