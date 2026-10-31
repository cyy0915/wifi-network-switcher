Set-StrictMode -Version Latest

$script:YamlModuleVersion = '0.4.12'
$script:MaxConfigBytes = 256KB
$script:NativeWifiLoaded = $false

function ConvertTo-WnsMap {
    param([AllowNull()]$Value)

    if ($null -eq $Value) { return $null }
    if ($Value -is [System.Collections.IDictionary]) {
        $result = [ordered]@{}
        foreach ($key in $Value.Keys) {
            $result[[string]$key] = ConvertTo-WnsMap $Value[$key]
        }
        return $result
    }
    if (($Value -is [System.Collections.IEnumerable]) -and -not ($Value -is [string])) {
        $items = @($Value | ForEach-Object { ConvertTo-WnsMap $_ })
        Write-Output -NoEnumerate $items
        return
    }
    return $Value
}

function Assert-WnsMap {
    param($Value, [string]$Path, [switch]$AllowNull)
    if ($AllowNull -and $null -eq $Value) { return }
    if ($Value -isnot [System.Collections.IDictionary]) {
        throw "$Path must be a YAML mapping."
    }
}

function Assert-WnsAllowedKeys {
    param(
        [System.Collections.IDictionary]$Map,
        [string[]]$Allowed,
        [string]$Path
    )
    foreach ($key in $Map.Keys) {
        if ($Allowed -notcontains [string]$key) {
            throw "$Path contains unknown field '$key'. Allowed fields: $($Allowed -join ', ')."
        }
    }
}

function Test-WnsIPv4 {
    param([AllowNull()]$Value)
    $parsed = $null
    return ($Value -is [string]) -and
        [System.Net.IPAddress]::TryParse($Value, [ref]$parsed) -and
        $parsed.AddressFamily -eq [System.Net.Sockets.AddressFamily]::InterNetwork
}

function Convert-WnsIPv4ToUInt32 {
    param([Parameter(Mandatory)][string]$Address)
    $bytes = [System.Net.IPAddress]::Parse($Address).GetAddressBytes()
    return [uint32](
        ([uint32]$bytes[0] -shl 24) -bor
        ([uint32]$bytes[1] -shl 16) -bor
        ([uint32]$bytes[2] -shl 8) -bor
        [uint32]$bytes[3]
    )
}

function Test-WnsSameSubnet {
    param(
        [Parameter(Mandatory)][string]$Address,
        [Parameter(Mandatory)][string]$Gateway,
        [Parameter(Mandatory)][int]$PrefixLength
    )
    $mask = if ($PrefixLength -eq 0) { [uint32]0 } else { [uint32]::MaxValue -shl (32 - $PrefixLength) }
    return ((Convert-WnsIPv4ToUInt32 $Address) -band $mask) -eq
        ((Convert-WnsIPv4ToUInt32 $Gateway) -band $mask)
}

function Convert-WnsCidr {
    param([Parameter(Mandatory)][string]$Cidr, [string]$Path = 'address')
    if ($Cidr -notmatch '^([^/]+)/([0-9]{1,2})$') {
        throw "$Path must use IPv4 CIDR notation, for example 192.168.10.20/24."
    }
    $address = $Matches[1]
    $prefix = [int]$Matches[2]
    if (-not (Test-WnsIPv4 $address)) { throw "$Path contains an invalid IPv4 address '$address'." }
    if ($prefix -lt 1 -or $prefix -gt 32) { throw "$Path prefix length must be between 1 and 32." }
    [pscustomobject]@{ Address = $address; PrefixLength = $prefix }
}

