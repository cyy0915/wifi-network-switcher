# WiFi Network Switcher

根据当前连接的 Wi-Fi SSID，自动切换指定无线网卡的 IPv4 和 DNS 配置。
它适合需要在办公网络、家庭网络、酒店网络之间切换网络参数的 Windows 用户。

> English summary: WiFi Network Switcher is a Windows PowerShell 7 utility that
> applies per-SSID IPv4 and DNS policies through a protected SYSTEM scheduled
> task. It supports DHCP/static IPv4, DHCP/static DNS, transactional rollback,
> and configuration validation.

## 功能

- 按 SSID 不区分大小写地精确匹配规则；未知网络使用 `defaults`。
- 支持 IPv4 DHCP 或静态地址（CIDR + 网关）。
- 支持 DNS DHCP 或一个或多个静态 IPv4 DNS 服务器。
- 只修改实际需要变化的部分；例如只改 DNS 时不会重建正常的 DHCP 地址。
- 应用失败或核验失败时，回滚本次实际修改的网络状态。
- 以最高权限的 SYSTEM 计划任务运行，支持开机、登录、解锁、恢复和手动触发。
- 配置和运行代码安装到受保护的 `C:\ProgramData\WifiNetworkSwitcher`。
- 不修改 IPv6、代理、DoH、Wi-Fi 密码或自动连接顺序。

## 系统要求

- Windows 10/11，且当前账户可以批准 UAC 提权。
- PowerShell 7，默认安装路径为 `C:\Program Files\PowerShell\7\pwsh.exe`。
- 一个可管理的 Wi-Fi 网卡；安装时需要知道它的 `InterfaceGuid`。
- 安装器会以管理员权限安装固定版本的 `powershell-yaml`（0.4.12）。

## 快速开始

### 1. 获取项目

```powershell
git clone https://github.com/cyy0915/wifi-network-switcher.git
Set-Location .\wifi-network-switcher
```

如果你还没有本地配置，请先复制公开示例；如果已有正在使用的 `wifi-network-config.yaml`，不要执行这条复制命令：

```powershell
if (-not (Test-Path .\wifi-network-config.yaml)) {
    Copy-Item .\wifi-network-config.example.yaml .\wifi-network-config.yaml
}
```

### 2. 找到 Wi-Fi 网卡的 InterfaceGuid

在 PowerShell 中运行：

```powershell
Get-NetAdapter | Format-Table Name, Status, InterfaceDescription, InterfaceGuid
```

打开本地的 `wifi-network-config.yaml`，把 `adapter.interfaceGuid` 替换为目标 Wi-Fi 网卡的 GUID。公开仓库只包含 `wifi-network-config.example.yaml`；实际配置文件会被 Git 忽略，不会上传。

### 3. 编辑网络规则

`wifi-network-config.example.yaml` 默认对 IPv4 和 DNS 都使用 DHCP，不会把示例地址直接应用到网络。一个包含静态办公网络和 DHCP 酒店网络的配置如下：

```yaml
version: 1

adapter:
  interfaceGuid: "{替换为你的 Wi-Fi 网卡 GUID}"

defaults:
  ip:
    mode: dhcp
  dns:
    mode: dhcp

networks:
  "Office-WiFi":
    ip:
      mode: static
      address: "192.168.10.20/24"
      gateway: "192.168.10.1"
    dns:
      mode: static
      servers:
        - "192.168.10.2"
        - "1.1.1.1"

  "Hotel-WiFi":
    # 未写 ip，因此继承 defaults.ip，即 DHCP。
    dns:
      mode: dhcp
```

注意：上面的 SSID、地址、网关和 DNS 只是示例。请替换为你实际网络提供的信息；不要把文档中的占位地址直接用于办公或酒店网络。

配置规则说明：

