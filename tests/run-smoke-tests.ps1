[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '..\WifiNetworkSwitcher.psm1') -Force

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw "Smoke test failed: $Message" }
}

$data = [ordered]@{
    version = 1
    adapter = [ordered]@{ interfaceGuid = '{11111111-2222-3333-4444-555555555555}' }
    defaults = [ordered]@{
        ip = [ordered]@{ mode = 'dhcp' }
        dns = [ordered]@{ mode = 'static'; servers = @('198.18.0.2') }
    }
    networks = [ordered]@{
        Office = [ordered]@{
            ip = [ordered]@{ mode = 'static'; address = '192.168.50.20/24'; gateway = '192.168.50.1' }
            dns = [ordered]@{ mode = 'static'; servers = @('192.168.50.2', '198.18.0.2') }
        }
        Hotel = [ordered]@{ dns = [ordered]@{ mode = 'dhcp' } }
    }
}

$config = Test-WnsConfigurationData $data
$office = Get-WnsPolicyForSsid $config 'OFFICE'
Assert-True (-not $office.IsDefault) 'SSID matching should be case-insensitive.'
Assert-True ($office.Policy.ip.cidr -eq '192.168.50.20/24') 'Static CIDR should be normalized.'
Assert-True ($office.Policy.dns.servers.Count -eq 2) 'Multiple DNS servers should be retained.'
$hotel = Get-WnsPolicyForSsid $config 'Hotel'
Assert-True ($hotel.Policy.ip.mode -eq 'dhcp') 'Hotel should inherit DHCP IP.'
Assert-True ($hotel.Policy.dns.mode -eq 'dhcp') 'Hotel should override static DNS with DHCP.'
$unknown = Get-WnsPolicyForSsid $config 'Unknown-WiFi'
Assert-True ($unknown.IsDefault -and $unknown.Policy.dns.servers[0] -eq '198.18.0.2') 'Unknown SSID should use defaults.'

$bad = [ordered]@{}
foreach ($key in $data.Keys) { $bad[$key] = $data[$key] }
$bad.networks = [ordered]@{ Bad = [ordered]@{ ip = [ordered]@{ mode = 'static'; address = '10.0.0.2/24'; gateway = '10.0.1.1' } } }
$threw = $false
try { Test-WnsConfigurationData $bad | Out-Null } catch { $threw = $true }
Assert-True $threw 'Off-subnet gateways must be rejected.'

$files = @('apply-now.ps1', 'install.ps1', 'uninstall.ps1', 'Invoke-WifiNetworkSwitcher.ps1', 'WifiNetworkSwitcher.psm1')
foreach ($name in $files) {
    $path = Join-Path $PSScriptRoot "..\$name"
    $tokens = $null
    $errors = $null
    [Management.Automation.Language.Parser]::ParseFile((Resolve-Path $path), [ref]$tokens, [ref]$errors) | Out-Null
    Assert-True ($errors.Count -eq 0) "$name must parse without PowerShell syntax errors."
}
Assert-True (Test-Path -LiteralPath (Join-Path $PSScriptRoot '..\WifiNetworkApply.cmd')) 'WifiNetworkApply.cmd must exist.'
Assert-True (-not (Test-Path -LiteralPath (Join-Path $PSScriptRoot '..\apply-now.cmd'))) 'The old apply-now.cmd name must not remain.'

Write-Host 'All smoke tests passed.'