function Merge-WnsMap {
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary]$Base,
        [AllowNull()][System.Collections.IDictionary]$Override
    )
    $result = [ordered]@{}
    foreach ($key in $Base.Keys) { $result[$key] = ConvertTo-WnsMap $Base[$key] }
    if ($null -ne $Override) {
        foreach ($key in $Override.Keys) {
            if (($result[$key] -is [System.Collections.IDictionary]) -and
                ($Override[$key] -is [System.Collections.IDictionary])) {
                $baseSection = $result[$key]
                $overrideSection = $Override[$key]
                $modeChanged = $baseSection.Contains('mode') -and $overrideSection.Contains('mode') -and
                    -not [string]::Equals([string]$baseSection.mode, [string]$overrideSection.mode, [StringComparison]::OrdinalIgnoreCase)
                $result[$key] = if ($modeChanged) { ConvertTo-WnsMap $overrideSection } else { Merge-WnsMap $baseSection $overrideSection }
            } else {
                $result[$key] = ConvertTo-WnsMap $Override[$key]
            }
        }
    }
    return $result
}

function Test-WnsIpPolicy {
    param([System.Collections.IDictionary]$Ip, [string]$Path)
    Assert-WnsMap $Ip $Path
    Assert-WnsAllowedKeys $Ip @('mode', 'address', 'gateway') $Path
    if (-not $Ip.Contains('mode') -or $Ip.mode -isnot [string]) { throw "$Path.mode is required and must be a string." }
    $mode = $Ip.mode.ToLowerInvariant()
    if ($mode -notin @('dhcp', 'static')) { throw "$Path.mode must be 'dhcp' or 'static'." }
    if ($mode -eq 'dhcp') {
        if ($Ip.Contains('address') -or $Ip.Contains('gateway')) {
            throw "$Path in DHCP mode cannot contain address or gateway."
        }
        return [ordered]@{ mode = 'dhcp' }
    }
    if (-not $Ip.Contains('address') -or $Ip.address -isnot [string]) { throw "$Path.address is required for static mode." }
    if (-not $Ip.Contains('gateway') -or $Ip.gateway -isnot [string]) { throw "$Path.gateway is required for static mode." }
    $cidr = Convert-WnsCidr $Ip.address "$Path.address"
    if (-not (Test-WnsIPv4 $Ip.gateway)) { throw "$Path.gateway '$($Ip.gateway)' is not a valid IPv4 address." }
    if (-not (Test-WnsSameSubnet $cidr.Address $Ip.gateway $cidr.PrefixLength)) {
        throw "$Path.gateway '$($Ip.gateway)' is not in the subnet defined by '$($Ip.address)'."
    }
    return [ordered]@{
        mode = 'static'
        address = $cidr.Address
        prefixLength = $cidr.PrefixLength
        cidr = "$($cidr.Address)/$($cidr.PrefixLength)"
        gateway = [string]$Ip.gateway
    }
}

function Test-WnsDnsPolicy {
    param([System.Collections.IDictionary]$Dns, [string]$Path)
    Assert-WnsMap $Dns $Path
    Assert-WnsAllowedKeys $Dns @('mode', 'servers') $Path
    if (-not $Dns.Contains('mode') -or $Dns.mode -isnot [string]) { throw "$Path.mode is required and must be a string." }
    $mode = $Dns.mode.ToLowerInvariant()
    if ($mode -notin @('dhcp', 'static')) { throw "$Path.mode must be 'dhcp' or 'static'." }
    if ($mode -eq 'dhcp') {
        if ($Dns.Contains('servers')) { throw "$Path in DHCP mode cannot contain servers." }
        return [ordered]@{ mode = 'dhcp'; servers = @() }
    }
    if (-not $Dns.Contains('servers')) { throw "$Path.servers is required for static mode." }
    if (($Dns.servers -is [string]) -or ($Dns.servers -isnot [System.Collections.IEnumerable])) {
        throw "$Path.servers must be a YAML list."
    }
    $servers = @($Dns.servers)
    if ($servers.Count -eq 0) { throw "$Path.servers must contain at least one IPv4 address." }
    $seen = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($server in $servers) {
        if (-not (Test-WnsIPv4 $server)) { throw "$Path.servers contains invalid IPv4 address '$server'." }
        if (-not $seen.Add([string]$server)) { throw "$Path.servers contains duplicate address '$server'." }
    }
    return [ordered]@{ mode = 'static'; servers = @($servers | ForEach-Object { [string]$_ }) }
}

