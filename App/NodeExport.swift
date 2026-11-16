import Foundation
import Network

enum NodeExportFormat: String, CaseIterable, Identifiable, Sendable {
    case v2ray, clash, singBox
    var id: String { rawValue }
    var label: String { switch self { case .v2ray: return "V2Ray"; case .clash: return "Clash"; case .singBox: return "sing-box" } }
    static func available(for kind: WARPProtocol) -> [Self] { kind == .wg ? allCases : [.clash] }
    func detail(for kind: WARPProtocol) -> String {
        switch self {
        case .v2ray: return "适用于 v2rayN / v2rayNG 的 WireGuard 分享链接，每行一个节点。"
        case .clash: return kind == .masque ? "Clash YAML 节点配置块，合并到现有配置使用；MASQUE 需要兼容 ProjectClash 的内核。" : "Clash YAML 节点配置块，合并到现有配置使用。"
        case .singBox: return "sing-box 1.11+ 的 WireGuard 节点配置块，合并到现有配置使用。"
        }
    }
}

struct NodeExportPayload: Sendable {
    let text: String
    let count: Int
}

/// Only completed on-disk results are exported. API tokens and registration IDs never enter the payload.
struct NodeExportService {
    var accounts: any AccountStoring = KeychainAccountStore()
    var caches: any NodeCacheStoring = NodeCacheStore()
    private func snapshot(kind: WARPProtocol, family: IPAddressFamily) throws -> (WARPAccount, NodeCache)? {
        guard let account = try accounts.load(kind), let cache = try caches.load(kind, family: family),
              cache.canExport(for: account, family: family) else { return nil }
        return (account, cache)
    }
    func count(kind: WARPProtocol, family: IPAddressFamily) throws -> Int {
        try snapshot(kind: kind, family: family)?.1.results.count ?? 0
    }
    func export(kind: WARPProtocol, family: IPAddressFamily, format: NodeExportFormat, mtu: Int) throws -> NodeExportPayload {
        guard let (account, cache) = try snapshot(kind: kind, family: family) else {
            throw WARPError.message("\(kind.label) · \(family.label) 尚无可导出的已完成优选缓存。")
        }
        return try NodeExporter.render(cache: cache, account: account, format: format, mtu: mtu)
    }
}

enum NodeExporter {
    static func render(cache: NodeCache, account: WARPAccount, format: NodeExportFormat, mtu: Int) throws -> NodeExportPayload {
        guard NodeExportFormat.available(for: cache.kind).contains(format) else {
            throw WARPError.message("\(cache.kind.label) 无法完整导出为 \(format.label)。")
        }
        guard cache.canExport(for: account, family: cache.addressFamily), (1280...1500).contains(mtu),
              IPv4Address(account.ipv4) != nil,
              cache.addressFamily != .ipv6 || IPv6Address(account.ipv6) != nil else {
            throw WARPError.message("本地优选缓存与注册身份不匹配，无法导出。")
        }
        let nodes = cache.results.map(\.endpoint)
        let text: String
        switch format {
        case .v2ray:
            text = nodes.map { wireguardLink($0, account: account, family: cache.addressFamily, mtu: mtu) }.joined(separator: "\n")
        case .clash:
            let proxies = try WARPConfiguration.proxyDefinitions(endpoints: nodes, account: account, family: cache.addressFamily, mtu: mtu)
            text = try yaml(["proxies": proxies]).joined(separator: "\n") + "\n"
        case .singBox:
            let endpoints: [[String: Any]] = nodes.map { node in
                var peer: [String: Any] = ["address": node.host, "port": node.port, "public_key": account.peerPublicKey,
                    "allowed_ips": cache.addressFamily == .ipv6 ? ["0.0.0.0/0", "::/0"] : ["0.0.0.0/0"],
                    // Unselected endpoints must not send periodic handshakes with the same WARP identity.
                    "persistent_keepalive_interval": 0]
                if account.reserved.count == 3 { peer["reserved"] = account.reserved.map(Int.init) }
                return ["type": "wireguard", "tag": node.name, "system": false, "mtu": mtu,
                    "address": addresses(account: account, family: cache.addressFamily),
                    "private_key": account.privateKey, "peers": [peer]]
            }
            text = String(decoding: try JSONSerialization.data(withJSONObject: ["endpoints": endpoints],
                options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]), as: UTF8.self)
        }
        return NodeExportPayload(text: text, count: nodes.count)
    }

    private static func addresses(account: WARPAccount, family: IPAddressFamily) -> [String] {
        [account.ipv4 + "/32"] + (family == .ipv6 ? [account.ipv6 + "/128"] : [])
    }
    private static func encode(_ text: String) -> String {
        text.addingPercentEncoding(withAllowedCharacters: CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~"))!
    }
    private static func wireguardLink(_ node: WARPEndpoint, account: WARPAccount, family: IPAddressFamily, mtu: Int) -> String {
        var fields = [("publickey", account.peerPublicKey), ("address", addresses(account: account, family: family).joined(separator: ",")),
            ("mtu", String(mtu)), ("dns", "1.1.1.1")]
        if account.reserved.count == 3 { fields.append(("reserved", account.reserved.map(String.init).joined(separator: ","))) }
        let query = fields.map { encode($0.0) + "=" + encode($0.1) }.joined(separator: "&")
        return "wireguard://" + encode(account.privateKey) + "@" + node.address + "?" + query + "#" + encode(node.name)
    }

    /// JSON quoting is also valid YAML double-quoted syntax; keys are fixed ASCII configuration fields.
    private static func yaml(_ value: Any, indent: Int = 0) throws -> [String] {
        let prefix = String(repeating: " ", count: indent)
        if let object = value as? [String: Any] {
            return try object.keys.sorted().flatMap { key -> [String] in
                let child = object[key]!
                if let map = child as? [String: Any], !map.isEmpty { return [prefix + key + ":"] + (try yaml(map, indent: indent + 2)) }
                if let list = child as? [Any], !list.isEmpty { return [prefix + key + ":"] + (try yaml(list, indent: indent + 2)) }
                return [prefix + key + ": " + (try scalar(child))]
            }
        }
        if let list = value as? [Any] {
            return try list.flatMap { child -> [String] in
                if let map = child as? [String: Any], !map.isEmpty {
                    let lines = try yaml(map, indent: indent + 2)
                    return [prefix + "- " + lines[0].dropFirst(indent + 2)] + lines.dropFirst()
                }
                return [prefix + "- " + (try scalar(child))]
            }
        }
        return [prefix + (try scalar(value))]
    }
    private static func scalar(_ value: Any) throws -> String {
        String(decoding: try JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed, .sortedKeys, .withoutEscapingSlashes]), as: UTF8.self)
    }
}
