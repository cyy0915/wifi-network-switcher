# WiFi Network Switcher

根据当前连接的 Wi-Fi SSID，在 Windows 上自动切换指定无线网卡的 IPv4 和 DNS 配置。

适用于需要在办公网、家庭网络、酒店网络等环境之间切换 DHCP、静态 IPv4 和 DNS 的用户。程序通过受保护的 SYSTEM 计划任务执行网络操作；用户只需维护项目目录中的 YAML 配置。

> **English summary:** WiFi Network Switcher is a Windows PowerShell 7 utility
> that applies per-SSID IPv4 and DNS policies through a protected SYSTEM
> scheduled task. It supports DHCP/static IPv4, DHCP/static DNS, strict
> configuration validation, state verification, and partial rollback.

## 功能

- 按 SSID 不区分大小写地精确匹配；未配置的网络使用 `defaults`。
- IPv4 支持 DHCP，或“静态 CIDR 地址 + 默认网关”。
- DNS 支持 DHCP，或一个/多个有序的静态 IPv4 DNS 服务器。
- IPv4 与 DNS 分别比较和应用；只修改 DNS 时不会重建正常的 DHCP 地址和路由。
- 应用失败或核验失败时，只回滚本次实际修改的部分。
- 通过 Native Wi-Fi API 获取当前 SSID，不解析本地化的 `netsh` 文本。
- SYSTEM 计划任务支持 Wi-Fi 连接、开机、登录、解锁、睡眠恢复和手动触发。
- 只管理所选无线网卡的 IPv4；不主动修改 IPv6、其他网卡、代理、DoH、Wi-Fi 密码或自动连接顺序。

## 系统要求

- Windows 10 或 Windows 11。
- 当前账户能够批准 UAC 提权。
- PowerShell 7，安装在默认位置：`C:\Program Files\PowerShell\7\pwsh.exe`。
- 至少一块 Windows Native Wi-Fi 网卡。
- 首次安装需要联网，以便为 AllUsers 安装固定版本的 `powershell-yaml` 0.4.12。

## 快速开始

### 1. 获取项目

```powershell
git clone https://github.com/cyy0915/wifi-network-switcher.git
Set-Location .\wifi-network-switcher
```

公开仓库不包含本机的 `wifi-network-config.yaml`；该文件已被 `.gitignore` 排除。

### 2. 运行安装器

正常情况无需提前复制示例配置，也无需手工查询网卡 GUID。请运行：

```powershell
& 'C:\Program Files\PowerShell\7\pwsh.exe' -NoProfile -ExecutionPolicy Bypass -File .\install.ps1
```

安装器会自动请求 UAC，并依次完成：

1. 检查系统 PowerShell 7。
2. 为 AllUsers 安装或确认 `powershell-yaml` 0.4.12。
3. 如果 `wifi-network-config.yaml` 不存在，枚举 Native Wi-Fi 接口。
4. 在恰好发现一块 Wi-Fi 网卡时，自动生成本机配置并写入真实的 `InterfaceGuid`。
5. 严格验证整个配置，再进行任何网络修改。
6. 将运行脚本复制到受 ACL 保护的 `C:\ProgramData\WifiNetworkSwitcher`。
7. 注册最高权限的 SYSTEM 计划任务 `WifiNetworkSwitcher`。
8. 立即运行一次计划任务并核验最终状态。

首次自动生成的配置采用安全默认值：IPv4 DHCP、DNS DHCP、无专属 SSID 规则。安装器不会在首次安装时套用文档中的静态示例地址。

如果机器上没有 Wi-Fi 接口，或同时发现多块 Wi-Fi 接口，安装器不会猜测目标。它会停止并列出候选接口；此时才需要参考 `wifi-network-config.example.yaml` 手工创建配置、填写希望管理的接口 GUID，然后重新运行安装器：

```powershell
Get-NetAdapter | Format-Table Name, Status, InterfaceDescription, InterfaceGuid
Copy-Item .\wifi-network-config.example.yaml .\wifi-network-config.yaml
```

如果 `wifi-network-config.yaml` 已经存在，安装器只会校验它，绝不会覆盖或重新生成。

### 3. 编辑规则

安装成功后，编辑项目目录中由安装器生成的 `wifi-network-config.yaml`。例如：

```yaml
version: 1

adapter:
  # 首次安装时由安装器自动填写；不要随意改成其他网卡。
  interfaceGuid: "{实际的 Wi-Fi 网卡 GUID}"

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
    # ip 未写，因此继承 defaults.ip，即 DHCP。
    dns:
      mode: dhcp
```

示例中的 SSID、地址、网关和 DNS 都是占位内容，请替换为实际网络参数。

配置规则：

- `version` 当前必须为整数 `1`。
- `adapter.interfaceGuid` 必须是目标 Wi-Fi 接口的有效 GUID。
- SSID 使用不区分大小写的完整匹配，不支持通配符或正则表达式。
- 未匹配的 SSID 使用 `defaults`。
- SSID 规则只需写需要覆盖的部分，其他部分继承 `defaults`。
- 静态 IPv4 必须使用 CIDR，例如 `192.168.10.20/24`，并提供同一子网中的网关。
- 静态 DNS 的 `servers` 必须是至少包含一个 IPv4 地址的列表，且不能重复。
- 静态 IPv4 不能与 DHCP DNS 组合；静态 IP 规则必须同时提供静态 DNS。该限制在继承合并后的最终策略上检查。
- `mode: dhcp` 时，不要在同一区块中保留 `address`、`gateway` 或 `servers`。
- YAML 中的未知字段、重复 SSID、非法地址、缺失字段和跨子网网关都会在修改网络前被拒绝。