function Resolve-WnsPolicy {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary]$Defaults,
        [AllowNull()][System.Collections.IDictionary]$Override,
        [string]$Path = 'policy'
    )
    $merged = Merge-WnsMap $Defaults $Override
    Assert-WnsAllowedKeys $merged @('ip', 'dns') $Path
    if (-not $merged.Contains('ip')) { throw "$Path.ip is required after inheritance." }
    if (-not $merged.Contains('dns')) { throw "$Path.dns is required after inheritance." }
    $ipPolicy = Test-WnsIpPolicy $merged.ip "$Path.ip"
    $dnsPolicy = Test-WnsDnsPolicy $merged.dns "$Path.dns"
    if ($ipPolicy.mode -eq 'static' -and $dnsPolicy.mode -eq 'dhcp') {
        throw "$Path cannot combine static IPv4 with DHCP DNS. Configure dns.mode as 'static' and provide one or more DNS server addresses."
    }
    return [ordered]@{
        ip = $ipPolicy
        dns = $dnsPolicy
    }
}

function Test-WnsConfigurationData {
    [CmdletBinding()]
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Data)

    Assert-WnsAllowedKeys $Data @('version', 'adapter', 'defaults', 'networks') 'root'
    if (-not $Data.Contains('version') -or [int]$Data.version -ne 1 -or "$($Data.version)" -ne '1') {
        throw 'root.version must be integer 1.'
    }
    if (-not $Data.Contains('adapter')) { throw 'root.adapter is required.' }
    Assert-WnsMap $Data.adapter 'root.adapter'
    Assert-WnsAllowedKeys $Data.adapter @('interfaceGuid') 'root.adapter'
    $guid = [guid]::Empty
    if (-not $Data.adapter.Contains('interfaceGuid') -or
        $Data.adapter.interfaceGuid -isnot [string] -or
        -not [guid]::TryParse($Data.adapter.interfaceGuid, [ref]$guid) -or
        $guid -eq [guid]::Empty) {
        throw 'root.adapter.interfaceGuid must be a non-empty GUID string.'
    }
    if (-not $Data.Contains('defaults')) { throw 'root.defaults is required.' }
    Assert-WnsMap $Data.defaults 'root.defaults'
    $defaults = Resolve-WnsPolicy $Data.defaults $null 'root.defaults'

    $networks = [ordered]@{}
    if ($Data.Contains('networks') -and $null -ne $Data.networks) {
        Assert-WnsMap $Data.networks 'root.networks'
        $seenSsid = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
        foreach ($ssidValue in $Data.networks.Keys) {
            $ssid = [string]$ssidValue
            if ([string]::IsNullOrWhiteSpace($ssid)) { throw 'root.networks contains an empty SSID.' }
            if ([Text.Encoding]::UTF8.GetByteCount($ssid) -gt 32) { throw "SSID '$ssid' exceeds 32 UTF-8 bytes." }
            if (-not $seenSsid.Add($ssid)) { throw "root.networks contains case-insensitive duplicate SSID '$ssid'." }
            $rule = $Data.networks[$ssidValue]
            Assert-WnsMap $rule "root.networks['$ssid']"
            Assert-WnsAllowedKeys $rule @('ip', 'dns') "root.networks['$ssid']"
            foreach ($section in @('ip', 'dns')) {
                if ($rule.Contains($section)) {
                    Assert-WnsMap $rule[$section] "root.networks['$ssid'].$section"
                    $allowed = if ($section -eq 'ip') { @('mode', 'address', 'gateway') } else { @('mode', 'servers') }
                    Assert-WnsAllowedKeys $rule[$section] $allowed "root.networks['$ssid'].$section"
                }
            }
            $networks[$ssid] = [ordered]@{
                raw = ConvertTo-WnsMap $rule
                resolved = Resolve-WnsPolicy $Data.defaults $rule "root.networks['$ssid']"
            }
        }
    }
    [pscustomobject]@{
        Version = 1
        InterfaceGuid = $guid
        DefaultsRaw = ConvertTo-WnsMap $Data.defaults
        Defaults = $defaults
        Networks = $networks
    }
}

