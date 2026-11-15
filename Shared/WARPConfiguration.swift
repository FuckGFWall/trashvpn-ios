import Foundation
import Network

enum WARPProtocol: String, CaseIterable, Codable, Identifiable, Sendable {
    case wg, awg, masque
    var id: String { rawValue }
    var label: String { rawValue.uppercased() }
    var detail: String {
        switch self {
        case .wg: return "WireGuard"
        case .awg: return "AmneziaWG"
        case .masque: return "MASQUE · HTTP/3"
        }
    }
}

struct WARPEndpoint: Identifiable, Codable, Equatable, Sendable {
    let host: String
    let port: Int
    var kind: WARPProtocol = .wg
    var address: String { host.contains(":") ? "[\(host)]:\(port)" : "\(host):\(port)" }
    var id: String { "\(kind.rawValue):\(address)" }
    var name: String { "\(kind.label) \(address)" }
    var family: IPAddressFamily? { IPAddressFamily.allCases.first { $0.contains(host) } }
    var isValid: Bool { family != nil && (1...65535).contains(port) }

    static func parse(_ address: String, kind: WARPProtocol) -> Self? {
        // IPv6 endpoints must be bracketed, otherwise the last hextet is ambiguous with a port.
        guard let parts = URLComponents(string: "udp://\(address)"), let rawHost = parts.host,
              let port = parts.port, parts.user == nil, parts.password == nil, parts.path.isEmpty,
              parts.query == nil, parts.fragment == nil else { return nil }
        let host = rawHost.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        let endpoint = Self(host: host, port: port, kind: kind)
        return endpoint.isValid ? endpoint : nil
    }

    private enum CodingKeys: String, CodingKey { case host, port, kind }
    init(host: String, port: Int, kind: WARPProtocol = .wg) { self.host = host; self.port = port; self.kind = kind }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        host = try values.decode(String.self, forKey: .host)
        port = try values.decode(Int.self, forKey: .port)
        kind = try values.decodeIfPresent(WARPProtocol.self, forKey: .kind) ?? .wg
    }

    static func lookup(_ id: String) -> WARPEndpoint? {
        fixtures.first { $0.id == id } ?? fixtures.first { $0.kind == .wg && $0.address == id }
    }
    static func fixtures(for kind: WARPProtocol) -> [WARPEndpoint] { fixtures.filter { $0.kind == kind } }

    static let fixtures = [
        WARPEndpoint(host: "8.39.125.159", port: 2408),
        WARPEndpoint(host: "8.6.112.85", port: 2408),
        WARPEndpoint(host: "8.6.112.7", port: 500),
        WARPEndpoint(host: "8.6.112.26", port: 2408, kind: .awg),
        WARPEndpoint(host: "8.6.112.125", port: 2408, kind: .awg),
        WARPEndpoint(host: "8.6.112.93", port: 2408, kind: .awg),
        WARPEndpoint(host: "8.35.211.176", port: 2408, kind: .awg),
        WARPEndpoint(host: "162.159.198.2", port: 443, kind: .masque),
        WARPEndpoint(host: "162.159.198.1", port: 1701, kind: .masque),
        WARPEndpoint(host: "162.159.198.1", port: 8095, kind: .masque),
        WARPEndpoint(host: "162.159.198.2", port: 500, kind: .masque)
    ]
}

enum WARPConfiguration {
    static let group = "group.com.leo.TrashVPN"
    static let providerID = "com.leo.TrashVPN.PacketTunnel"
    static let testURL = "https://cp.cloudflare.com/generate_204"
    static let peerKey = "bmXOC+F1FxEMF9dyiK2H5/1SUtzH0JuVo51h2wPfgyo="
    static let masquePeerPEM = """
    -----BEGIN PUBLIC KEY-----
    MFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAEIaU7MToJm9NKp8YfGxR6r+/h4mcG
    7SxI8tsW8OR1A5tv/zCzVbCRRh2t87/kxnP6lAy0lkr7qYwu+ox+k3dr6w==
    -----END PUBLIC KEY-----
    """
    static let masqueIPv6 = "2606:4700:110:87dc:a080:e8a:7697:e741"
    static let awgOptions: [String: Any] = [
        "jc": 6, "jmin": 10, "jmax": 50, "s1": 0, "s2": 0,
        "h1": 1, "h2": 2, "h3": 3, "h4": 4,
        "i1": "<r 2><b 0x858000010001000000000669636c6f756403636f6d0000010001c00c000100010000105a00044d583737>"
    ]

    static func normalizePublicKey(_ pem: String) throws -> String {
        let encoded = pem.components(separatedBy: .newlines)
            .filter { !$0.hasPrefix("-----") }.joined().filter { !$0.isWhitespace }
        guard let data = Data(base64Encoded: encoded), !data.isEmpty else {
            throw WARPError.message("MASQUE 公钥格式错误。")
        }
        return data.base64EncodedString()
    }

