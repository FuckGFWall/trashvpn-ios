<p align="center">
  <img src="https://raw.githubusercontent.com/FuckGFWall/trashvpn-ios/main/App/icon.icon/Assets/%E9%80%8F%E6%98%8E%E8%83%8C%E6%99%AF%202.png" width="112" alt="TrashVPN icon">
</p>

<h1 align="center">TrashVPN</h1>
<p align="center"><a href="README.md">简体中文</a> · English · <a href="README.fa.md">فارسی</a></p>
<p align="center">
  <a href="https://testflight.apple.com/join/YBg8gqaQ">Get it on TestFlight</a>
  · <a href="LICENSE">GPL-3.0</a>
</p>

**TrashVPN** is a third-party Cloudflare WARP client for Apple devices. Built natively with SwiftUI and powered by the Mihomo kernel, it supports automatic registration, endpoint discovery and optimization, and node export.

Supported platforms: **iOS 15+, iPadOS 15+, and Apple silicon Macs**.

## Features

- **Multiple WARP protocols**: WireGuard (WG), AmneziaWG (AWG), and MASQUE (HTTP/3).
- **Automatic registration and endpoint optimization**: automatically prepares a WARP identity, discovers available endpoints, and tests them.
- **IPv4 / IPv6**: choose the address family used to reach WARP endpoints.
- **Node management and export**: automatically selects the lowest-latency node, supports manual latency and speed tests, and exports node configurations in multiple formats.
- **Multilingual support**: Simplified Chinese, Traditional Chinese, English, and Persian.

## Installation

TrashVPN is currently available through **TestFlight**.

1. On your iPhone, iPad, or Apple silicon Mac, download [TestFlight from the App Store](https://apps.apple.com/app/testflight/id899247664).
2. After installing TestFlight, open the [TrashVPN TestFlight invitation](https://testflight.apple.com/join/YBg8gqaQ).
3. Accept the invitation in TestFlight, then tap **Install**.

**Important: Install TestFlight before opening the invitation link.**

## Development and Build

### Requirements

- macOS
- Xcode 26 or later
- XcodeGen
- On-device testing requires valid Apple Developer signing and the Network Extension (Packet Tunnel) capability

### Fetch dependencies and generate the Xcode project

```sh
brew install xcodegen
bash Scripts/bootstrap.sh
```

The script downloads the Mihomo-derived Apple SDK, verifies its SHA-256 checksum, and generates the Xcode project.

### Build

```sh
xcodebuild -project TrashVPN.xcodeproj -scheme TrashVPN \
  -destination 'generic/platform=iOS' \
  -derivedDataPath build \
  -allowProvisioningUpdates build
```

You can also open `TrashVPN.xcodeproj` in Xcode and run it on a selected device.

## Technology Stack

- **App UI**: Swift, SwiftUI
- **Proxy engine**: Mihomo-derived Apple SDK provided by ProjectClash
- **System integration**: Apple Network Extension (Packet Tunnel)
- **Project generation**: XcodeGen

The integrated kernel version is `v1.19.33-clash.4`. See [Dependencies.lock.json](Dependencies.lock.json) for the version and checksum.

## Acknowledgements

This project references or uses the following open-source projects:

- [ProjectClash/Clash](https://github.com/ProjectClash/Clash) — Mihomo-derived Apple SDK.
- [ProjectClash/Clash-Adapter](https://github.com/ProjectClash/Clash-Adapter) — Packet Tunnel bridge and networking helpers.
- [ProjectClash/Clash-Client](https://github.com/ProjectClash/Clash-Client) — Apple platform integration and framework packaging reference.
- [trashvpn-windows](https://github.com/FuckGFWall/trashvpn-windows) — WARP registration flow, protocol parameters, and endpoint pool reference.
- [usque](https://github.com/Diniboy1123/usque) — MASQUE registration reference.

Thanks to the authors and contributors of these projects.

## License

This project is distributed under the **GNU General Public License v3.0 (GPL-3.0)**. See [LICENSE](LICENSE) for the full license text.

The project also includes the Mihomo kernel and other third-party components. Their notices and license information are available in:

- [Core/NOTICE](Core/NOTICE)
- [Core/THIRD_PARTY_LICENSES.md](Core/THIRD_PARTY_LICENSES.md)
- [Vendor/NOTICE](Vendor/NOTICE)
- [Vendor/THIRD_PARTY_LICENSES.md](Vendor/THIRD_PARTY_LICENSES.md)
- [Vendor/ClashAdapter/LICENSE](Vendor/ClashAdapter/LICENSE)
