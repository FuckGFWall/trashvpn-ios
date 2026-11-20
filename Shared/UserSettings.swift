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
        // Legacy round counts above remain available when reading already completed v2 caches.
        var qualityCandidates: Int { switch self { case .low: return 4; case .medium: return 6; case .high: return 8 } }
        var desiredResults: Int { switch self { case .low: return 2; case .medium: return 3; case .high: return 4 } }
        var minimumRounds: Int { switch self { case .low: return 3; case .medium: return 4; case .high: return 5 } }
        var maximumRounds: Int { minimumRounds + 2 }
        var measuredDownloadBytes: Int { switch self { case .low: return 768 * 1024; case .medium: return 1024 * 1024; case .high: return 1536 * 1024 } }
        var downloadWarmupBytes: Int { 256 * 1024 }
        var downloadBudgetMiB: Int { Int(ceil(Double(qualityCandidates * (measuredDownloadBytes + downloadWarmupBytes)) / 1024 / 1024)) }
    }
    static let defaultCacheDays = 7
    static let validCacheDays = 1...36_500
    static let secondsPerDay: TimeInterval = 86_400
    var tunnelProtocol: WARPProtocol = .wg
    var theme: Theme = .system
    var language: AppLanguage = AppLanguage.system.resolved
    var addressFamily: IPAddressFamily = .ipv4
    var mtu = 0
    var customDNS = ""
    var dnsLeakProtection = true
    var doNotSetDNS = false
    var strength: Strength = .medium
    var autoConnectAfterOptimization = false
    var cacheDays = Self.defaultCacheDays
    var cacheNeverExpires = false
    var probeTimeout = 5
    var minimumDownloadMbps = 3.0
    var downloadTestEnabled = true
    var qualityProfile: ProbeQualityProfile { .init(strength: strength, downloadEnabled: downloadTestEnabled, minimumMbps: downloadTestEnabled ? minimumDownloadMbps : 0) }
    // Bound payload time near a very low user-specified floor instead of timing out a valid slow link.
    var measuredDownloadBytes: Int { min(strength.measuredDownloadBytes, max(64 * 1024, Int(minimumDownloadMbps * 1_000_000))) }
    var downloadWarmupBytes: Int { min(strength.downloadWarmupBytes, max(16 * 1024, Int(minimumDownloadMbps * 250_000))) }

    init() {}
    enum CodingKeys: String, CodingKey {
        case tunnelProtocol, theme, language, addressFamily, mtu, customDNS, dnsLeakProtection, doNotSetDNS, strength, cacheDays, cacheNeverExpires, probeTimeout, minimumDownloadMbps, downloadTestEnabled
        case autoConnectAfterOptimization
    }
    private enum LegacyCodingKeys: String, CodingKey { case cacheHours }
    init(from decoder: Decoder) throws {
        self.init()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        tunnelProtocol = try c.decodeIfPresent(WARPProtocol.self, forKey: .tunnelProtocol) ?? tunnelProtocol
        theme = try c.decodeIfPresent(Theme.self, forKey: .theme) ?? theme
        language = try c.decodeIfPresent(AppLanguage.self, forKey: .language) ?? .system
        addressFamily = try c.decodeIfPresent(IPAddressFamily.self, forKey: .addressFamily) ?? addressFamily
        mtu = try c.decodeIfPresent(Int.self, forKey: .mtu) ?? mtu
        customDNS = try c.decodeIfPresent(String.self, forKey: .customDNS) ?? customDNS
        dnsLeakProtection = try c.decodeIfPresent(Bool.self, forKey: .dnsLeakProtection) ?? dnsLeakProtection
        doNotSetDNS = try c.decodeIfPresent(Bool.self, forKey: .doNotSetDNS) ?? doNotSetDNS
        strength = try c.decodeIfPresent(Strength.self, forKey: .strength) ?? strength
        autoConnectAfterOptimization = try c.decodeIfPresent(Bool.self, forKey: .autoConnectAfterOptimization) ?? autoConnectAfterOptimization
        let legacyHours = try decoder.container(keyedBy: LegacyCodingKeys.self).decodeIfPresent(Int.self, forKey: .cacheHours)
        cacheDays = try c.decodeIfPresent(Int.self, forKey: .cacheDays) ?? Self.daysForLegacyCache(hours: legacyHours)
        cacheNeverExpires = try c.decodeIfPresent(Bool.self, forKey: .cacheNeverExpires) ?? (legacyHours == 0)
        probeTimeout = try c.decodeIfPresent(Int.self, forKey: .probeTimeout) ?? probeTimeout
        minimumDownloadMbps = try c.decodeIfPresent(Double.self, forKey: .minimumDownloadMbps) ?? minimumDownloadMbps
        downloadTestEnabled = try c.decodeIfPresent(Bool.self, forKey: .downloadTestEnabled) ?? downloadTestEnabled
    }
    private static func daysForLegacyCache(hours: Int?) -> Int {
        switch hours {
        case 12, 24: return 1
        case 48: return 2
        default: return defaultCacheDays // Six hours was the old default.
        }
    }
    var effectiveMTU: Int { mtu == 0 ? 1280 : mtu }
    var cacheDurationLabel: String { cacheDurationText.source }
    var cacheDurationText: LocalizedText {
        if cacheNeverExpires { return "永不过期" }
        return cacheDays == 1 ? "1 天" : "\(cacheDays) 天"
    }
    var cacheLifetime: TimeInterval { cacheNeverExpires ? .infinity : TimeInterval(cacheDays) * Self.secondsPerDay }
    func cacheExpiry(from start: Date) -> Date { cacheNeverExpires ? .distantFuture : start.addingTimeInterval(cacheLifetime) }
    func withCachePolicy(from latest: Self?) -> Self {
        guard let latest else { return self }
        var value = self
        value.cacheDays = latest.cacheDays
        value.cacheNeverExpires = latest.cacheNeverExpires
        return value
    }

    func validated() throws -> Self {
        guard mtu == 0 || (1280...1500).contains(mtu) else { throw WARPError.message("MTU 请填写 0（自动），或 1280–1500 的整数。") }
        guard Self.validCacheDays.contains(cacheDays) else { throw WARPError.message("缓存有效期请输入 1 至 36500 天的整数。") }
        guard (1...30).contains(probeTimeout) else { throw WARPError.message("探测超时应为 1–30 秒。") }
        guard minimumDownloadMbps.isFinite, (0.1...1000).contains(minimumDownloadMbps) else { throw WARPError.message("最小下载速度应为 0.1–1000 Mbps。") }
        guard !(doNotSetDNS && dnsLeakProtection) else { throw WARPError.message("保留系统 DNS 时无法同时启用 DNS 防泄漏。") }
        if !doNotSetDNS { _ = try dnsServers() }
        var value = self
        value.language = language.resolved
        return value
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
        let components = ["quality-v3", addressFamily.rawValue, String(effectiveMTU), doNotSetDNS ? "system-dns" : ((try? dnsServers().joined(separator: ",")) ?? customDNS),
            String(dnsLeakProtection), String(doNotSetDNS), strength.rawValue, String(probeTimeout), String(downloadTestEnabled), String(qualityProfile.minimumMbps)]
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
            let decoded = try JSONDecoder().decode(Self.self, from: Data(contentsOf: url))
            let value = try decoded.validated()
            if decoded.language == .system { try value.save(root: root) }
            return value
        }
        var value = Self()
        let legacy = directory.appendingPathComponent("network-preferences.json")
        if let data = try? Data(contentsOf: legacy), let preferences = try? JSONDecoder().decode(NetworkPreferences.self, from: data) {
            value.addressFamily = preferences.addressFamily
        }
        if let raw = UserDefaults.standard.string(forKey: "selectedProtocol"), let kind = WARPProtocol(rawValue: raw) { value.tunnelProtocol = kind }
        // Pin the initial system-language match once; later launches keep the user's choice.
        try value.save(root: root)
        return value
    }
    func save(root: URL? = nil) throws {
        let validated = try validated()
        let directory = try root ?? WARPConfiguration.container()
        try JSONEncoder().encode(validated).write(to: directory.appendingPathComponent("settings.json"), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        if root == nil { validated.language.persistSelection() }
    }
}