- SSID 采用不区分大小写的精确匹配；未匹配时使用 `defaults`。
- 专属规则只需写要覆盖的部分，其他部分继承默认值。
- 静态 IPv4 必须写成 CIDR，例如 `192.168.10.20/24`，并提供同一子网内的网关。
- 静态 DNS 的 `servers` 必须至少包含一个 IPv4 地址，且不能重复。
- `mode: dhcp` 时不要保留同一部分的 `address`、`gateway` 或 `servers`。
- 修改配置后无需重新安装；下一次任务运行时会重新读取配置。

### 4. 安装

在管理员 PowerShell 7 中运行：

```powershell
Set-Location '项目目录'
Set-ExecutionPolicy -Scope Process Bypass
.\install.ps1
```

安装器会请求 UAC，并完成以下操作：安装 YAML 依赖、验证配置、复制受保护的运行文件、注册 `WifiNetworkSwitcher` 计划任务，然后立即应用并核验当前 Wi-Fi 的配置。

安装完成后：

- 配置：当前项目目录的 `wifi-network-config.yaml`
- 受保护运行代码：`C:\ProgramData\WifiNetworkSwitcher`
- 运行日志：`C:\ProgramData\WifiNetworkSwitcher\logs\switch.log`
- 计划任务：`WifiNetworkSwitcher`

## 手动应用和验证

配置保存后可以直接双击 `WifiNetworkApply.cmd`。它会请求 UAC、启动计划任务、等待应用完成，并显示最新日志。

也可以在管理员 PowerShell 中运行：

```powershell
.\apply-now.ps1
```

仅验证配置而不修改网络：

```powershell
& 'C:\Program Files\PowerShell\7\pwsh.exe' -NoProfile -File `
  'C:\ProgramData\WifiNetworkSwitcher\Invoke-WifiNetworkSwitcher.ps1' `
  -ConfigPath (Join-Path (Get-Location) 'wifi-network-config.yaml') `
  -Trigger Manual -ValidateOnly
```

成功日志通常包含：

```text
Applying DNS mode 'static'.
Network state was applied and verified successfully.
Final state: DHCP=True; IPv4=[...]; Gateway=[...]; DNS=[...].
```

如果只修改 DNS，日志不应出现 `Applying IPv4 mode ...`。任务失败时请查看上面的 `switch.log`；程序只有在系统状态核验通过后才报告成功。暂时没有默认路由时，程序会记录空值而不会仅因日志字段为空误报失败。

## 卸载

保留当前网络状态、配置、日志和 YAML 模块：

```powershell
.\uninstall.ps1
```

卸载前将目标网卡的 IPv4 和 DNS 恢复为 DHCP：

```powershell
.\uninstall.ps1 -RestoreDhcp
```

可选参数：

- `-RemoveLogs`：同时删除 `C:\ProgramData\WifiNetworkSwitcher` 下的日志。
- `-RemoveYamlModule`：再次确认后删除全局 `powershell-yaml` 0.4.12；如果其他脚本依赖它，请不要使用此参数。

## 测试

烟雾测试无需管理员权限，也不会修改真实网络：

```powershell
.\tests\run-smoke-tests.ps1
```

如果已安装 Pester 5，可以运行完整测试：

```powershell
Invoke-Pester .\tests\WifiNetworkSwitcher.Tests.ps1 -Output Detailed
```

GitHub Actions 会在 Windows runner 上自动执行这两组测试。真实网络验收应使用可恢复的测试 Wi-Fi，并在操作前确认静态 IP、CIDR、网关和 DNS 均正确。

## 安全与权限提示

该工具会修改本机网络配置，并以 SYSTEM 权限运行计划任务。请只使用你信任的配置文件和代码；静态 IP 或 DNS 填写错误可能导致网络中断。安装目录和日志中的本机信息不应提交到公开仓库。`wifi-network-config.yaml` 是本机配置，不会被 Git 跟踪；公开发布时请使用 `wifi-network-config.example.yaml`。

`cleanup/` 目录是开发过程中的本地清理和调查材料，不属于程序发布内容，已被 Git 忽略。

## License

本项目以 [MIT License](LICENSE) 发布。
