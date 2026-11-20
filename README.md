<p align="center">
  <img src="https://raw.githubusercontent.com/FuckGFWall/trashvpn-ios/main/App/icon.icon/Assets/%E9%80%8F%E6%98%8E%E8%83%8C%E6%99%AF%202.png" width="112" alt="TrashVPN 图标">
</p>

<h1 align="center">TrashVPN</h1>
<p align="center">简体中文 · <a href="README.en.md">English</a> · <a href="README.fa.md">فارسی</a></p>
<p align="center">
  <a href="https://testflight.apple.com/join/YBg8gqaQ">TestFlight 下载</a>
  · <a href="LICENSE">GPL-3.0</a>
</p>

**TrashVPN** 是一款面向 Apple 设备的第三方 Cloudflare WARP 客户端，用 SwiftUI 原生开发，使用 Mihomo 内核，支持自动注册、节点筛选与优选，以及节点导出。

支持 **iOS 16+、iPadOS 16+**，以及 **Apple Silicon Mac**。

## 功能

- **多种 WARP 协议**：WireGuard（WG）、AmneziaWG（AWG）和 MASQUE（HTTP/3）。
- **自动注册与节点优选**：自动准备 WARP 身份，筛选并测试可用端点。
- **IPv4 / IPv6**：支持选择 WARP 入口地址族。
- **节点管理与导出**：支持自动选择最低延迟节点，手动测试延迟和速度，以及多种节点配置格式导出。
- **多语言支持**：简体中文、繁體中文、English 和 فارسی。

## 安装

目前通过 **TestFlight** 提供。

1. 在 iPhone、iPad 或 Apple Silicon Mac 上，从 [App Store 下载 TestFlight](https://apps.apple.com/app/testflight/id899247664)。
2. 安装完成后，点击 [TrashVPN TestFlight 邀请链接](https://testflight.apple.com/join/YBg8gqaQ)。
3. 在 TestFlight 中接受邀请，然后点击“安装”。

**注意：请先安装 TestFlight，再点击邀请链接**。

## 开发与构建

### 环境要求

- macOS
- Xcode 26 或更高版本
- XcodeGen
- 真机调试需要有效的 Apple 开发者签名及 Network Extension（Packet Tunnel）权限

### 获取依赖并生成 Xcode 项目

```sh
brew install xcodegen
bash Scripts/bootstrap.sh
```

脚本会下载项目使用的 Mihomo 衍生 Apple SDK、校验 SHA-256，并生成 Xcode 项目。

### 构建

```sh
xcodebuild -project TrashVPN.xcodeproj -scheme TrashVPN \
  -destination 'generic/platform=iOS' \
  -derivedDataPath build \
  -allowProvisioningUpdates build
```

也可以使用 Xcode 打开 `TrashVPN.xcodeproj`，选择设备后运行。

## 技术栈

- **应用界面**：Swift、SwiftUI
- **代理内核**：ProjectClash 提供的 Mihomo 衍生 Apple SDK
- **系统集成**：Apple Network Extension（Packet Tunnel）
- **项目生成**：XcodeGen

当前集成的内核版本为 `v1.19.33-clash.4`，版本和校验值见 [Dependencies.lock.json](Dependencies.lock.json)。

## 致谢

本项目参考或使用了以下开源项目：

- [ProjectClash/Clash](https://github.com/ProjectClash/Clash)：Mihomo 衍生 Apple SDK。
- [ProjectClash/Clash-Adapter](https://github.com/ProjectClash/Clash-Adapter)：Packet Tunnel 桥接及网络辅助实现。
- [ProjectClash/Clash-Client](https://github.com/ProjectClash/Clash-Client)：Apple 平台集成与框架打包参考。
- [trashvpn-windows](https://github.com/FuckGFWall/trashvpn-windows)：WARP 注册流程、协议参数及地址池参考。
- [usque](https://github.com/Diniboy1123/usque)：MASQUE 注册流程参考。

感谢以上项目的作者及贡献者。

## 许可证

本项目采用 **GNU General Public License v3.0（GPL-3.0）** 发布，完整协议见 [LICENSE](LICENSE)。

项目还包含 Mihomo 内核及其他第三方组件。相关版权声明和依赖许可证清单见：

- [Core/NOTICE](Core/NOTICE)
- [Core/THIRD_PARTY_LICENSES.md](Core/THIRD_PARTY_LICENSES.md)
- [Vendor/NOTICE](Vendor/NOTICE)
- [Vendor/THIRD_PARTY_LICENSES.md](Vendor/THIRD_PARTY_LICENSES.md)
- [Vendor/ClashAdapter/LICENSE](Vendor/ClashAdapter/LICENSE)
