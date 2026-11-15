import Foundation

struct NodeCache: Codable, Equatable, Sendable {
    static let lifetime: TimeInterval = 6 * 60 * 60
    let schema: Int
    let kind: WARPProtocol
    let accountFingerprint: String
    let createdAt: Date
    let expiresAt: Date
    let results: [ProbeResult]
    private var family: IPAddressFamily?
    private var measurementFingerprint: String?
    private var sampleCount: Int?
    var addressFamily: IPAddressFamily { family ?? .ipv4 }

    init(account: WARPAccount, results: [ProbeResult], now: Date, family: IPAddressFamily = .ipv4, settings: UserSettings? = nil) throws {
        let rounds = settings?.strength.rounds ?? 3
        let usable = results.filter { result in
            result.endpoint.kind == account.kind && result.endpoint.family == family && result.samples.count == rounds && result.median != nil
                && (settings == nil || result.qualifies(settings!.strength))
        }
            .sorted(by: ProbeResult.isBetter)
        guard account.isRegistered, !usable.isEmpty else { throw WARPError.message("没有通过完整验证的节点，未更新缓存。") }
        schema = settings == nil ? 1 : 3; kind = account.kind; accountFingerprint = account.fingerprint
        createdAt = now; expiresAt = now.addingTimeInterval(settings?.cacheLifetime ?? Self.lifetime); self.results = usable
        self.family = family
        measurementFingerprint = settings?.measurementFingerprint; sampleCount = settings?.strength.rounds
    }

    func expiry(settings: UserSettings) -> Date { createdAt.addingTimeInterval(settings.cacheLifetime) }

    func isValid(for account: WARPAccount, now: Date, family: IPAddressFamily = .ipv4, settings: UserSettings? = nil) -> Bool {
        var configuration = settings ?? UserSettings(); configuration.addressFamily = family
        let validSchema = settings == nil && schema == 1
            ? expiresAt.timeIntervalSince(createdAt) == Self.lifetime
            : schema == 3 && measurementFingerprint == configuration.measurementFingerprint
                && sampleCount == configuration.strength.rounds
                && UserSettings.cacheDurations.contains { expiresAt.timeIntervalSince(createdAt) == TimeInterval($0 * 3600) }
        return validSchema && account.isRegistered && account.kind == kind && account.fingerprint == accountFingerprint
            && addressFamily == family
            && now >= createdAt && now < expiry(settings: configuration)
            && !results.isEmpty && results.allSatisfy {
                $0.endpoint.kind == kind && $0.endpoint.family == family && $0.endpoint.isValid && $0.samples.count == (settings == nil && schema == 1 ? 3 : configuration.strength.rounds) && $0.median != nil
                    && (settings == nil && schema == 1 || $0.qualifies(configuration.strength))
            }
    }
}

protocol NodeCacheStoring: Sendable {
    func load(_ kind: WARPProtocol) throws -> NodeCache?
    func load(_ kind: WARPProtocol, family: IPAddressFamily) throws -> NodeCache?
    func save(_ cache: NodeCache) throws
}

extension NodeCacheStoring {
    func load(_ kind: WARPProtocol, family: IPAddressFamily) throws -> NodeCache? {
        let cache = try load(kind)
        return cache?.addressFamily == family ? cache : nil
    }
}

struct NodeCacheStore: NodeCacheStoring {
    var root: URL?
    private func url(_ kind: WARPProtocol, family: IPAddressFamily) throws -> URL {
        let directory = try root ?? WARPConfiguration.container().appendingPathComponent("node-cache")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // Preserve the stage-two IPv4 cache path; old files decode as IPv4.
        return directory.appendingPathComponent("\(kind.rawValue)\(family == .ipv6 ? "-ipv6" : "").json")
    }
    func load(_ kind: WARPProtocol) throws -> NodeCache? {
        try load(kind, family: .ipv4)
    }
    func load(_ kind: WARPProtocol, family: IPAddressFamily) throws -> NodeCache? {
        let path = try url(kind, family: family)
        guard FileManager.default.fileExists(atPath: path.path) else { return nil }
        // A damaged cache is replaceable; account/keychain failures must remain visible.
        guard let data = try? Data(contentsOf: path), let cache = try? JSONDecoder().decode(NodeCache.self, from: data),
              cache.kind == kind, cache.addressFamily == family else { return nil }
        return cache
    }
    func save(_ cache: NodeCache) throws {
        try JSONEncoder().encode(cache).write(to: url(cache.kind, family: cache.addressFamily), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }
}