function Read-WnsConfiguration {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)
    $file = Get-Item -LiteralPath $Path -ErrorAction Stop
    if ($file.Length -gt $script:MaxConfigBytes) { throw "Configuration exceeds the $script:MaxConfigBytes byte limit." }
    Import-Module powershell-yaml -RequiredVersion $script:YamlModuleVersion -ErrorAction Stop
    $raw = [IO.File]::ReadAllText($file.FullName, [Text.UTF8Encoding]::new($false, $true))
    if ([string]::IsNullOrWhiteSpace($raw)) { throw 'Configuration file is empty.' }
    $parsed = ConvertFrom-Yaml -Yaml $raw -Ordered -ErrorAction Stop
    $data = ConvertTo-WnsMap $parsed
    Assert-WnsMap $data 'root'
    return Test-WnsConfigurationData $data
}

function Get-WnsPolicyForSsid {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Configuration,
        [Parameter(Mandatory)][string]$Ssid
    )
    foreach ($key in $Configuration.Networks.Keys) {
        if ([string]::Equals($key, $Ssid, [StringComparison]::OrdinalIgnoreCase)) {
            return [pscustomobject]@{ RuleName = $key; IsDefault = $false; Policy = $Configuration.Networks[$key].resolved }
        }
    }
    return [pscustomobject]@{ RuleName = 'defaults'; IsDefault = $true; Policy = $Configuration.Defaults }
}

function Initialize-WnsNativeWifi {
    if ($script:NativeWifiLoaded) { return }
    if ('WifiNetworkSwitcher.NativeWifi' -as [type]) { $script:NativeWifiLoaded = $true; return }
    $source = @'
using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Text;

namespace WifiNetworkSwitcher {
    public sealed class WlanInterfaceInfo {
        public Guid InterfaceGuid { get; set; }
        public string Description { get; set; }
        public int State { get; set; }
        public string Ssid { get; set; }
    }

    public static class NativeWifi {
        [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
        private struct WLAN_INTERFACE_INFO {
            public Guid InterfaceGuid;
            [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 256)] public string Description;
            public int State;
        }

        [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
        private struct WLAN_CONNECTION_ATTRIBUTES {
            public int InterfaceState;
            public int ConnectionMode;
            [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 256)] public string ProfileName;
            public WLAN_ASSOCIATION_ATTRIBUTES Association;
            public WLAN_SECURITY_ATTRIBUTES Security;
        }

        [StructLayout(LayoutKind.Sequential)]
        private struct DOT11_SSID {
            public uint Length;
            [MarshalAs(UnmanagedType.ByValArray, SizeConst = 32)] public byte[] Bytes;
        }

        [StructLayout(LayoutKind.Sequential)]
        private struct WLAN_ASSOCIATION_ATTRIBUTES {
            public DOT11_SSID Ssid;
            public int BssType;
            [MarshalAs(UnmanagedType.ByValArray, SizeConst = 6)] public byte[] Bssid;
            public int PhyType;
            public uint PhyIndex;
            public uint SignalQuality;
            public uint RxRate;
            public uint TxRate;
        }

        [StructLayout(LayoutKind.Sequential)]
        private struct WLAN_SECURITY_ATTRIBUTES {
            [MarshalAs(UnmanagedType.Bool)] public bool SecurityEnabled;
            [MarshalAs(UnmanagedType.Bool)] public bool OneXEnabled;
            public int AuthAlgorithm;
            public int CipherAlgorithm;
        }

        [DllImport("wlanapi.dll")]
        private static extern uint WlanOpenHandle(uint clientVersion, IntPtr reserved, out uint negotiatedVersion, out IntPtr clientHandle);
        [DllImport("wlanapi.dll")]
        private static extern uint WlanCloseHandle(IntPtr clientHandle, IntPtr reserved);
        [DllImport("wlanapi.dll")]
        private static extern uint WlanEnumInterfaces(IntPtr clientHandle, IntPtr reserved, out IntPtr interfaceList);
        [DllImport("wlanapi.dll")]
        private static extern uint WlanQueryInterface(IntPtr clientHandle, ref Guid interfaceGuid, int opcode, IntPtr reserved, out uint dataSize, out IntPtr data, out int opcodeValueType);
        [DllImport("wlanapi.dll")]
        private static extern void WlanFreeMemory(IntPtr memory);

        private static string ReadSsid(IntPtr handle, Guid guid, int state) {
            if (state != 1) return null; // wlan_interface_state_connected
            IntPtr data = IntPtr.Zero;
            try {
                uint size;
                int valueType;
                uint result = WlanQueryInterface(handle, ref guid, 7, IntPtr.Zero, out size, out data, out valueType);
                if (result != 0 || data == IntPtr.Zero) return null;
                WLAN_CONNECTION_ATTRIBUTES attributes = Marshal.PtrToStructure<WLAN_CONNECTION_ATTRIBUTES>(data);
                int length = Math.Min((int)attributes.Association.Ssid.Length, 32);
                return Encoding.UTF8.GetString(attributes.Association.Ssid.Bytes, 0, length);
            } finally {
                if (data != IntPtr.Zero) WlanFreeMemory(data);
            }
        }

        public static WlanInterfaceInfo[] GetInterfaces() {
            IntPtr handle = IntPtr.Zero;
            IntPtr list = IntPtr.Zero;
            try {
                uint negotiated;
                uint result = WlanOpenHandle(2, IntPtr.Zero, out negotiated, out handle);
                if (result != 0) throw new Win32Exception((int)result, "WlanOpenHandle failed");
                result = WlanEnumInterfaces(handle, IntPtr.Zero, out list);
                if (result != 0) throw new Win32Exception((int)result, "WlanEnumInterfaces failed");
                int count = Marshal.ReadInt32(list, 0);
                long offset = 8;
                int itemSize = Marshal.SizeOf<WLAN_INTERFACE_INFO>();
                var output = new List<WlanInterfaceInfo>();
                for (int i = 0; i < count; i++) {
                    IntPtr itemPtr = new IntPtr(list.ToInt64() + offset + (long)i * itemSize);
                    WLAN_INTERFACE_INFO item = Marshal.PtrToStructure<WLAN_INTERFACE_INFO>(itemPtr);
                    output.Add(new WlanInterfaceInfo {
                        InterfaceGuid = item.InterfaceGuid,
                        Description = item.Description,
                        State = item.State,
                        Ssid = ReadSsid(handle, item.InterfaceGuid, item.State)
                    });
                }
                return output.ToArray();
            } finally {
                if (list != IntPtr.Zero) WlanFreeMemory(list);
                if (handle != IntPtr.Zero) WlanCloseHandle(handle, IntPtr.Zero);
            }
        }
    }
}
'@
    Add-Type -TypeDefinition $source -Language CSharp -ErrorAction Stop
    $script:NativeWifiLoaded = $true
}

