# TrashVPN for iOS

橘色 SwiftUI WARP 客户端，使用 ProjectClash 的 Mihomo 衍生 Apple SDK。支持 **WG、AWG、MASQUE（QUIC/HTTP/3）**。

已接入自动注册、真实 HTTPS 优选、按协议和地址族隔离的缓存，以及完整首页与设置。首页使用统一注册/优选进度条，节点默认折叠，第一项固定为「自动选择」；协议仅在设置切换。完整设置和验收细节见 [第三阶段](Docs/Stage3/Validation.md)。历史结果保留在 [IPv6 验证](Docs/Stage3-IPv6/Validation.md)、[第二阶段](Docs/Stage2/Validation.md) 和 [第一阶段](Docs/Stage1-ThreeProtocols/Validation.md)。

## 自动准备流程

进入应用、重新回到前台或切换协议时，自动检查当前协议：

1. 已注册且缓存有效：直接恢复节点，不访问注册接口、不重复优选，也不延长到期时间。
2. 未注册：在本机生成密钥，向 Cloudflare 创建并启用该协议的独立身份，随后优选。
3. 已注册但无缓存、缓存过期或身份与缓存不匹配：保留注册身份，只重新优选。
4. 完整优选成功：写入带身份指纹和明确到期时间的缓存，有效期从完成时开始计算，默认 6 小时，可选 6 / 12 / 24 / 48 小时。

WG、AWG、MASQUE 各自保存身份；每个协议的 IPv4 / IPv6 节点缓存独立保存，切换地址族复用该协议的注册身份。注册采用分步检查点；POST 成功后立即保存身份，PATCH 中断后可继续，不会为一次扫描失败重建账号。注册令牌和私钥放在主程序与 Packet Tunnel 共享的钥匙串中，不经过 VPN 偏好配置。

切换协议会取消旧准备任务，等内核清理完再开始新协议；旧任务的回调不会覆盖新协议界面。退后台时暂停注册/优选，允许当前有界请求完成清理，回前台再自动检查。已有 VPN 连接保持运行，过期缓存的更新排到断开后自动进行。

## 优选

优选不启动系统 VPN。初筛使用随机密钥保护的回环控制接口；质量复测使用仅绑定 `127.0.0.1`、带随机账号密码的临时代理，确认 Cloudflare Trace 的 WARP 状态后才记录结果。测试结束即关闭监听器。

- 候选来自注册响应、历史缓存、已验证的公共端点提示以及 Cloudflare 地址池抽样。
- 低 / 中 / 高强度最多筛选 64 / 160 / 320 个候选，分别入围最多 6 / 10 / 16 个端点。候选数受协议实际入口池限制。
- 每个入围节点交替检查 Cloudflare 与 YouTube 的 HTTPS 连通，复测 5 / 8 / 12 轮，至少成功 4 / 7 / 11 轮，同时限制延迟抖动。
- 下载预热后，再测 2 / 3 / 4 轮实际下载（每轮 768 KiB / 1536 KiB / 2 MiB）。每轮至少 3 Mbps，最低与最高速度之比至少为 40% / 55% / 70%。速度显示取最慢一轮。
- 自动选择在全部达标节点中选延迟中位数最低的端点；低延迟但下载慢、波动大或无法连通 YouTube 的节点不能进入有效缓存。
- 各端点串行测试，同一端点质量复测复用内核连接，避免身份漫游和重复冷启动干扰结果。
- 失败或取消不刷新缓存到期时间，部分测试结果不作为有效缓存。

单次下载预热与测速的最大有效载荷约为 12 / 50 / 136 MiB，另有握手、连通检查等开销；提前淘汰节点会减少用量。旧版只有延迟的缓存会自动重新优选，注册身份继续复用。前台显示每个节点、每轮稳定性检查与下载测速的实际进度。

测试目标包含 `cp.cloudflare.com/generate_204`、`www.youtube.com/generate_204` 及 `speed.cloudflare.com/__down`；不以 TCP 握手或单次 HTTP 成功作为速度依据。连接后可点击“验证 WARP 出口”，只有 HTTPS 200 且 Cloudflare Trace 返回 `warp=on` 或 `warp=plus` 才显示成功。

## 本地构建

需要 Xcode 26+、iOS 17+ 和 XcodeGen（`brew install xcodegen`）。签名沿用 `4LQT8WXV3K`；主程序 `com.leo.TrashVPN`，扩展 `com.leo.TrashVPN.PacketTunnel`，App Group `group.com.leo.TrashVPN`，共享钥匙串组 `$(AppIdentifierPrefix)com.leo.TrashVPN.shared`。

