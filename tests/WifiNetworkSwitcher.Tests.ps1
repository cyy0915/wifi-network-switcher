BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..\WifiNetworkSwitcher.psm1') -Force

    function New-TestConfig {
        param([System.Collections.IDictionary]$Networks = ([ordered]@{}))
        [ordered]@{
            version = 1
            adapter = [ordered]@{ interfaceGuid = '{11111111-2222-3333-4444-555555555555}' }
            defaults = [ordered]@{
                ip = [ordered]@{ mode = 'dhcp' }
                dns = [ordered]@{ mode = 'static'; servers = @('198.18.0.2') }
            }
            networks = $Networks
        }
    }
}

Describe 'Wi-Fi network configuration model' {
    It 'accepts the default DHCP IP and static DNS configuration' {
        $config = Test-WnsConfigurationData (New-TestConfig)
        $config.Defaults.ip.mode | Should -Be 'dhcp'
        $config.Defaults.dns.servers | Should -Be @('198.18.0.2')
    }

    It 'matches SSIDs exactly and case-insensitively' {
        $networks = [ordered]@{
            'Office-WiFi' = [ordered]@{
                ip = [ordered]@{ mode = 'static'; address = '192.168.10.20/24'; gateway = '192.168.10.1' }
            }
        }
        $config = Test-WnsConfigurationData (New-TestConfig $networks)
        (Get-WnsPolicyForSsid $config 'office-wifi').RuleName | Should -Be 'Office-WiFi'
        (Get-WnsPolicyForSsid $config 'Office-WiFi-Guest').IsDefault | Should -BeTrue
    }

    It 'inherits unchanged sections from defaults' {
        $networks = [ordered]@{
            Office = [ordered]@{
                ip = [ordered]@{ mode = 'static'; address = '10.20.30.40/24'; gateway = '10.20.30.1' }
            }
        }
        $config = Test-WnsConfigurationData (New-TestConfig $networks)
        $policy = (Get-WnsPolicyForSsid $config Office).Policy
        $policy.ip.cidr | Should -Be '10.20.30.40/24'
        $policy.dns.servers | Should -Be @('198.18.0.2')
    }

    It 'drops static-only fields when a rule changes DNS mode to DHCP' {
        $networks = [ordered]@{ Hotel = [ordered]@{ dns = [ordered]@{ mode = 'dhcp' } } }
        $config = Test-WnsConfigurationData (New-TestConfig $networks)
        $policy = (Get-WnsPolicyForSsid $config Hotel).Policy
        $policy.ip.mode | Should -Be 'dhcp'
        $policy.dns.mode | Should -Be 'dhcp'
        $policy.dns.servers.Count | Should -Be 0
    }

    It 'supports an ordered static DNS list' {
        $networks = [ordered]@{
            Office = [ordered]@{ dns = [ordered]@{ mode = 'static'; servers = @('10.0.0.2', '198.18.0.2') } }
        }
        $config = Test-WnsConfigurationData (New-TestConfig $networks)
        (Get-WnsPolicyForSsid $config Office).Policy.dns.servers | Should -Be @('10.0.0.2', '198.18.0.2')
    }

    It 'rejects static IPv4 combined with DHCP DNS after inheritance' {
        $data = New-TestConfig
        $data.defaults.dns = [ordered]@{ mode = 'dhcp' }
        $data.networks = [ordered]@{
            Office = [ordered]@{
                ip = [ordered]@{ mode = 'static'; address = '192.168.10.20/24'; gateway = '192.168.10.1' }
            }
        }
        { Test-WnsConfigurationData $data } | Should -Throw '*cannot combine static IPv4 with DHCP DNS*'
    }

    It 'rejects static IPv4 combined with explicitly selected DHCP DNS' {
        $networks = [ordered]@{
            Office = [ordered]@{
                ip = [ordered]@{ mode = 'static'; address = '192.168.10.20/24'; gateway = '192.168.10.1' }
                dns = [ordered]@{ mode = 'dhcp' }
            }
        }
        { Test-WnsConfigurationData (New-TestConfig $networks) } |
            Should -Throw '*cannot combine static IPv4 with DHCP DNS*'
    }

    It 'rejects unknown fields' {
        $data = New-TestConfig
        $data.defaults.ip.command = 'anything'
        { Test-WnsConfigurationData $data } | Should -Throw '*unknown field*'
    }

    It 'rejects invalid CIDR, off-subnet gateways, duplicate DNS, and duplicate SSIDs' {
        $cases = @(
            [ordered]@{ Bad = [ordered]@{ ip = [ordered]@{ mode = 'static'; address = '10.0.0.2/99'; gateway = '10.0.0.1' } } },
            [ordered]@{ Bad = [ordered]@{ ip = [ordered]@{ mode = 'static'; address = '10.0.0.2/24'; gateway = '10.0.1.1' } } },
            [ordered]@{ Bad = [ordered]@{ dns = [ordered]@{ mode = 'static'; servers = @('1.1.1.1', '1.1.1.1') } } }
        )
        foreach ($networks in $cases) {
            { Test-WnsConfigurationData (New-TestConfig $networks) } | Should -Throw
        }
        $caseSensitiveNetworks = [System.Collections.Specialized.OrderedDictionary]::new([StringComparer]::Ordinal)
        $caseSensitiveNetworks.Add('Office', [ordered]@{})
        $caseSensitiveNetworks.Add('OFFICE', [ordered]@{})
        { Test-WnsConfigurationData (New-TestConfig $caseSensitiveNetworks) } | Should -Throw '*duplicate SSID*'
    }
}