### 4. 立即应用修改

保存 YAML 后无需重新安装。双击项目目录中的：

```text
WifiNetworkApply.cmd
```

它会请求 UAC、启动计划任务、等待应用与核验完成，并显示最新日志。也可以运行：

```powershell
.\apply-now.ps1
```

或在管理员 PowerShell 中直接触发：

```powershell
Start-ScheduledTask -TaskName WifiNetworkSwitcher
```

## 文件与安全边界

安装后各部分的位置不同：

- **用户配置**：项目目录中的 `wifi-network-config.yaml`。
- **受保护运行代码**：`C:\ProgramData\WifiNetworkSwitcher`。
- **运行日志**：`C:\ProgramData\WifiNetworkSwitcher\logs\switch.log`。
- **计划任务**：`WifiNetworkSwitcher`，以 SYSTEM 和最高权限运行。

计划任务不会执行项目目录中普通用户可修改的 `.ps1` 文件；它只执行 ProgramData 中受 ACL 保护的副本。项目目录中的 YAML 只作为数据读取，并经过严格的字段、类型、地址和继承校验。

计划任务保存了 YAML 的绝对路径。如果安装后移动或重命名项目目录，请在新位置重新运行 `install.ps1`，以更新受保护代码和任务参数。

如果修改的是 `.ps1`、`.psm1` 或计划任务定义，而不仅是 YAML，也必须重新运行 `install.ps1`，才能把新代码部署到 ProgramData。单纯修改 YAML 不需要重装。

## 自动触发

安装器注册的任务包含以下触发条件：

- WLAN AutoConfig 成功连接事件 8001。
- 系统开机。
- 任意用户登录。
- 会话解锁。
- 系统从睡眠恢复。
- 用户通过 `WifiNetworkApply.cmd`、`apply-now.ps1` 或 `Start-ScheduledTask` 手动触发。

每次运行都会重新读取当前 YAML 和当前 SSID。多个触发同时发生时任务会排队，网络变更还受到全局互斥保护。

## 验证与日志

仅验证已安装配置而不修改网络：

```powershell
& 'C:\Program Files\PowerShell\7\pwsh.exe' -NoProfile -File `
  'C:\ProgramData\WifiNetworkSwitcher\Invoke-WifiNetworkSwitcher.ps1' `
  -ConfigPath (Join-Path (Get-Location) 'wifi-network-config.yaml') `
  -Trigger Manual -ValidateOnly
```

DNS-only 更新的正常日志类似：

```text
Applying DNS mode 'static'.
Network state was applied and verified successfully.
Final state: DHCP=True; IPv4=[...]; Gateway=[...]; DNS=[...].
```

如果只修改 DNS，日志不应出现 `Applying IPv4 mode ...`。程序会分别比较 IPv4 与 DNS，只修改不一致的部分；DNS-only 失败时也只回滚 DNS，不会通过回滚重置 IP。

程序只有在系统状态核验通过后才返回成功。DHCP 模式不仅检查 DHCP 开关，还要求网卡实际获得有效的非 APIPA IPv4 地址。暂时没有默认路由时，日志会安全记录空值，不会仅因日志字段缺失而误报失败。

任务失败时，请查看 `WifiNetworkApply.cmd` 窗口中的日志尾部，或在管理员权限下读取：

```text
C:\ProgramData\WifiNetworkSwitcher\logs\switch.log
```

## 卸载

默认卸载会删除计划任务和受保护运行代码，但保留当前网络状态、项目目录中的 YAML、日志和全局 YAML 模块：

```powershell
.\uninstall.ps1
```

卸载前将目标网卡的 IPv4 和 DNS 恢复为 DHCP：

```powershell
.\uninstall.ps1 -RestoreDhcp
```

可选参数：

- `-RemoveLogs`：同时删除 ProgramData 中的运行日志。
- `-RemoveYamlModule`：再次确认后删除全局 `powershell-yaml` 0.4.12；其他脚本可能也依赖该模块。

卸载器不会删除项目目录中的 `wifi-network-config.yaml`、安装器、测试或文档。

## 测试

烟雾测试无需管理员权限，也不会修改真实网络：

```powershell
.\tests\run-smoke-tests.ps1
```

如果已安装 Pester 5，可以运行完整测试：

```powershell
Invoke-Pester .\tests\WifiNetworkSwitcher.Tests.ps1 -Output Detailed
```

GitHub Actions 会在 Windows runner 上执行烟雾测试和 Pester 测试。真实网络验收应使用可恢复的测试 Wi-Fi，并提前确认静态 IP、CIDR、网关和 DNS 正确。

## 发布与隐私

- `wifi-network-config.yaml` 包含本机接口 GUID、SSID 和网络地址，已被 Git 忽略，不应提交。
- `wifi-network-config.example.yaml` 仅供多网卡或手工配置时参考，不是正常安装的必需步骤。
- 根目录的安装/应用 transcript、ProgramData 日志和 `cleanup/` 调查材料都已被 Git 忽略。
- 发布前请检查 `git status`，避免提交本机网络信息。

## License

本项目以 [MIT License](LICENSE) 发布。