    static func container() throws -> URL {
        guard let url = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group) else {
            throw WARPError.message("无法访问 VPN 共享容器，请检查 App Group 签名。")
        }
        return url
    }

    static func render(endpoints: [WARPEndpoint], selected: WARPEndpoint, account: WARPAccount, tunnel: Bool,
        family: IPAddressFamily = .ipv4, settings: UserSettings? = nil, controller: ProbeController? = nil, probeProxy: ProbeProxy? = nil) throws -> String {
        var configuration = try (settings ?? UserSettings()).validated(); configuration.addressFamily = family
        guard account.isRegistered, account.kind == selected.kind, !endpoints.isEmpty, endpoints.contains(selected),
              endpoints.allSatisfy({ $0.kind == selected.kind && $0.isValid && $0.family == family }) else {
            throw WARPError.message("测试配置必须使用同一种协议的有效节点。")
        }
        let ipv6 = family == .ipv6
        guard !ipv6 || IPv6Address(account.ipv6) != nil else {
            throw WARPError.message("Cloudflare 注册身份缺少有效的 IPv6 地址，无法建立 IPv6 隧道。")
        }
        let custom = configuration.doNotSetDNS ? [] : try configuration.dnsServers()
        // The WARP transport already encrypts DNS. UDP inside it avoids an extra TLS cold start.
        let servers = custom.isEmpty ? ["1.1.1.1"] : custom
        let protectedDNS = configuration.doNotSetDNS || configuration.dnsLeakProtection
        let routed: (String) -> String = { protectedDNS ? $0 + "#" + selected.name : $0 }
        let proxies: [[String: Any]] = try endpoints.map { endpoint in
            var proxy: [String: Any] = ["name": endpoint.name, "type": "wireguard", "server": endpoint.host, "port": endpoint.port,
             "ip": account.ipv4, "private-key": account.privateKey, "public-key": account.peerPublicKey,
             "allowed-ips": ipv6 ? ["0.0.0.0/0", "::/0"] : ["0.0.0.0/0"], "persistent-keepalive": 25,
             "mtu": configuration.effectiveMTU, "udp": true, "workers": 1,
             "remote-dns-resolve": false]
            if account.reserved.count == 3 { proxy["reserved"] = account.reserved.map(Int.init) }
            if ipv6 { proxy["ipv6"] = account.ipv6 }
            if endpoint.kind == .awg { proxy["amnezia-wg-option"] = awgOptions }
            if endpoint.kind == .masque {
                proxy = ["name": endpoint.name, "type": "masque", "server": endpoint.host, "port": endpoint.port,
                    "private-key": account.privateKey, "public-key": try normalizePublicKey(account.peerPublicKey),
                    "ip": "\(account.ipv4)/32",
                    "sni": "consumer-masque.cloudflareclient.com", "network": "quic",
                    "mtu": configuration.effectiveMTU, "udp": true, "skip-cert-verify": false,
                    "remote-dns-resolve": false]
                if !account.ipv6.isEmpty { proxy["ipv6"] = "\(account.ipv6)/128" }
            }
            return proxy
        }
        let config: [String: Any] = [
            "mode": "rule", "log-level": "debug", "ipv6": ipv6,
            "allow-lan": false, "bind-address": "127.0.0.1", "mixed-port": probeProxy.map { Int($0.port) } ?? 0, "socks-port": 0, "port": 0,
            "authentication": probeProxy.map { ["\($0.username):\($0.password)"] } ?? [], "skip-auth-prefixes": [],
            // The SDK starts its Unix API in application mode only when a controller is configured.
            // Port 0 allocates a short-lived loopback port; the Unix API stays inside the app sandbox.
            "external-controller": tunnel ? "" : controller?.address ?? "127.0.0.1:0",
            "secret": controller?.secret ?? UUID().uuidString,
            "find-process-mode": "off", "geo-auto-update": false,
            "profile": ["store-selected": false, "store-fake-ip": false],
            "dns": ["enable": true, "ipv6": ipv6, "enhanced-mode": configuration.doNotSetDNS ? "redir-host" : "fake-ip",
                    "fake-ip-range": "198.18.0.1/16",
                    "fake-ip-range6": "fc00::/18",
                    "nameserver": servers.map(routed),
                    "default-nameserver": protectedDNS ? [routed("1.1.1.1")] : ["system"],
                    "proxy-server-nameserver": protectedDNS ? [routed("1.1.1.1")] : ["system"]],
            "tun": ["enable": tunnel, "stack": "gvisor", "auto-route": false,
                    "auto-detect-interface": false, "mtu": configuration.effectiveMTU,
                    "inet4-address": ["198.18.0.1/30"], "inet6-address": ["fdfe:dcba:9876::1/126"],
                    "dns-hijack": configuration.doNotSetDNS ? [] : ["any:53"]],
            "proxies": proxies, "rules": ["MATCH,\(selected.name)"]
        ]
        // YAML's JSON subset does not accept Foundation's optional escaped slash (\/).
        return String(decoding: try JSONSerialization.data(withJSONObject: config, options: [.sortedKeys, .withoutEscapingSlashes]), as: UTF8.self)
    }
}

enum WARPError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case let .message(message) = self { return message }; return nil }
}
