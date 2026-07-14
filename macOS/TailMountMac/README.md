# TailMount for macOS

TailMount 是一个原生 SwiftUI 的 Tailscale SFTP 磁盘管理工具。它通过 macFUSE + SSHFS，把服务器目录挂载到 macOS，并能直接在 Finder 中像本地磁盘一样访问。

## 当前功能

- 多服务器配置，支持 Tailscale IP 与 MagicDNS 名称。
- SSH 密钥或密码认证；配置 JSON 永不保存密码，记忆密码仅写入 macOS Keychain。
- 一键测试 SSH 可达性、挂载、重新挂载、卸载以及 Finder 打开。
- 优先使用 `tailscale ping`，不可用时自动回退到 SSH TCP 探测。
- 每 10 秒监测延时、成功率、断线与不稳定状态，异常时发送 macOS 通知。
- 主窗口关闭后驻留菜单栏；菜单可恢复窗口、打开磁盘、卸载或彻底退出。
- 可选择登录时启动，以及恢复选中服务器的登录挂载。
- 原生浅色/深色模式、现代化卡片界面和连接质量曲线。

## 系统要求

- macOS Ventura 13 或更高版本。
- Apple Silicon 或 Intel Mac。
- [Tailscale for macOS](https://tailscale.com/docs/install/mac)。
- [macFUSE 与官方 SSHFS](https://macfuse.github.io/)。macFUSE 本身不包含 SSHFS，需要两项都安装。

> macOS 26 上 macFUSE 可以使用新的 FSKit 后端；较早版本可能需要按 macFUSE 安装器提示批准系统扩展或重启。

## 在 Mac 上构建

需要 Xcode 15 或更高版本及 Command Line Tools。打开“终端”，进入本目录：

```zsh
chmod +x scripts/*.sh scripts/*.command
./scripts/build-app.sh
```

应用生成在：

```text
dist/TailMount.app
```

生成可拖入“应用程序”文件夹安装的 DMG：

```zsh
./scripts/build-dmg.sh
```

默认构建当前 Mac 的架构。需要通用二进制时：

```zsh
UNIVERSAL=1 ./scripts/build-dmg.sh
```

仓库也包含 `.github/workflows/build-macos.yml`。推送 macOS 目录后，GitHub Actions 会在真实的 `macos-15-intel` Runner 上构建并验证 x86_64 DMG，构建结果可在 Actions 页面下载。

## 首次测试流程

1. 安装并登录 Tailscale。
2. 安装 macFUSE 与 SSHFS，按安装器要求完成系统扩展许可或重启。
3. 构建后将 `TailMount.app` 拖入“应用程序”，再启动。
4. 输入服务器地址、SSH 用户名、端口和远程目录。
5. 优先选择专用 SSH 密钥；若使用密码，可选择保存到 Keychain。
6. 点击“测试连接”，确认延时与成功率正常。
7. 点击“挂载远程磁盘”，Finder 会自动打开本地挂载目录。
8. 关闭主窗口，确认菜单栏仍显示 TailMount 图标并能恢复窗口。

## 数据与隐私

- 配置：`~/Library/Application Support/TailMount/profiles.json`
- 默认挂载目录：`~/TailMount/<配置名称>`
- 密码：macOS Keychain，服务名 `com.mmmht.TailMountMac`
- 项目不包含服务器地址、用户名、密码、私钥或个人配置。
- 私钥始终由系统 OpenSSH/SSHFS 读取，不复制进应用数据目录。

## 签名说明

本项目的本地构建脚本使用 ad-hoc 签名，适合你自己的 Mac 测试。公开分发时应使用 Apple Developer ID 签名并完成 notarization，否则 Gatekeeper 可能阻止首次打开。测试未公证版本时，可以在 Finder 中右键应用并选择“打开”。

## 项目结构

```text
TailMountMac/
├─ Package.swift
├─ Resources/Info.plist
├─ Sources/TailMountMac/
│  ├─ TailMountMacApp.swift
│  ├─ ContentView.swift
│  ├─ Theme.swift
│  ├─ Models.swift
│  ├─ AppModel.swift
│  ├─ ProfileStore.swift
│  ├─ KeychainStore.swift
│  ├─ CommandRunner.swift
│  └─ SystemServices.swift
└─ scripts/
   ├─ build-app.sh
   ├─ build-dmg.sh
   ├─ install-dependencies.command
   └─ IconGenerator.swift
```