Describe 'Desired-state comparison' {
    It 'recognizes matching static state' {
        $state = [pscustomobject]@{
            DhcpEnabled = $false
            Addresses = @([pscustomobject]@{ IPAddress = '192.168.1.20'; PrefixLength = 24; PrefixOrigin = 'Manual' })
            Routes = @([pscustomobject]@{ NextHop = '192.168.1.1' })
            DnsServers = @('1.1.1.1', '8.8.8.8')
            DnsOverride = '1.1.1.1,8.8.8.8'
        }
        $policy = [ordered]@{
            ip = [ordered]@{ mode = 'static'; address = '192.168.1.20'; prefixLength = 24; gateway = '192.168.1.1' }
            dns = [ordered]@{ mode = 'static'; servers = @('1.1.1.1', '8.8.8.8') }
        }
        (Test-WnsDesiredState $state $policy) | Should -BeTrue
    }

    It 'recognizes DHCP mode only when no static DNS override remains' {
        $policy = [ordered]@{ ip = [ordered]@{ mode = 'dhcp' }; dns = [ordered]@{ mode = 'dhcp'; servers = @() } }
        $state = [pscustomobject]@{
            DhcpEnabled = $true
            Addresses = @([pscustomobject]@{ IPAddress = '192.168.1.20'; PrefixLength = 24; PrefixOrigin = 'Dhcp' })
            Routes = @(); DnsServers = @('192.168.1.1'); DnsOverride = ''
        }
        (Test-WnsDesiredState $state $policy) | Should -BeTrue
        $state.DnsOverride = '1.1.1.1'
        (Test-WnsDesiredState $state $policy) | Should -BeFalse
    }
}

