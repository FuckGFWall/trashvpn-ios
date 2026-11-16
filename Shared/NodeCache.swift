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
    private var qualityProfile: ProbeQualityProfile?
    var addressFamily: IPAddressFamily { family ?? .ipv4 }
    private var measuredStrength: UserSettings.Strength? { UserSettings.Strength.allCases.first { $0.rounds == sampleCount } }

    init(account: WARPAccount, results: [ProbeResult], now: Date, family: IPAddressFamily = .ipv4, settings: UserSettings? = nil) throws {
        let usable = results.filter { result in
            result.endpoint.kind == account.kind && result.endpoint.family == family && result.endpoint.isValid && result.median != nil
                && (settings.map { result.qualifies(settings: $0) } ?? (result.samples.count == 3))
        }.sorted(by: ProbeResult.isBetter)
        guard account.isRegistered, !usable.isEmpty else { throw WARPError.message("没有通过完整验证的节点，未更新缓存。") }
        let adaptive = usable.allSatisfy { $0.qualityVersion == 3 }
        guard settings == nil || adaptive || usable.allSatisfy({ $0.qualityVersion == 2 }) else {
            throw WARPError.message("测量版本不一致，未更新缓存。")
        }
        schema = settings == nil ? 1 : adaptive ? 4 : 3
        kind = account.kind; accountFingerprint = account.fingerprint
        createdAt = now; expiresAt = settings?.cacheExpiry(from: now) ?? now.addingTimeInterval(Self.lifetime); self.results = usable
        self.family = family; qualityProfile = adaptive ? settings?.qualityProfile : nil
        measurementFingerprint = settings?.measurementFingerprint; sampleCount = settings?.strength.rounds
    }

    func expiry(settings: UserSettings) -> Date { settings.cacheExpiry(from: createdAt) }

    /// Validate against the originally recorded policy so permanent caches and exports survive preference changes.
    func canExport(for account: WARPAccount, family: IPAddressFamily) -> Bool {
        guard [3, 4].contains(schema), account.isRegistered, account.kind == kind, account.fingerprint == accountFingerprint,
              addressFamily == family, !results.isEmpty,
              Set(results.map { $0.endpoint.id }).count == results.count else { return false }
        return results.allSatisfy { result in
            guard result.endpoint.kind == kind, result.endpoint.family == family, result.endpoint.isValid else { return false }
            if schema == 4 { return qualityProfile.map { result.qualifies($0) } == true }
            return result.qualityVersion == 2 && measuredStrength.map { result.qualifies($0) } == true
        }
    }

    func isValid(for account: WARPAccount, now: Date, family: IPAddressFamily = .ipv4, settings: UserSettings? = nil) -> Bool {
        var configuration = settings ?? UserSettings(); configuration.addressFamily = family
        guard account.isRegistered, account.kind == kind, account.fingerprint == accountFingerprint, addressFamily == family else { return false }
        if settings == nil && schema == 1 {
            return expiresAt.timeIntervalSince(createdAt) == Self.lifetime && now >= createdAt && now < expiresAt
                && !results.isEmpty && results.allSatisfy { $0.endpoint.kind == kind && $0.endpoint.family == family && $0.endpoint.isValid && $0.samples.count == 3 && $0.median != nil }
        }
        guard canExport(for: account, family: family),
              expiresAt == .distantFuture || UserSettings.cacheDurations.filter({ $0 > 0 }).contains(where: { expiresAt.timeIntervalSince(createdAt) == TimeInterval($0 * 3600) }) else { return false }
        if configuration.cacheNeverExpires { return true }
        return measurementFingerprint == configuration.measurementFingerprint && now >= createdAt && now < expiry(settings: configuration)
            && (schema == 4 ? qualityProfile == configuration.qualityProfile : sampleCount == configuration.strength.rounds)
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
