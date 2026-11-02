# 第三阶段：先完成 IPv6

用户本轮允许优先实现 IPv6；完整首页、进度条、主题、MTU、DNS 和优选设置留到后续。缓存时长选项已明确为 **6 / 12 / 24 / 48 小时**，当前实现仍使用 6 小时。

版本为 **1.0.0 (10013)**，沿用原 Bundle ID、签名、名称、图标。设备为 Richard，iPhone 12 Pro Max，iOS 18.7.8。

## 实现范围

- 设置增加 IPv4 / IPv6 地址族，选择保存到 App Group；断开 VPN 后可以切换。切换立即自动检查对应缓存。
- 地址族指连接 WARP 入口的传输地址；IPv6 模式同时支持隧道内 IPv4 和 IPv6 流量。
- 注册响应同时解析 v4 / v6 端点和分配的双栈地址；IPv6 地址显示为 `[address]:port`。
- WG / AWG 的 IPv6 模式配置双栈本地地址及 `0.0.0.0/0`、`::/0` Allowed IPs。MASQUE 配置双栈地址与 IPv6 QUIC 入口。
- 内核启用 AAAA、IPv6 fake-IP 和 prefer-ipv6，保留 IPv4 目标的可用性。IPv4 模式保持 IPv4-only。
- 前台优选仍然 `tun=false`，平台层拒绝创建 TUN；候选列表严格过滤地址族。
- 缓存按协议、注册身份和地址族隔离：旧 `{protocol}.json` 继续作为 IPv4，新增 `{protocol}-ipv6.json`。读取旧缓存不延长到期时间；切换地址族不重建注册身份。
- Packet Tunnel 捕获双栈默认路由；仅将当前服务器以 IPv4 `/32` 或 IPv6 `/128` 排除，避免物理出站回环。IPv6 模式关闭系统的本地网络绕过，确保 ULA fake-IP 留在隧道中。
- IPv6 出口验证要求 Cloudflare Trace 返回 IPv6 地址且 `warp=on/plus`；另以两个 IP 字面量、禁止重定向的 HTTPS 请求分别验证 IPv4 与 IPv6 包链路。
- 每次复测独立创建和清理内核实例，规避 URL-test 结束后 MASQUE 会话关闭对后续复测的影响；同一身份不会同时运行多个端点。

## 验证方法

单元测试覆盖 IPv6 端点解析、注册双栈响应、三协议候选过滤、真实 SDK 双栈配置检查、缺失 IPv6 地址、混合地址族拒绝、缓存迁移与隔离、身份复用、六小时边界、双栈默认路由和 `/128` 排除路由，并保留此前所有注册/配置/缓存测试。

真机 UI 测试先在未启用 VPN 时自动优选，重启应用确认缓存命中，再连接并验证出口；退至主屏幕 20 秒后回前台再次验证。另测试设置切换与重启后的偏好持久化。

## 首轮结果及排查

- `IPv6-Unit.xcresult`：首批 26 项单元测试通过；随后新增地址族切换不重新注册的测试。
- `IPv6-WG-Live.xcresult`：Wi-Fi 下 WG 的 48 个 IPv6 候选均未通过初筛；没有写入失败缓存，注册身份保留。
- `IPv6-AWG-MASQUE-Live.xcresult`：AWG 在 Wi-Fi、切换蜂窝后的剩余候选中均未通过初筛。MASQUE 在蜂窝网络下完成优选、重启命中缓存、建隧道、IPv6 出口验证和退后台后的再次验证。
- 首次 MASQUE 成功端点 `[2606:4700:103::1]:500`，Trace 显示 `warp=on`、IPv6 出口 `2a09:bac1:19c0:20::4e8:1`。该轮已验证隧道内 IPv4 HTTPS；追加的 IPv6 字面量 HTTPS 检查已在后续构建通过。
- 首轮还运行过直接在 XCTest UI 运行器中建立原生 IPv6 TLS 的诊断。运行器日志出现 `Denied over cellular interface`；这项失败不能作为主 App 原生 IPv6 不可用的证据，已移除该测试，采用主 App 的实际内核探测和通网结果判断。首次请求用户切换网络时对此权限限制认识不足，记录在此纠正。
- 初次 MASQUE 复测出现首次成功、后续请求超时，而正式隧道持续正常的情况；随后将每个复测样本改为独立内核实例，实测结果见后续记录。

## 后续结果

`IPv6-Cellular.xcresult`：27 项单元测试全部通过。WG、AWG 各 48 个 IPv6 候选在蜂窝网络下仍未通过初筛，这两项不能标记为通网验收通过。MASQUE IPv6 用例通过，包括重启命中缓存、双栈字面量 HTTPS、IPv6 WARP 出口和后台 20 秒后的再次验证；地址族切换及偏好持久化用例也通过。总计 31 项：29 通过、2 未通过，失败均保留在结果包中。

`IPv6-IPv4-Regression.xcresult`：WG IPv4、MASQUE IPv4 真机回归通过；AWG IPv4 首次出口 HTTPS 超时；`IPv6-AWG-IPv4-Retry.xcresult` 使用同一缓存、同一注册身份复测通过（28 秒），没有通过重新注册来掩盖失败。

`IPv6-MASQUE-Final.xcresult`：最终两项测试全部通过。主动重新优选时 VPN 保持未连接；独立内核实例的复测为 `[2606:4700:103::2]:443` 得到 **320 / 320 / 321 ms（3/3）**，优先排在 2/3、1/3 的节点前面。新缓存完成时间约 19:22，期限约次日 01:22。随后用该缓存重启、连接，验证 IPv6 出口 `2a09:bac5:1f0c:281e::3ff:3e`、`warp=on`、IPv4 字面量 HTTPS 与 IPv6 字面量 HTTPS；退至主屏幕 20 秒后再次验证通过。

| 协议 | IPv4 回归 | IPv6 真机通网 |
| --- | --- | --- |
| WG | 通过 | 未通过初筛，当前没有可用结果 |
| AWG | 首次超时，同节点复测通过 | 未通过初筛，当前没有可用结果 |
| MASQUE H3 | 通过 | 通过，包含 3/3 优选、双栈 HTTPS 和后台验证 |

最终安装版本为 1.0.0 (10013)，Richard 留在 MASQUE / IPv6、断开 VPN、缓存可用的状态。未修改手机 Wi-Fi 开关，保留用户切换后的蜂窝网络状态。

最终截图：[三次复测](MASQUE-Final-Three-Samples.png)、[后台后通网](MASQUE-Final-Background.png)。摘要与采样日志随本目录保留，原始 `.xcresult` 在忽略的 `TestResults` 目录内。

## 边界

短时间退后台已经验证的项目会单独列出；长时间锁屏、Wi-Fi/蜂窝无缝切换、不同运营商、高负载尚未验收。`NWPath.supportsIPv6` 仅作本地地址族预检，不能保证 WARP 入口可达。节点不可达时会明确报错，保留身份和旧缓存，不静默切换到 IPv4 入口。

## 参考

- [Windows 客户端](https://github.com/FuckGFWall/trashvpn-windows)：消费者 IPv6 地址池位于 `engine/pools.go`、`engine/masque.go`，注册及协议配置同源。
- [ProjectClash/Clash](https://github.com/ProjectClash/Clash)：项目固定版本的 Apple SDK、WG/MASQUE 出站、URL-test API 和地址族查询策略。
- [Apple NEIPv6Settings](https://developer.apple.com/documentation/networkextension/neipv6settings)、[NEDNSSettings](https://developer.apple.com/documentation/networkextension/nednssettings)：iOS 双栈路由和 DNS 设置。