function Get-WnsWlanInterfaces {
    [CmdletBinding()]
    param()
    Initialize-WnsNativeWifi
    return [WifiNetworkSwitcher.NativeWifi]::GetInterfaces()
}

function Get-WnsConnectedSsid {
    [CmdletBinding()]
    param([Parameter(Mandatory)][guid]$InterfaceGuid)
    $interface = @(Get-WnsWlanInterfaces | Where-Object InterfaceGuid -eq $InterfaceGuid)
    if ($interface.Count -eq 0) { throw "Wi-Fi interface $InterfaceGuid was not found by the Native Wi-Fi API." }
    if ($interface.Count -gt 1) { throw "Native Wi-Fi API returned duplicate interface GUID $InterfaceGuid." }
    return $interface[0].Ssid
}

function Get-WnsAdapter {
    param([Parameter(Mandatory)][guid]$InterfaceGuid)
    $adapter = @(Get-NetAdapter -ErrorAction Stop | Where-Object { [guid]$_.InterfaceGuid -eq $InterfaceGuid })
    if ($adapter.Count -ne 1) { throw "Configured adapter $InterfaceGuid was not found exactly once." }
    $native = @(Get-WnsWlanInterfaces | Where-Object InterfaceGuid -eq $InterfaceGuid)
    if ($native.Count -ne 1) { throw "Configured adapter $InterfaceGuid is not a Native Wi-Fi interface." }
    if ($adapter[0].Status -eq 'Disabled') { throw "Configured Wi-Fi adapter '$($adapter[0].Name)' is disabled." }
    return $adapter[0]
}