版本保持 `1.0.0`，当前 build 为 `10015`。无需准备测试私钥，第一阶段的 `LocalSecrets` 不再打包。

```sh
bash Scripts/bootstrap.sh
xcodebuild -project TrashVPN.xcodeproj -scheme TrashVPN \
  -destination 'generic/platform=iOS' -derivedDataPath build \
  -allowProvisioningUpdates build
```

也可直接打开 `TrashVPN.xcodeproj`，选择 Richard 运行。

## 验证

```sh
xcodebuild -project TrashVPN.xcodeproj -scheme TrashVPN \
  -destination 'platform=iOS,id=00008101-001128C03EC2001E' \
  -derivedDataPath build -allowProvisioningUpdates \
  -resultBundlePath TestResults/Unit.xcresult \
  -only-testing:TrashVPNTests test
```

45 项配置和流程测试覆盖注册续接、实际 SDK 对三协议双栈密钥配置的解析、缓存期限和失效、取消及失败恢复、IPv6 路由、真实超时、最低下载速度、稳定性、YouTube 连通要求与临时代理的本地认证配置。网络 UI 测试可用 `-only-testing:TrashVPNUITests/Stage3DeviceTests` 单独执行，依赖当前运营商与端点可达性；具体通过和未通过项目见本轮验证记录。

## 结构

- `App/WARPRegistration.swift`：Cloudflare 消费者 WARP 注册，参考 Windows 客户端的 WG 与两步 MASQUE 注册流程。
- `App/NodePreparation.swift`：身份和缓存检查、候选池、按强度初筛与复测调度。
- `App/NodeQualityProbe.swift`：无 TUN 的 WARP 链路验证、Cloudflare/YouTube 稳定性检查和持续下载测速。
- `Shared/WARPAccount.swift`：密钥生成与共享钥匙串存储。
- `Shared/NodeCache.swift`：按期限、协议、地址族、注册身份及测量设置隔离的原子文件缓存。
- `PacketTunnel`：独立扩展，读取注册身份和有效缓存，通过公开 `NEPacketTunnelFlow` 桥接内核。出站绑定物理接口，并为 IPv4 服务器设置 `/32`、IPv6 服务器设置 `/128` 排除路由，避免路由回环。
- `Core`：App 和扩展共享的动态内核框架；各自在不同进程和工作目录运行。

设置中可选择到 WARP 入口的 IPv4 / IPv6 地址族。IPv4 保持原有 IPv4-only 查询策略；IPv6 使用 prefer-ipv6 查询策略、启用 AAAA 与 IPv6 fake-IP，WG / AWG 使用注册的双栈地址及双栈 Allowed IPs，MASQUE 同时保留双栈地址。两种模式都接管系统双栈默认路由，IPv4 模式继续阻止 IPv6 绕过隧道。选择 IPv6 不会静默回退到 IPv4 入口。

IPv6 出口验证要求 Cloudflare Trace 返回 IPv6 出口及 `warp=on/plus`，还会通过禁止重定向的 IPv4、IPv6 字面量 HTTPS 请求检查两种包链路的可用性。长时间锁屏、Wi-Fi/蜂窝切换、高负载和全地址空间扫描尚未验收。完整首页与设置本轮结果见 [第三阶段验证记录](Docs/Stage3/Validation.md)。

## 来源

- [ProjectClash/Clash](https://github.com/ProjectClash/Clash)：Apple SDK `v1.19.33-clash.4`，版本和校验值固定在 `Dependencies.lock.json`。
- [ProjectClash/Clash-Adapter](https://github.com/ProjectClash/Clash-Adapter)：公开 PacketFlow 桥接和物理网络辅助代码。
- [ProjectClash/Clash-Client](https://github.com/ProjectClash/Clash-Client)：参考共享框架打包和平台接法。
- [trashvpn-windows](https://github.com/FuckGFWall/trashvpn-windows)：注册请求、协议参数和地址池参考。
- [usque](https://github.com/Diniboy1123/usque)：MASQUE 注册和设备公钥登记机制参考。

应用名称、图标及 Apple 身份沿用机主授权的原工程。许可证与依赖说明见 `LICENSE`、`Core/NOTICE`、`Core/THIRD_PARTY_LICENSES.md` 和 `Vendor/ClashAdapter/LICENSE`。