Describe 'Transactional network application' {
    BeforeEach {
        $script:testAdapter = [pscustomobject]@{ ifIndex = 7; InterfaceGuid = '{11111111-2222-3333-4444-555555555555}'; Name = 'Test Wi-Fi' }
        $script:testPolicy = [ordered]@{
            ip = [ordered]@{ mode = 'dhcp' }
            dns = [ordered]@{ mode = 'static'; servers = @('198.18.0.2') }
        }
        $script:testSnapshot = [pscustomobject]@{
            DhcpEnabled = $true
            Addresses = @([pscustomobject]@{ IPAddress = '192.168.1.20'; PrefixLength = 24; PrefixOrigin = 'Dhcp' })
            Routes = @(); DnsServers = @('192.168.1.1'); DnsOverride = ''
        }
        $script:testLog = { param($Level, $Message) }
        Mock Get-WnsNetworkState -ModuleName WifiNetworkSwitcher { $script:testSnapshot }
        Mock Start-Sleep -ModuleName WifiNetworkSwitcher {}
        Mock Set-WnsPolicy -ModuleName WifiNetworkSwitcher {}
        Mock Restore-WnsNetworkState -ModuleName WifiNetworkSwitcher {}
        Mock Test-WnsIpDesiredState -ModuleName WifiNetworkSwitcher { $true }
        Mock Test-WnsDnsDesiredState -ModuleName WifiNetworkSwitcher { $true }
    }

    It 'does not write when the current state already matches' {
        Invoke-WnsPolicy -Adapter $script:testAdapter -Policy $script:testPolicy -Log $script:testLog | Out-Null
        Should -Invoke Set-WnsPolicy -ModuleName WifiNetworkSwitcher -Times 0
        Should -Invoke Restore-WnsNetworkState -ModuleName WifiNetworkSwitcher -Times 0
    }

    It 'restores the snapshot when applying a command fails' {
        Mock Test-WnsDnsDesiredState -ModuleName WifiNetworkSwitcher { $false }
        Mock Set-WnsPolicy -ModuleName WifiNetworkSwitcher { throw 'simulated apply failure' }
        { Invoke-WnsPolicy -Adapter $script:testAdapter -Policy $script:testPolicy -Log $script:testLog } |
            Should -Throw '*simulated apply failure*'
        Should -Invoke Restore-WnsNetworkState -ModuleName WifiNetworkSwitcher -Times 1 -ParameterFilter {
            -not $RestoreIp -and $RestoreDns
        }
    }

    It 'restores the snapshot when post-change verification never matches' {
        Mock Test-WnsDnsDesiredState -ModuleName WifiNetworkSwitcher { $false }
        { Invoke-WnsPolicy -Adapter $script:testAdapter -Policy $script:testPolicy -Log $script:testLog } |
            Should -Throw '*Post-change verification*'
        Should -Invoke Get-WnsNetworkState -ModuleName WifiNetworkSwitcher -Times 16
        Should -Invoke Restore-WnsNetworkState -ModuleName WifiNetworkSwitcher -Times 1
    }

    It 'changes only DNS when DHCP IP is already healthy' {
        $script:dnsChecks = 0
        Mock Test-WnsDnsDesiredState -ModuleName WifiNetworkSwitcher {
            $script:dnsChecks++
            return $script:dnsChecks -gt 1
        }
        Invoke-WnsPolicy -Adapter $script:testAdapter -Policy $script:testPolicy -Log $script:testLog | Out-Null
        Should -Invoke Set-WnsPolicy -ModuleName WifiNetworkSwitcher -Times 1 -ParameterFilter {
            -not $ChangeIp -and $ChangeDns
        }
        Should -Invoke Restore-WnsNetworkState -ModuleName WifiNetworkSwitcher -Times 0
    }
}

Describe 'Scheduled task security definition' {
    BeforeAll { $installer = Get-Content -LiteralPath (Join-Path $PSScriptRoot '..\install.ps1') -Raw }

    It 'runs as SYSTEM at highest privilege from ProgramData' {
        $installer | Should -Match '<UserId>S-1-5-18</UserId>'
        $installer | Should -Match '<RunLevel>HighestAvailable</RunLevel>'
        $installer | Should -Match 'Join-Path \$env:ProgramData ''WifiNetworkSwitcher'''
    }

    It 'contains WLAN, boot, logon, unlock, and resume triggers' {
        $installer | Should -Match 'EventID=8001'
        $installer | Should -Match '<BootTrigger>'
        $installer | Should -Match '<LogonTrigger>'
        $installer | Should -Match '<SessionStateChangeTrigger>'
        $installer | Should -Match 'Power-Troubleshooter'
    }

    It 'generates a safe DHCP IP and DHCP DNS configuration on first install' {
        $installer | Should -Not -Match '198\.18\.0\.2'
        $installer | Should -Match '(?s)defaults:\s+ip:\s+mode: dhcp\s+dns:\s+mode: dhcp'
    }
}

Describe 'IPv4 policy store cleanup' {
    It 'cleans persistent and active entries before recreating an address' {
        InModuleScope WifiNetworkSwitcher {
            Mock Get-NetRoute { @() }
            Mock Get-NetIPAddress { @() }
            Mock Remove-NetRoute {}
            Mock Remove-NetIPAddress {}
            Remove-WnsManagedIpv4 ([pscustomobject]@{ ifIndex = 7 })
            Should -Invoke Get-NetIPAddress -Times 1 -Exactly -ParameterFilter { $PolicyStore -eq 'PersistentStore' }
            Should -Invoke Get-NetIPAddress -Times 1 -Exactly -ParameterFilter { $PolicyStore -eq 'ActiveStore' }
            Should -Invoke Get-NetRoute -Times 1 -Exactly -ParameterFilter { $PolicyStore -eq 'PersistentStore' }
            Should -Invoke Get-NetRoute -Times 1 -Exactly -ParameterFilter { $PolicyStore -eq 'ActiveStore' }
        }
    }
}
