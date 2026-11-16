import Foundation

struct CachedNodeChoice: Equatable, Sendable {
    let endpoint: WARPEndpoint
    let automatic: Bool
    static func resolve(_ cache: NodeCache, stored: String?, measurements: [String: NodeMeasurement] = [:]) -> Self? {
        if let stored, stored != "auto", let endpoint = cache.results.first(where: { $0.endpoint.id == stored })?.endpoint {
            return Self(endpoint: endpoint, automatic: false)
        }
        let fastest = cache.results.compactMap { result -> (WARPEndpoint, Int)? in
            guard let delay = measurements[result.endpoint.id]?.latencyMS ?? result.median.map(Int.init), delay > 0 else { return nil }
            return (result.endpoint, delay)
        }.min { $0.1 == $1.1 ? $0.0.id < $1.0.id : $0.1 < $1.1 }?.0 ?? ProbeResult.fastest(cache.results)
        return fastest.map { Self(endpoint: $0, automatic: true) }
    }
}

enum CachedTunnelTarget {
    /// A cache must match the running network snapshot; queued MTU/DNS changes stay queued.
    static func load(kind: WARPProtocol, running: UserSettings, latest: UserSettings,
        accounts: any AccountStoring, caches: any NodeCacheStoring, now: Date = Date()) throws -> NodeCache? {
        let settings = running.forProtocol(kind).withCachePolicy(from: latest)
        guard let account = try accounts.load(kind), let cache = try caches.load(kind, family: settings.addressFamily),
              cache.isValid(for: account, now: now, family: settings.addressFamily, settings: settings) else { return nil }
        return cache
    }
}

extension UserSettings {
    func forProtocol(_ kind: WARPProtocol) -> Self { var value = self; value.tunnelProtocol = kind; return value }
}

struct ActiveTunnelState: Codable, Equatable, Sendable {
    let sessionID: UUID
    let startedAt: Date
    let endpoint: WARPEndpoint
    let settings: UserSettings
    let automatic: Bool
    var revision: Int = 0
    var lastRequestID: UUID? = nil
    var tunOpenCount: Int = 1

    func selecting(_ endpoint: WARPEndpoint, automatic: Bool, requestID: UUID, settings: UserSettings) -> Self {
        var next = Self(sessionID: sessionID, startedAt: startedAt, endpoint: endpoint, settings: settings, automatic: automatic)
        next.revision = revision + 1; next.lastRequestID = requestID; next.tunOpenCount = tunOpenCount
        return next
    }
}

struct ActiveTunnelStore {
    var root: URL?
    private func url() throws -> URL { try (root ?? WARPConfiguration.container()).appendingPathComponent("active-tunnel.json") }
    func load() throws -> ActiveTunnelState? {
        let url = try url()
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try JSONDecoder().decode(ActiveTunnelState.self, from: Data(contentsOf: url))
    }
    func save(_ value: ActiveTunnelState) throws {
        try JSONEncoder().encode(value).write(to: url(), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }
    func remove(sessionID: UUID) throws {
        guard try load()?.sessionID == sessionID else { return }
        try FileManager.default.removeItem(at: url())
    }
}

struct TunnelSwitchRequest: Codable, Sendable {
    let id: UUID
    let sessionID: UUID
    let expectedRevision: Int
    let endpoint: WARPEndpoint
    let automatic: Bool
    func isConfirmed(by state: ActiveTunnelState) -> Bool {
        state.sessionID == sessionID && state.lastRequestID == id && state.revision > expectedRevision
            && state.endpoint == endpoint && state.automatic == automatic
            && state.settings.tunnelProtocol == endpoint.kind && state.settings.addressFamily == endpoint.family
    }
    func validate(current: ActiveTunnelState) throws {
        guard sessionID == current.sessionID, endpoint.isValid, endpoint.family == current.settings.addressFamily,
              expectedRevision == current.revision || current.lastRequestID == id else {
            throw WARPError.message("隧道状态已变化，请重试切换。")
        }
        if current.lastRequestID == id, current.endpoint != endpoint || current.automatic != automatic {
            throw WARPError.message("切换请求与已完成的请求不一致。")
        }
    }
}

struct TunnelSwitchReply: Codable, Sendable {
    let requestID: UUID
    let success: Bool
    let state: ActiveTunnelState?
    let error: String?
}

struct TunnelReloadFailure: LocalizedError {
    let message: LocalizedText
    let mayHaveChangedCore: Bool
    var errorDescription: String? { message.localized() }
}
struct TunnelSwitchFailure: LocalizedError {
    let message: LocalizedText
    let restored: Bool
    var errorDescription: String? { message.localized() }
}

/// A failed pre-commit reload keeps the old core; partial commits and later errors require rollback.
/// Called on the provider's serial queue. It never creates or stops a system VPN session.
struct TunnelSwitchTransaction {
    var installUnionRoutes: () throws -> Void
    var closeConnections: () -> Void
    var reloadTarget: () throws -> Void
    var installTargetRoutes: () throws -> Void
    var saveTarget: () throws -> Void
    var reloadPrevious: () throws -> Void
    var installPreviousRoutes: () throws -> Void
    var savePrevious: () throws -> Void

    func perform() throws {
        var changedCore = false, attemptedSave = false
        do {
            try installUnionRoutes()
            closeConnections()
            do { try reloadTarget(); changedCore = true }
            catch { changedCore = (error as? TunnelReloadFailure)?.mayHaveChangedCore ?? true; throw error }
            closeConnections()
            try installTargetRoutes()
            attemptedSave = true
            try saveTarget()
        } catch {
            do {
                if changedCore { closeConnections(); try reloadPrevious() }
                try installPreviousRoutes()
                if attemptedSave { try savePrevious() }
            } catch {
                throw TunnelSwitchFailure(message: "热切换失败且无法恢复原隧道，VPN 已停止，请手动重新连接。", restored: false)
            }
            throw TunnelSwitchFailure(message: "热切换失败，已保留原节点：\(error.localizedDescription)", restored: true)
        }
    }
}