function Get-WnsDnsOverride {
    param([Parameter(Mandatory)][guid]$InterfaceGuid)
    $path = "Registry::HKEY_LOCAL_MACHINE\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters\Interfaces\{$InterfaceGuid}"
    $value = $null
    if (Test-Path -LiteralPath $path) {
        $properties = Get-ItemProperty -LiteralPath $path -ErrorAction Stop
        if ($properties.PSObject.Properties.Name -contains 'NameServer') { $value = $properties.NameServer }
    }
    return [string]$value
}

function Get-WnsNetworkState {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Adapter)
    $index = [uint32]$Adapter.ifIndex
    $ipInterface = Get-NetIPInterface -InterfaceIndex $index -AddressFamily IPv4 -ErrorAction Stop
    $addresses = @(Get-NetIPAddress -InterfaceIndex $index -AddressFamily IPv4 -ErrorAction SilentlyContinue |
        Where-Object { $_.IPAddress -notlike '169.254.*' -and $_.IPAddress -ne '127.0.0.1' } |
        Select-Object IPAddress, PrefixLength, PrefixOrigin, SuffixOrigin, AddressState, PolicyStore)
    $routes = @(Get-NetRoute -InterfaceIndex $index -AddressFamily IPv4 -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue |
        Select-Object DestinationPrefix, NextHop, RouteMetric, Protocol, PolicyStore)
    $dns = @(Get-DnsClientServerAddress -InterfaceIndex $index -AddressFamily IPv4 -ErrorAction Stop).ServerAddresses
    [pscustomobject]@{
        DhcpEnabled = $ipInterface.Dhcp -eq 'Enabled'
        Addresses = $addresses
        Routes = $routes
        DnsServers = @($dns)
        DnsOverride = Get-WnsDnsOverride ([guid]$Adapter.InterfaceGuid)
    }
}

function Test-WnsStringArrayEqual {
    param([string[]]$Left, [string[]]$Right)
    if ($Left.Count -ne $Right.Count) { return $false }
    for ($i = 0; $i -lt $Left.Count; $i++) {
        if (-not [string]::Equals($Left[$i], $Right[$i], [StringComparison]::OrdinalIgnoreCase)) { return $false }
    }
    return $true
}

function Test-WnsIpDesiredState {
    param($State, [System.Collections.IDictionary]$Policy)
    if ($Policy.ip.mode -eq 'dhcp') {
        if (-not $State.DhcpEnabled) { return $false }
        if (@($State.Addresses | Where-Object PrefixOrigin -eq 'Manual').Count -gt 0) { return $false }
        if (@($State.Addresses).Count -eq 0) { return $false }
    } else {
        if ($State.DhcpEnabled) { return $false }
        $matching = @($State.Addresses | Where-Object {
            $_.IPAddress -eq $Policy.ip.address -and [int]$_.PrefixLength -eq [int]$Policy.ip.prefixLength
        })
        if ($matching.Count -ne 1 -or $State.Addresses.Count -ne 1) { return $false }
        $gateway = @($State.Routes | Where-Object NextHop -eq $Policy.ip.gateway)
        if ($gateway.Count -lt 1) { return $false }
    }
    return $true
}

function Test-WnsDnsDesiredState {
    param($State, [System.Collections.IDictionary]$Policy)
    if ($Policy.dns.mode -eq 'dhcp') {
        return [string]::IsNullOrWhiteSpace($State.DnsOverride)
    }
    return (Test-WnsStringArrayEqual @($State.DnsServers) @($Policy.dns.servers)) -and
        (-not [string]::IsNullOrWhiteSpace($State.DnsOverride))
}

function Test-WnsDesiredState {
    param($State, [System.Collections.IDictionary]$Policy)
    return (Test-WnsIpDesiredState $State $Policy) -and (Test-WnsDnsDesiredState $State $Policy)
}

