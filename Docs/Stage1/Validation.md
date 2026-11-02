# 第一阶段真机验收

这是 WG 首轮验收的历史记录。当前协议范围已收敛为 WG、AWG、MASQUE（QUIC/HTTP/3）；三协议版本为 `1.0.0 (10011)`，新增协议另行验收。

2026-10-31，Richard（iPhone 12 Pro Max，iOS 18.7.8）。应用 `TrashVPN 1.0.0 (10010)`，沿用原工程的 Bundle ID、团队签名、软件名及图标。当前测试内核为 ProjectClash Apple SDK `v1.19.33-clash.4`，上游 Mihomo `1.19.33`。

## 结果

Xcode 真机验收 **6/6 通过，0 失败，0 跳过**。

| 测试 | 结果 |
| --- | --- |
| 前台配置关闭 TUN 和代理监听、指定出站正确，真实内核可解析配置 | 通过 |
| 前台平台接口拒绝创建 TUN | 通过 |
| 失败延迟不作为最快节点、成功采样中位数正确 | 通过 |
| 三端点实际 HTTPS 筛选，至少一个有效结果，系统 VPN 保持关闭 | 通过 |
| 筛选退至主屏幕后暂停，回来后 VPN 保持关闭 | 通过 |
| 指定 WG 节点连接、验证 WARP，退至主屏幕 20 秒后再次验证 | 通过 |

最后一项使用 `8.39.125.159:2408`。Cloudflare Trace 确认 **`warp=on`**，并观察到扩展双向收发包。测试结束保留该 VPN 连接。

机器可读汇总见 [TestSummary.json](TestSummary.json)。完整本地测试结果位于 `TestResults/Device-Stage1-Acceptance.xcresult`；该目录被 `.gitignore` 排除。

## 真机截图

[无 VPN 筛选](WARP-Probe.png) · [退后台后 WARP 出口验证](WARP-Connected.png)

## 本轮解决的接入问题

- Apple SDK 的 `DisablePersistentCache` 属于只读配置检查模式，运行代理服务必须使用可写的独立工作目录。
- 配置以 JSON 形式传入 YAML 解析器时，禁止 Foundation 生成 `\/` 转义。
- App Group 路径较长，控制 socket 使用短目录，以满足 Darwin Unix socket 路径长度限制。
- WG 对端使用显式 `/32` 排除路由，出站 socket 同时绑定物理接口，避免 VPN 路由回环。
- `https://1.1.1.1/cdn-cgi/trace` 会返回 302；筛选改用返回 204 的 Cloudflare 测试地址。
- 域名在 WG 内解析，隧道的 DoH 请求也经过 WG，避免依赖当前网络的直连 DoH 可达性。
- 同一测试身份按端点逐个创建、测试和销毁出站，清理前一个端点的保活定时器。

## 验收范围

本阶段确认给定账号的 WG 数据链路。三个端点均纳入筛选，采样会随网络情况出现超时；第三个端点曾在筛选时可用，后续连接握手却超时，因此端点扫描结果代表测试当时的情况。

本轮后台验收覆盖退至主屏幕 20 秒后的复测。长时间锁屏、Wi-Fi/蜂窝切换和高负载尚未验收；已设置不因睡眠主动断开，凭据在首次解锁后可供扩展读取。自动注册与完整地址池扫描留待后续；新增 AWG、MASQUE 的结果以三协议版本的独立验收为准。
