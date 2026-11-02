import CryptoKit
import Foundation
import Network

struct UserSettings: Codable, Equatable, Sendable {
    enum Theme: String, Codable, CaseIterable, Identifiable, Sendable {
        case system, light, dark
        var id: String { rawValue }
        var label: String { switch self { case .system: return "跟随系统"; case .light: return "浅色"; case .dark: return "深色" } }
    }
    enum Strength: String, Codable, CaseIterable, Identifiable, Sendable {
        case low, medium, high
        var id: String { rawValue }
        var label: String { switch self { case .low: return "低"; case .medium: return "中"; case .high: return "高" } }
        var candidates: Int { switch self { case .low: return 64; case .medium: return 160; case .high: return 320 } }
        var finalists: Int { switch self { case .low: return 6; case .medium: return 10; case .high: return 16 } }
        var rounds: Int { switch self { case .low: return 5; case .medium: return 8; case .high: return 12 } }
        var requiredSuccesses: Int { switch self { case .low: return 4; case .medium: return 7; case .high: return 11 } }
        var downloadRounds: Int { switch self { case .low: return 2; case .medium: return 3; case .high: return 4 } }
        var downloadBytes: Int { switch self { case .low: return 768 * 1024; case .medium: return 1536 * 1024; case .high: return 2 * 1024 * 1024 } }
        var warmupBytes: Int { 512 * 1024 }
        var maxDownloadMiB: Int { Int(ceil(Double(finalists * (downloadRounds * downloadBytes + warmupBytes)) / 1024 / 1024)) }
        var jitterFactor: Double { switch self { case .low: return 0.75; case .medium: return 0.6; case .high: return 0.5 } }
        var speedConsistency: Double { switch self { case .low: return 0.4; case .medium: return 0.55; case .high: return 0.7 } }

    }
    static let cacheDurations = [6, 12, 24, 48]
    var tunnelProtocol: WARPProtocol = .wg
    var theme: Theme = .system
    var addressFamily: IPAddressFamily = .ipv4
    var mtu = 0
    var customDNS = ""
    var dnsLeakProtection = true
    var doNotSetDNS = false
    var strength: Strength = .medium
    var cacheHours = 6
    var probeTimeout = 5
    var effectiveMTU: Int { mtu == 0 ? 1280 : mtu }
    var cacheLifetime: TimeInterval { TimeInterval(cacheHours * 3600) }

    func validated() throws -> Self {
        guard mtu == 0 || (1280...1500).contains(mtu) else { throw WARPError.message("MTU 请填写 0（自动），或 1280–1500 的整数。") }
        guard Self.cacheDurations.contains(cacheHours) else { throw WARPError.message("请选择 6、12、24 或 48 小时缓存。") }
        guard (1...30).contains(probeTimeout) else { throw WARPError.message("探测超时应为 1–30 秒。") }
        guard !(doNotSetDNS && dnsLeakProtection) else { throw WARPError.message("保留系统 DNS 时无法同时启用 DNS 防泄漏。") }
        if !doNotSetDNS { _ = try dnsServers() }
        return self
    }

    /// Transport syntax owned by the app; routing fragments cannot be supplied by user text.
    func dnsServers() throws -> [String] {
        let entries = customDNS.split(whereSeparator: { $0.isWhitespace || $0 == "," || $0 == "，" }).map(String.init)
        guard entries.count <= 8 else { throw WARPError.message("自定义 DNS 最多填写 8 个地址。") }
        var result: [String] = []
        for entry in entries {
            let text = entry.contains("://") ? entry : IPAddressFamily.ipv6.contains(entry) ? "udp://[\(entry)]" : "udp://\(entry)"
            guard let url = URLComponents(string: text), let scheme = url.scheme?.lowercased(),
                  ["udp", "tcp", "tls", "https", "quic"].contains(scheme), let rawHost = url.host,
                  !rawHost.isEmpty, url.user == nil, url.password == nil, url.fragment == nil, url.query == nil,
                  url.port.map({ (1...65535).contains($0) }) ?? true,
                  scheme == "https" || url.path.isEmpty else { throw WARPError.message("DNS 地址无效：\(entry)。支持 IP、IP:端口，以及 udp/tcp/tls/https/quic 地址。") }
            let host = rawHost.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
            let validHost = IPAddressFamily.allCases.contains { $0.contains(host) }
                || (host.count <= 253 && host.contains(".") && !host.allSatisfy { $0.isNumber || $0 == "." } && host.split(separator: ".", omittingEmptySubsequences: false).allSatisfy {
                    !$0.isEmpty && $0.count <= 63 && $0.first != "-" && $0.last != "-"
                    && $0.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }
                })
            guard validHost, !host.contains("%") else { throw WARPError.message("DNS 服务器地址无效：\(entry)") }
            var normalized = url
            normalized.scheme = scheme
            if scheme == "https" && url.path.isEmpty { normalized.path = "/dns-query" }
            guard let value = normalized.string else { throw WARPError.message("DNS 地址无法解析。") }
            if !result.contains(value) { result.append(value) }
        }
        return result
    }

    /// Preference-only changes do not invalidate measured nodes or move their original timestamp.
    var measurementFingerprint: String {
        let components = ["quality-v2", addressFamily.rawValue, String(effectiveMTU), doNotSetDNS ? "system-dns" : ((try? dnsServers().joined(separator: ",")) ?? customDNS),
            String(dnsLeakProtection), String(doNotSetDNS), strength.rawValue, String(probeTimeout)]
        return SHA256.hash(data: Data(components.joined(separator: "|").utf8)).map { String(format: "%02x", $0) }.joined()
    }
    var supportsLegacyCache: Bool {
        var defaults = Self(); defaults.addressFamily = addressFamily
        return measurementFingerprint == defaults.measurementFingerprint
    }
    static func load(root: URL? = nil) throws -> Self {
        let directory = try root ?? WARPConfiguration.container()
        let url = directory.appendingPathComponent("settings.json")
        if FileManager.default.fileExists(atPath: url.path) {
            return try JSONDecoder().decode(Self.self, from: Data(contentsOf: url)).validated()
        }
        var value = Self()
        let legacy = directory.appendingPathComponent("network-preferences.json")
        if let data = try? Data(contentsOf: legacy), let preferences = try? JSONDecoder().decode(NetworkPreferences.self, from: data) {
            value.addressFamily = preferences.addressFamily
        }
        if let raw = UserDefaults.standard.string(forKey: "selectedProtocol"), let kind = WARPProtocol(rawValue: raw) { value.tunnelProtocol = kind }
        return value
    }
    func save(root: URL? = nil) throws {
        let validated = try validated()
        let directory = try root ?? WARPConfiguration.container()
        try JSONEncoder().encode(validated).write(to: directory.appendingPathComponent("settings.json"), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }
}
