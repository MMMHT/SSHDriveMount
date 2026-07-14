# TailMount for Windows

> macOS 原生版本源码位于 [`macOS/TailMountMac`](macOS/TailMountMac)，包含 SwiftUI 应用、菜单栏驻留、Keychain、连接质量监测和 DMG 构建脚本。

TailMount 是一个面向 Tailscale + SSH/SFTP 的 Windows 图形化远程磁盘管理工具。它通过 SSHFS-Win 把服务器目录挂载成盘符，让远程文件可以像本地磁盘一样在文件资源管理器中访问。

当前版本为 Windows 预览版，界面和主要功能已经可以实际使用，并提供标准 Windows 安装程序。

## 功能

- 管理多个服务器配置和独立盘符。
- 支持 Tailscale MagicDNS 名称和 `100.x.x.x` 地址。
- 支持 SSH 密码和 SSHFS-Win 默认密钥认证。
- 测试 SSH 端口、挂载、重新挂载、卸载和打开远程磁盘。
- 自动检测 Tailscale、WinFsp 与 SSHFS-Win 运行环境。
- 后台监测网络延时、近期稳定性和远程目录响应时间。
- 关闭主窗口后驻留 Windows 系统托盘，单击托盘图标即可恢复，右键可打开远程磁盘或彻底退出。
- 网络抖动快速复查，连续失败后才判定离线。
- 配置原子保存、自动备份、损坏恢复和持久诊断日志。
- 单实例运行，避免多个窗口同时写入配置。

## 系统要求

- Windows 10 或 Windows 11。
- Windows PowerShell 5.1。
- 已加入同一 Tailnet 的 Tailscale 客户端。
- WinFsp 与 SSHFS-Win。

缺少 WinFsp 或 SSHFS-Win 时，可以在应用左下角点击“安装缺少的组件”，也可以用管理员身份运行 `Install-Dependencies.ps1`。

## 快速开始

### 安装版（推荐）

1. 双击 `TailMount-Setup-0.2.0.exe`。
2. 按安装向导完成安装；可以选择是否创建桌面快捷方式。
3. 从开始菜单打开 TailMount。

安装版默认安装到当前用户的 `%LOCALAPPDATA%\Programs\TailMount`，不需要管理员权限，并会出现在 Windows“已安装的应用”中，可正常卸载。

### 便携版

1. 下载或克隆整个项目目录。
2. 双击 `TailMount.exe`。也可以运行 `启动 TailMount.vbs` 或 `启动 TailMount.cmd`。
3. 填写服务器地址、SSH 端口、用户名、远程目录和盘符。
4. 选择认证方式，点击“测试连接”。
5. 测试成功后点击“挂载远程磁盘”。

服务器建议只通过 Tailscale ACL 开放 SSH，不要把 SSH 端口直接暴露到公网。

## SSH 密钥模式

SSHFS-Win 默认使用 `%USERPROFILE%\.ssh\id_rsa`。网络映射模式通常要求密钥没有交互式口令。若需要其他密钥，可以在 `%USERPROFILE%\.ssh\config` 中配置 Host 别名和 `IdentityFile`，再把 Host 别名填入 TailMount。

## 健康监测逻辑

- 后台优先使用 ICMP Ping 检测 Tailnet 网络延时；ICMP 被禁用时回退到 SSH TCP 端口。
- “测试连接”和挂载前检查始终执行真实的 SSH TCP 连接测试。
- 默认保留最近 12 次结果计算稳定性。
- 延时达到 180 ms 时提示偏慢，达到 400 ms 时提示非常慢。
- 单次网络失败显示为瞬时波动并在约 1 秒后复查；连续失败才显示离线。
- 挂载后约每 12 秒检查一次远程根目录响应，不会创建或修改服务器文件。
- 目录响应慢或无响应时会显示分级提醒；挂载操作在后台执行，不会冻结主界面。

这里展示的是交互延时和目录响应速度，不会写入测试文件，也不代表大文件的实际传输带宽。

## 配置与隐私

安装版的运行数据保存在 `%LOCALAPPDATA%\TailMount\data`，便携版保存在程序目录的 `data` 文件夹：

- `profiles.json`：服务器配置，不保存 SSH 密码。
- `profiles.json.bak`：上一次有效配置备份。
- `TailMount.log`：运行诊断日志，达到约 1 MB 后轮换。

这些文件已被 `.gitignore` 排除，不会在正常 Git 操作中上传。仓库只包含 `examples/profiles.example.json` 示例配置。

安装、升级和卸载程序都不会把服务器配置打入安装包，也不会主动删除个人配置。若确实需要彻底清理，可在卸载后手动删除 `%LOCALAPPDATA%\TailMount`。

## 从源码构建

使用 Windows PowerShell 5.1：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Build.ps1
```

构建脚本使用 Windows 自带的 .NET Framework C# 编译器生成 `TailMount.exe`。该 EXE 是轻量启动器，运行时仍需和 `TailMount.ps1` 放在同一目录。

生成 Windows 安装包需要安装 Inno Setup 6，然后运行：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Build-Installer.ps1
```

输出文件位于 `dist\TailMount-Setup-0.2.0.exe`。

## 项目结构

```text
TailMount/
├─ TailMount.ps1               # WPF 界面与核心逻辑
├─ TailMount.Launcher.cs       # 无控制台窗口启动器源码
├─ TailMount.exe               # 已编译启动器
├─ Build.ps1                   # 启动器构建脚本
├─ Build-Installer.ps1         # Windows 安装包构建脚本
├─ Create-Icon.ps1             # 应用图标生成脚本
├─ assets/                     # 应用图标
├─ installer/                  # Inno Setup 安装脚本
├─ Install-Dependencies.ps1    # WinFsp / SSHFS-Win 安装脚本
├─ examples/                   # 无隐私信息的示例配置
└─ data/                       # 本地运行数据，Git 默认忽略
```

## 已知限制

- SSHFS-Win 对 Linux 权限、符号链接和文件锁的表现与 NTFS 不完全相同。
- 不建议通过 SSHFS 直接运行数据库、虚拟机或 Docker 数据目录。
- SSH 用户名和密码是否正确，只能在真正挂载时由 SSHFS-Win 完成验证。
- 当前安装包尚未进行商业代码签名，因此首次运行时 Windows 可能显示“未知发布者”；请核对下载来源和 SHA-256。
- 当前版本尚未提供自动更新。
