[CmdletBinding(DefaultParameterSetName = 'Apply')]
param(
    [Parameter(Mandatory)][string]$ConfigPath,
    [string]$Trigger = 'Manual',
    [Parameter(ParameterSetName = 'Validate')][switch]$ValidateOnly,
    [Parameter(ParameterSetName = 'Restore')][switch]$RestoreDhcp,
    [string]$LogDirectory = (Join-Path $PSScriptRoot 'logs')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$mutex = $null
$hasMutex = $false
$log = $null

function Rotate-Log {
    param([string]$Path)
    if ((Test-Path -LiteralPath $Path) -and (Get-Item -LiteralPath $Path).Length -ge 1MB) {
        for ($i = 4; $i -ge 1; $i--) {
            $source = "$Path.$i"
            $target = "$Path.$($i + 1)"
            if (Test-Path -LiteralPath $source) { Move-Item -LiteralPath $source -Destination $target -Force }
        }
        Move-Item -LiteralPath $Path -Destination "$Path.1" -Force
    }
}

try {
    New-Item -ItemType Directory -Path $LogDirectory -Force | Out-Null
    $logPath = Join-Path $LogDirectory 'switch.log'
    Rotate-Log $logPath
    $log = {
        param([string]$Level, [string]$Message)
        $line = '{0} [{1}] [{2}] {3}' -f ([DateTimeOffset]::Now.ToString('yyyy-MM-dd HH:mm:ss.fff zzz')), $Level, $Trigger, $Message
        [IO.File]::AppendAllText($logPath, $line + [Environment]::NewLine, [Text.UTF8Encoding]::new($false))
        Write-Host $line
    }

    & $log 'INFO' "Starting. ConfigPath='$ConfigPath'."
    Import-Module (Join-Path $PSScriptRoot 'WifiNetworkSwitcher.psm1') -Force -ErrorAction Stop
    $configuration = Read-WnsConfiguration -Path $ConfigPath
    & $log 'INFO' "Configuration validated. InterfaceGuid={$($configuration.InterfaceGuid)}."
    if ($ValidateOnly) { & $log 'INFO' 'Validation-only run completed.'; exit 0 }

    $mutexName = "Global\WifiNetworkSwitcher-$($configuration.InterfaceGuid.ToString('N'))"
    $mutex = [Threading.Mutex]::new($false, $mutexName)
    $hasMutex = $mutex.WaitOne([TimeSpan]::FromSeconds(90))
    if (-not $hasMutex) { throw 'Timed out waiting for another network switch operation to finish.' }

    if ($RestoreDhcp) {
        Invoke-WnsRestoreDhcp -InterfaceGuid $configuration.InterfaceGuid -Log $log | Out-Null
        & $log 'INFO' 'Explicit DHCP restore completed.'
        exit 0
    }

    if ($Trigger -notin @('Install', 'Manual', 'Validation')) { Start-Sleep -Seconds 2 }
    $adapter = Get-WnsAdapter $configuration.InterfaceGuid
    $ssid = $null
    foreach ($attempt in 1..5) {
        try { $ssid = Get-WnsConnectedSsid $configuration.InterfaceGuid } catch { if ($attempt -eq 5) { throw }; $ssid = $null }
        if (-not [string]::IsNullOrEmpty($ssid)) { break }
        if ($attempt -lt 5) { Start-Sleep -Seconds 2 }
    }
    if ([string]::IsNullOrEmpty($ssid)) {
        & $log 'INFO' "Adapter '$($adapter.Name)' is not connected to a Wi-Fi network; no changes were made."
        exit 0
    }
    $selection = Get-WnsPolicyForSsid -Configuration $configuration -Ssid $ssid
    & $log 'INFO' "SSID='$ssid'; matched rule='$($selection.RuleName)'; default=$($selection.IsDefault)."
    $state = Invoke-WnsPolicy -Adapter $adapter -Policy $selection.Policy -Log $log
    $addresses = @($state.Addresses | ForEach-Object { "$($_.IPAddress)/$($_.PrefixLength)" }) -join ', '
    $gateways = @($state.Routes | ForEach-Object { $_.NextHop }) -join ', '
    $dns = @($state.DnsServers) -join ', '
    & $log 'INFO' "Final state: DHCP=$($state.DhcpEnabled); IPv4=[$addresses]; Gateway=[$gateways]; DNS=[$dns]."
    exit 0
} catch {
    try {
        if ($null -ne $log) { & $log 'ERROR' $_.Exception.Message } else { Write-Error $_ }
    } catch { Write-Error $_ }
    exit 1
} finally {
    if ($hasMutex -and $null -ne $mutex) { $mutex.ReleaseMutex() }
    if ($null -ne $mutex) { $mutex.Dispose() }
}
