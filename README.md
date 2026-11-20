<p align="center">
  <img src="https://raw.githubusercontent.com/FuckGFWall/trashvpn-ios/main/App/icon.icon/Assets/%E9%80%8F%E6%98%8E%E8%83%8C%E6%99%AF%202.png" width="112" alt="TrashVPN 图标">
</p>

<h1 align="center">TrashVPN</h1>
<p align="center">简体中文 · <a href="README.en.md">English</a> · <a href="README.fa.md">فارسی</a></p>
<p align="center">
  <a href="https://testflight.apple.com/join/YBg8gqaQ">TestFlight 下载</a>
  · <a href="LICENSE">GPL-3.0</a>
</p>

橘色 SwiftUI WARP 客户端，使用 ProjectClash 的 Mihomo 衍生 Apple SDK。支持 **WG、AWG、MASQUE（QUIC/HTTP/3）**。

已接入自动注册、真实 HTTPS 优选、按协议和地址族隔离的缓存，以及完整首页与设置。首页使用统一注册/优选进度条，节点列表常驻展开，第一项固定为「自动选择」；协议仅在设置切换。

点击首页右上角设置后，从右侧进入完整设置页，左上角返回首页。设置自动保存，文本输入停止 0.5 秒或结束编辑时校验并保存有效值；无效输入在对应设置项显示提示，不覆盖上次有效值。协议与 IPv4 / IPv6 地址族使用下拉菜单，优选强度可在低 / 中 / 高三档之间拖动切换并自动保存，下载测速开关位于最小下载速度上方。首页节点区标题为「选择节点」，进度条操作与「延迟 / 测速」使用相同按钮样式。

支持简体中文、English、繁體中文、فارسی；首次启动按系统主语言选择，不支持时使用英文，并保存为初始选择。语言菜单仅显示这四种语言，可立即切换并自动保存，波斯语使用从右向左布局，DNS 地址保持从左向右输入。自定义 DNS 留空提示实际默认值 `1.1.1.1`，支持多行输入。设置的「关于」以单行图标入口提供官网、GitHub、Telegram、YouTube、X，GitHub / X 使用品牌标志；紧凑的独立单行捐赠卡片整块均可点击。版本位于连接诊断上方。连接位置以小地球与服务器图标表示国家和数据中心，两个冒号固定为英文 `:`，仅国旗 emoji 略微放大。电源外环与光晕在连接时渐变为橘色，断开时渐变回灰色。

缓存可选“永不过期”；存在有效的已完成缓存时，只在首页手动重新优选后更新，修改 MTU、DNS、强度等不自动重新测量。首次无缓存、缓存损坏或注册身份变化时仍准备对应节点。设置页增加“节点导出”，左侧格式菜单、右侧复制按钮：WG 支持 V2Ray 分享链接、Clash YAML 和 sing-box JSON；AWG、Cloudflare MASQUE 提供能保留其参数的 Clash 节点配置。导出读取当前协议、所选地址族的全部已完成本地缓存，不发起注册或扫描。

已连接时可在首页切换缓存节点及“自动选择”，也可在设置中切换到已有有效缓存的协议；使用内核重载保持原系统 VPN 会话。目标缓存不可用时先断开，随后自动注册、优选，完成后等待手动点击开关。

## 安装

目前通过 **TestFlight** 提供。