function Remove-WnsManagedIpv4 {
    param([Parameter(Mandatory)]$Adapter)
    $index = [uint32]$Adapter.ifIndex
    # New-NetIPAddress writes to both stores by default. Remove persistent entries
    # first, then re-query active entries (persistent deletion may propagate).
    foreach ($store in @('PersistentStore', 'ActiveStore')) {
        Get-NetRoute -InterfaceIndex $index -AddressFamily IPv4 -PolicyStore $store -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue |
            Remove-NetRoute -Confirm:$false -ErrorAction Stop
        Get-NetIPAddress -InterfaceIndex $index -AddressFamily IPv4 -PolicyStore $store -ErrorAction SilentlyContinue |
            Where-Object { $_.IPAddress -notlike '169.254.*' -and $_.IPAddress -ne '127.0.0.1' } |
            Remove-NetIPAddress -Confirm:$false -ErrorAction Stop
    }
}

function Set-WnsPolicy {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Adapter,
        [Parameter(Mandatory)][System.Collections.IDictionary]$Policy,
        [switch]$ChangeIp,
        [switch]$ChangeDns
    )
    $index = [uint32]$Adapter.ifIndex
    if ($ChangeIp) {
        if ($Policy.ip.mode -eq 'dhcp') {
            $currentIpInterface = Get-NetIPInterface -InterfaceIndex $index -AddressFamily IPv4 -ErrorAction Stop
            if ($currentIpInterface.Dhcp -ne 'Enabled') {
                Remove-WnsManagedIpv4 $Adapter
                Set-NetIPInterface -InterfaceIndex $index -AddressFamily IPv4 -Dhcp Enabled -ErrorAction Stop
            }
            & ipconfig.exe /renew $Adapter.Name | Out-Null
            if ($LASTEXITCODE -ne 0) { throw "ipconfig /renew failed for '$($Adapter.Name)' with exit code $LASTEXITCODE." }
        } else {
            Set-NetIPInterface -InterfaceIndex $index -AddressFamily IPv4 -Dhcp Disabled -ErrorAction Stop
            Remove-WnsManagedIpv4 $Adapter
            New-NetIPAddress -InterfaceIndex $index -AddressFamily IPv4 -IPAddress $Policy.ip.address `
                -PrefixLength $Policy.ip.prefixLength -DefaultGateway $Policy.ip.gateway -ErrorAction Stop | Out-Null
        }
    }
    if ($ChangeDns) {
        if ($Policy.dns.mode -eq 'dhcp') {
            Set-DnsClientServerAddress -InterfaceIndex $index -ResetServerAddresses -ErrorAction Stop
        } else {
            Set-DnsClientServerAddress -InterfaceIndex $index -ServerAddresses @($Policy.dns.servers) -ErrorAction Stop
        }
    }
}

function Restore-WnsNetworkState {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Adapter,
        [Parameter(Mandatory)]$Snapshot,
        [switch]$RestoreIp,
        [switch]$RestoreDns
    )
    $index = [uint32]$Adapter.ifIndex
    if ($RestoreIp) {
        Remove-WnsManagedIpv4 $Adapter
        if ($Snapshot.DhcpEnabled) {
            Set-NetIPInterface -InterfaceIndex $index -AddressFamily IPv4 -Dhcp Enabled -ErrorAction Stop
            & ipconfig.exe /renew $Adapter.Name | Out-Null
        } else {
            Set-NetIPInterface -InterfaceIndex $index -AddressFamily IPv4 -Dhcp Disabled -ErrorAction Stop
            foreach ($address in $Snapshot.Addresses) {
                New-NetIPAddress -InterfaceIndex $index -AddressFamily IPv4 -IPAddress $address.IPAddress `
                    -PrefixLength $address.PrefixLength -ErrorAction Stop | Out-Null
            }
            foreach ($route in $Snapshot.Routes) {
                New-NetRoute -InterfaceIndex $index -AddressFamily IPv4 -DestinationPrefix '0.0.0.0/0' `
                    -NextHop $route.NextHop -RouteMetric $route.RouteMetric -ErrorAction Stop | Out-Null
            }
        }
    }
    if ($RestoreDns) {
        if ([string]::IsNullOrWhiteSpace($Snapshot.DnsOverride)) {
            Set-DnsClientServerAddress -InterfaceIndex $index -ResetServerAddresses -ErrorAction Stop
        } elseif ($Snapshot.DnsServers.Count -gt 0) {
            Set-DnsClientServerAddress -InterfaceIndex $index -ServerAddresses @($Snapshot.DnsServers) -ErrorAction Stop
        }
    }
}

function Invoke-WnsPolicy {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Adapter,
        [Parameter(Mandatory)][System.Collections.IDictionary]$Policy,
        [Parameter(Mandatory)][scriptblock]$Log
    )
    $timer = [Diagnostics.Stopwatch]::StartNew()
    $snapshot = Get-WnsNetworkState $Adapter
    & $Log 'INFO' "Snapshot read in $($timer.ElapsedMilliseconds) ms. DHCP=$($snapshot.DhcpEnabled); addresses=$(@($snapshot.Addresses).Count); gateways=$(@($snapshot.Routes).Count)."
    $changeIp = -not (Test-WnsIpDesiredState $snapshot $Policy)
    $changeDns = -not (Test-WnsDnsDesiredState $snapshot $Policy)
    if (-not $changeIp -and -not $changeDns) {
        & $Log 'INFO' 'Network state already matches the desired policy; no changes are required.'
        return $snapshot
    }
    $changes = @()
    if ($changeIp) { $changes += "IPv4 mode '$($Policy.ip.mode)'" }
    if ($changeDns) { $changes += "DNS mode '$($Policy.dns.mode)'" }
    & $Log 'INFO' "Applying $($changes -join ' and ')."
    try {
        $timer.Restart()
        Set-WnsPolicy $Adapter $Policy -ChangeIp:$changeIp -ChangeDns:$changeDns
        & $Log 'INFO' "Network writes completed in $($timer.ElapsedMilliseconds) ms."
        $timer.Restart()
        $verified = $false
        $current = $null
        foreach ($attempt in 1..15) {
            if ($attempt -gt 1) { Start-Sleep -Seconds 2 }
            $current = Get-WnsNetworkState $Adapter
            if (Test-WnsDesiredState $current $Policy) { $verified = $true; break }
        }
        if (-not $verified) { throw 'Post-change verification did not match the desired IPv4/DNS state.' }
        & $Log 'INFO' "Network state was applied and verified successfully in $($timer.ElapsedMilliseconds) ms."
        return $current
    } catch {
        $originalError = $_
        & $Log 'ERROR' "Apply or verification failed: $($originalError.Exception.Message)"
        try {
            Restore-WnsNetworkState $Adapter $snapshot -RestoreIp:$changeIp -RestoreDns:$changeDns
            & $Log 'WARN' "The changed portion of the pre-change network snapshot was restored. IPv4=$changeIp; DNS=$changeDns."
        } catch {
            & $Log 'ERROR' "Rollback also failed: $($_.Exception.Message)"
        }
        throw $originalError
    }
}

function Invoke-WnsRestoreDhcp {
    [CmdletBinding()]
    param([Parameter(Mandatory)][guid]$InterfaceGuid, [Parameter(Mandatory)][scriptblock]$Log)
    $adapter = Get-WnsAdapter $InterfaceGuid
    $policy = [ordered]@{ ip = [ordered]@{ mode = 'dhcp' }; dns = [ordered]@{ mode = 'dhcp'; servers = @() } }
    Invoke-WnsPolicy $adapter $policy $Log
}

Export-ModuleMember -Function @(
    'Read-WnsConfiguration', 'Test-WnsConfigurationData', 'Resolve-WnsPolicy',
    'Get-WnsPolicyForSsid', 'Get-WnsWlanInterfaces', 'Get-WnsConnectedSsid',
    'Get-WnsAdapter', 'Get-WnsNetworkState', 'Test-WnsIpDesiredState',
    'Test-WnsDnsDesiredState', 'Test-WnsDesiredState',
    'Invoke-WnsPolicy', 'Invoke-WnsRestoreDhcp'
)
