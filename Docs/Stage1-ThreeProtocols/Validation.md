# 三协议第一阶段验收

2026-10-31，Richard（iPhone 12 Pro Max，iOS 18.7.8），应用版本 **1.0.0 (10011)**。保持原 Bundle ID、签名、图标和橘色主题，内核为 ProjectClash Apple SDK `v1.19.33-clash.4`。

产品范围只保留 **WG、AWG、MASQUE（QUIC/HTTP/3）**。不接入 MASQUE H2、WARP-in-WARP 或 MASQUE-in-MASQUE。

## 新增协议结果

7 项配置/兼容性检查、4 项新增协议真机测试和 1 项原 WG 回归全部通过，合计 **12/12，0 失败，0 跳过**。

| 协议 | 无系统 VPN 筛选 | 隧道实际出口 | 回主屏幕 20 秒后复测 |
| --- | --- | --- | --- |
| AWG | 4 个端点均取得有效 HTTPS 响应 | `8.6.112.125:2408`，`warp=on` | 通过 |
| MASQUE H3 | 4 个端点均取得有效 HTTPS 响应 | `162.159.198.1:8095`，`warp=on` | 通过 |
| WG 回归 | 首轮已验收 | `8.39.125.159:2408`，`warp=on` | 本次三协议构建中再次通过 |

测试目标为 `https://cp.cloudflare.com/generate_204`。每个端点串行测试三次，关闭出站后再切换下一端点；筛选期间系统 VPN 保持关闭。优先比较成功次数，再比较成功采样的延迟中位数。部分采样超时，结果仅代表当时的网络情况。

| AWG 端点 | 成功/采样 | 成功延迟中位数 |
| --- | --- | --- |
| `8.6.112.26:2408` | 2/3 | 320 ms |
| `8.6.112.125:2408` | 2/3 | 308 ms |
| `8.6.112.93:2408` | 1/3 | 322 ms |
| `8.35.211.176:2408` | 2/3 | 316 ms |

| MASQUE 端点 | 成功/采样 | 成功延迟中位数 |
| --- | --- | --- |
| `162.159.198.2:443` | 1/3 | 206 ms |
| `162.159.198.1:1701` | 3/3 | 264 ms |
| `162.159.198.1:8095` | 3/3 | 241 ms |
| `162.159.198.2:500` | 3/3 | 261 ms |

AWG 原样保留用户提供的 Jc/Jmin/Jmax、S1/S2、H1–H4、I1 及 25 秒保活。MASQUE 使用给定私钥、标准化后的 ECDSA 对端公钥、给定 SNI、IPv4/IPv6 地址及 QUIC，未关闭证书验证。

配置检查由实际链接的 SDK 完成；还检查了协议身份隔离、旧 WG 节点数据迁移，以及前台实例拒绝创建 TUN。

## 截图和记录

- [AWG 无 VPN 筛选](AWG-Probe.png) · [AWG 后台出口验证](AWG-Connected.png)
- [MASQUE 无 VPN 筛选](MASQUE-Probe.png) · [MASQUE 后台出口验证](MASQUE-Connected.png)
- [同一构建中的 WG 后台回归验证](WG-Connected.png)
- [机器可读结果及原始采样](TestSummary.json)
- 本地结果包：`TestResults/ThreeProtocols-Initial.xcresult`
- WG 回归结果包：`TestResults/ThreeProtocols-WG-Regression.xcresult`

## 范围

本轮验证真实账号和指定端点的 IPv4 数据链路，以及退至主屏幕后 20 秒复测。MASQUE 出站保留给定 IPv6 地址，但系统查询策略仍为 IPv4-only；未将 IPv6 完整性、长时间锁屏、Wi-Fi/蜂窝切换或高负载列为已验收项目。

自动注册和完整地址池扫描仍属于后续阶段。测试私钥只放在被忽略的本地凭据文件内，未写入源码、文档、日志或 VPN 偏好配置。