1. 在 iPhone、iPad 或 Apple Silicon Mac 上，从 [App Store 下载 TestFlight](https://apps.apple.com/app/testflight/id899247664)。
2. 安装完成后，点击 [TrashVPN TestFlight 邀请链接](https://testflight.apple.com/join/YBg8gqaQ)。
3. 在 TestFlight 中接受邀请，然后点击“安装”。

**注意：请先安装 TestFlight，再点击邀请链接**。

## 自动准备流程

进入应用、重新回到前台或切换协议时，自动检查当前协议：

1. 已注册且缓存有效、没有尚未完成的优选：直接恢复节点，不访问注册接口、不重复优选，也不延长到期时间。
2. 未注册：在本机生成密钥，向 Cloudflare 创建并启用该协议的独立身份，随后优选。
3. 已注册但无缓存、缓存过期或身份与缓存不匹配：保留注册身份，只重新优选。
4. 完整优选成功：写入带身份指纹和到期策略的缓存，有效期从完成时开始计算，默认 7 天，可输入有效天数或开启「缓存永不过期」。
5. 存在有效的未完成优选：恢复原候选顺序、初筛轮次、入围名单、已完成节点与当前节点的复测/下载轮次，仅重测中断时未完成的请求。手动重新优选途中被中断，也会优先继续该轮任务。

WG、AWG、MASQUE 各自保存身份；每个协议的 IPv4 / IPv6 节点缓存独立保存，切换地址族复用该协议的注册身份。注册采用分步检查点；POST 成功后立即保存身份，PATCH 中断后可继续，不会为一次扫描失败重建账号。注册令牌和私钥放在主程序与 Packet Tunnel 共享的钥匙串中，不经过 VPN 偏好配置。

切换协议会取消旧准备任务，等内核清理完再开始新协议；旧任务的回调不会覆盖新协议界面，各协议/地址族分别保留未完成进度。回到主屏幕时申请系统允许的有限后台执行时间，尽量继续优选；后台时间耗尽后暂停，回前台恢复。每轮测量完成就原子写盘，因此从多任务界面划掉 App 后重新打开也能恢复，进度条保留原阶段；暂停按钮会变为“继续优选”。

未完成进度的有效期采用设置的天数，从这一轮优选**最初开始**计算，重新打开、保存进度或暂停/继续均不会重置开始时间；永不过期模式也保留手动优选的断点。限时模式过期或测量配置变化后重新优选；永不过期模式沿用已有完整缓存，只有手动重新优选时才重新测量。主题变化不使进度失效。正在进行且未完成的 HTTP 请求不能跨进程恢复，重开时会重建内核连接并预热，已完成的测量不重做。已有 VPN 连接保持运行，网络设置和重新优选排到断开后进行；缓存节点及有缓存的协议可热切换。

## 优选

优选不启动系统 VPN。初筛使用随机密钥保护的回环控制接口；质量复测使用仅绑定 `127.0.0.1`、带随机账号密码的临时代理，确认 Cloudflare Trace 的 WARP 状态后才记录结果。测试结束即关闭监听器。

- 候选来自注册响应、历史缓存、已验证的公共端点提示以及 Cloudflare 地址池抽样。
- 低 / 中 / 高强度每轮最多筛选 64 / 160 / 320 个候选，最多入围 4 / 6 / 8 个端点，取得 2 / 3 / 4 个合格节点后提前结束。候选数受协议实际入口池限制。
- WG / AWG 的 IPv4 首轮包含公共端点提示 `8.35.211.127:864`。首轮没有命中时，补测优先覆盖 Windows 版使用的 50 个备用端口，并复查少量原候选。发现可用备用端口后，优先在其他入口测试该端口。MASQUE 补测沿用自己的 HTTP/3 地址和端口。三个协议的补测都改用 Cloudflare 的 HTTPS IP 地址，以减少测试域名解析失败引起的误判。每个候选仍需通过 WARP 出口与质量检查才能写入缓存。
- 每个入围节点交替检查 Cloudflare 与 YouTube 的 HTTPS 连通。连续稳定 3 / 4 / 5 次后即结束；仅未达标时补测，最多 5 / 6 / 7 次，已无法在剩余次数内达标的节点直接淘汰。检查同源延迟抖动与 1500 ms 延迟上限。
- 下载测速默认开启，最小下载速度默认 3 Mbps，可在设置的探测超时下方填写 0.1–1000 Mbps。先预热 256 KiB，再只测一次实际下载（768 KiB / 1 MiB / 1536 KiB），达标后不重复下载。低于门槛立即淘汰。
- 关闭下载测速会同时跳过下载预热和实际下载，仅按连通性与稳定性筛选；不会把未测速结果当作已达到最低下载速度，节点标注“未测下载”。
- 自动选择在达标节点中选延迟中位数最低的端点；各端点串行测试，同一端点复用内核连接，避免同一身份漫游和重复冷启动干扰结果。
- 失败或取消不刷新缓存到期时间，部分测试结果不作为有效缓存。原子保存已完成的每次测量，下载完成后即使进程被结束，回来也不会重复测这次下载。

正常一次通过时，低 / 中 / 高强度下载预热与测速的有效载荷约为 2 / 3.75 / 7 MiB；尝试全部入围节点的上限为 4 / 7.5 / 14 MiB，另有握手、连通检查等开销。中断恢复时重新预热与未完成请求重试会有额外流量。永久缓存继续按原测量策略使用；限时缓存升级测量算法后重新优选，注册身份继续复用。

首页注册里程碑位于进度条的三分之一处。运行时显示流动高光，暂停时停止，完成后整条变绿；开启系统“减弱动态效果”时保持静态进度。阶段文案按实际注册状态、下载开关动态计算，例如 `7/10 下载测速 · 1/4 测速节点`；就绪时只显示“连接已就绪”。具体次数与端点显示在下方。

测试目标包含 `cp.cloudflare.com/generate_204`、`www.youtube.com/generate_204` 及 `speed.cloudflare.com/__down`；不以 TCP 握手或单次 HTTP 成功作为速度依据。首页“延迟 / 测速”按钮会自动连接 VPN 并逐个测试缓存节点，内部确认 `warp=on/plus` 后记录结果；测试后保持 VPN 连接，用户可点击电源断开。

首页当前节点名称左对齐，右侧为“延迟 / 测速”按钮，列表只显示节点名称、延迟和速度。连通延迟为绿色，失败为红色 `-1`，当前测试项显示转圈。手动结果独立保存，不改变优选质量缓存和有效期；自动选择采用更新后的有效延迟。

首页标题与设置同一行，移除协议徽标、状态标题、宣传语及就绪后的缓存说明。电源按钮未连接时为灰色，连接时以每次随机生成的双层水波上升，成功填满橘色，失败或断开时回落；减弱动态效果时直接切换。有效缓存恢复不发布零进度，返回前台、关闭设置或断开 VPN 保持绿色就绪进度。阶段标题缩小并固定单行。连接后显示“国家：🇨🇳　数据中心：SJC”样式；国旗使用通过当前 WARP 隧道读取的 Trace `loc`，与原“验证 WARP 出口”一致，机场码单独使用 `colo`。移除进度条左下角的“检查”。

## 本地构建

需要 Xcode 26+、iOS 15+ 和 XcodeGen（`brew install xcodegen`）。签名沿用 `4LQT8WXV3K`；主程序 `com.leo.TrashVPN`，扩展 `com.leo.TrashVPN.PacketTunnel`，App Group `group.com.leo.TrashVPN`，共享钥匙串组 `$(AppIdentifierPrefix)com.leo.TrashVPN.shared`。

支持 iPhone、iPad，以及 Apple Silicon Mac 以“Designed for iPad/iPhone”方式运行。关闭 Mac Catalyst 和 Apple Vision 兼容目标；平台选项在 `project.yml` 的共享设置组内固定，重新生成项目后仍保持一致。iOS 15 使用兼容的导航、多行 DNS 编辑器和系统分享面板，继续使用原预编译内核。

当前版本为 `1.0.1`，当前 build 为 `10027`。无需准备测试私钥，第一阶段的 `LocalSecrets` 不再打包。

从旧实现（build 10009 及以下）覆盖升级时，在注册和启动内核前清理旧数据。识别必须有旧 App 自身容器里的明确安装记录；遗留钥匙串、共享容器及空目录不能单独证明覆盖升级。全新安装不清理，新版更新保留 WARP 数据。清理保留 iOS 管理的 Caches 等目录，仅删除内容；10024 无依据的待清理记录会取消，确认的旧版清理支持中断重试。初始化发起小型 HTTPS 请求，让系统在需要时展示联网授权；首次 VPN 连接等待系统配置授权成功后启动，拒绝或取消不会连接。

```sh
bash Scripts/bootstrap.sh
xcodebuild -project TrashVPN.xcodeproj -scheme TrashVPN \
  -destination 'generic/platform=iOS' -derivedDataPath build \
  -allowProvisioningUpdates build
```

也可直接打开 `TrashVPN.xcodeproj`，选择你的设备运行。

## 验证

```sh
xcodebuild -project TrashVPN.xcodeproj -scheme TrashVPN \
  -destination 'platform=iOS,id=<YOUR_DEVICE_UDID>' \
  -derivedDataPath build -allowProvisioningUpdates \
  -resultBundlePath TestResults/Unit.xcresult \
  -only-testing:TrashVPNTests test
```

136 项配置和流程测试覆盖注册续接、实际 SDK 对三协议双栈密钥配置的解析、缓存期限和永不过期策略、取消及失败恢复、IPv6 路由、真实超时、最低下载速度、稳定性、YouTube 连通要求、临时代理的本地认证配置、检查点跨进程恢复，以及导出格式过滤、URI 编码、身份隔离、Clash YAML 实际解析、sing-box endpoint 参数和出口地区解析。导出 JSON 另通过官方 sing-box 1.14.4 原生检查器校验。网络 UI 测试应指定当前验收用例，例如 `-only-testing:TrashVPNUITests/Stage3DeviceTests/test130HomeConnectionLocationAndStableReadyProgress`；历史 UI 用例保留了各阶段当时的布局预期，依赖当前运营商与端点可达性，具体结果见验证记录。

## 结构

- `App/WARPRegistration.swift`：Cloudflare 消费者 WARP 注册，参考 Windows 客户端的 WG 与两步 MASQUE 注册流程。
- `App/NodePreparation.swift`：身份和缓存检查、候选池、按强度初筛与复测调度。
- `App/NodeQualityProbe.swift`：无 TUN 的 WARP 链路验证、Cloudflare/YouTube 稳定性检查和持续下载测速。
- `Shared/OptimizationCheckpoint.swift` 与 `App/OptimizationJournal.swift`：未完成优选的原子文件检查点和串行提交，保留候选列表、各轮测量及原始开始时间。
- `Shared/TunnelSwitch.swift` 与 `App/ProviderMessageClient.swift`：热切换目标验证、运行快照、路由和核心回滚、带超时的 App/扩展通信。
- `App/NodeExport.swift`：只读本地完整缓存的协议格式过滤、WireGuard 分享链接、Clash YAML 与 sing-box JSON 导出。
- `Shared/WARPAccount.swift`：密钥生成与共享钥匙串存储。
- `Shared/NodeCache.swift`：按期限、协议、地址族、注册身份及测量设置隔离的原子文件缓存。
- `PacketTunnel`：独立扩展，读取注册身份和有效缓存，通过公开 `NEPacketTunnelFlow` 桥接内核。出站绑定物理接口，并为 IPv4 服务器设置 `/32`、IPv6 服务器设置 `/128` 排除路由，避免路由回环。
- `Core`：App 和扩展共享的动态内核框架；各自在不同进程和工作目录运行。

设置中可选择到 WARP 入口的 IPv4 / IPv6 地址族。IPv4 保持原有 IPv4-only 查询策略；IPv6 使用 prefer-ipv6 查询策略、启用 AAAA 与 IPv6 fake-IP，WG / AWG 使用注册的双栈地址及双栈 Allowed IPs，MASQUE 同时保留双栈地址。两种模式都接管系统双栈默认路由，IPv4 模式继续阻止 IPv6 绕过隧道。选择 IPv6 不会静默回退到 IPv4 入口。

IPv6 出口验证要求 Cloudflare Trace 返回 IPv6 出口及 `warp=on/plus`，还会通过禁止重定向的 IPv4、IPv6 字面量 HTTPS 请求检查两种包链路的可用性。长时间锁屏、Wi-Fi/蜂窝切换、高负载和全地址空间扫描尚未验收。

## 来源

- [ProjectClash/Clash](https://github.com/ProjectClash/Clash)：Apple SDK `v1.19.33-clash.4`，版本和校验值固定在 `Dependencies.lock.json`。
- [ProjectClash/Clash-Adapter](https://github.com/ProjectClash/Clash-Adapter)：公开 PacketFlow 桥接和物理网络辅助代码。
- [ProjectClash/Clash-Client](https://github.com/ProjectClash/Clash-Client)：参考共享框架打包和平台接法。
- [trashvpn-windows](https://github.com/FuckGFWall/trashvpn-windows)：注册请求、协议参数和地址池参考。
- [usque](https://github.com/Diniboy1123/usque)：MASQUE 注册和设备公钥登记机制参考。

应用名称、图标及 Apple 身份沿用机主授权的原工程。许可证与依赖说明见 `LICENSE`、`Core/NOTICE`、`Core/THIRD_PARTY_LICENSES.md` 和 `Vendor/ClashAdapter/LICENSE`。
