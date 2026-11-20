import Foundation

enum PreparationUpdate: Sendable {
    case status(LocalizedText)
    case progress(PreparationProgress)
    case sample(ProbeResult)
}

struct PreparedNodes: Sendable {
    let cache: NodeCache
    let reusedCache: Bool
}

protocol NodeOptimizing: Sendable {
    func optimize(account: WARPAccount, previous: NodeCache?,
        progress: @escaping @Sendable (PreparationUpdate) async -> Void) async throws -> [ProbeResult]
    func optimize(account: WARPAccount, previous: NodeCache?, steps: [PreparationProgress.Stage],
        progress: @escaping @Sendable (PreparationUpdate) async -> Void) async throws -> [ProbeResult]
}
extension NodeOptimizing {
    func optimize(account: WARPAccount, previous: NodeCache?, steps: [PreparationProgress.Stage],
        progress: @escaping @Sendable (PreparationUpdate) async -> Void) async throws -> [ProbeResult] {
        try await optimize(account: account, previous: previous, progress: progress)
    }
}

struct EndpointCatalog {
    static let wireguardNetworks = ["8.6.112", "8.34.70", "8.34.146", "8.35.211", "8.39.125", "8.39.204",
        "8.39.214", "8.47.69", "162.159.192", "162.159.195", "188.114.96", "188.114.97", "188.114.98", "188.114.99"]
    // Public WARP ports used by the Windows client's fallback discovery.
    static let alternatePorts = [
        864, 854, 859, 878, 880, 890, 891, 894, 903, 908,
        928, 934, 939, 942, 943, 945, 946, 955, 968, 987,
        988, 1002, 1010, 1014, 1018, 1070, 1074, 1180, 1387, 1843,
        2371, 2506, 3138, 3476, 3581, 3854, 4177, 4198, 4233, 5279,
        5956, 7103, 7152, 7156, 7281, 7559, 8319, 8742, 8854, 8886
    ]
    private static func campusEndpoint(_ kind: WARPProtocol) -> WARPEndpoint {
        WARPEndpoint(host: "8.35.211.127", port: 864, kind: kind)
    }

    static func candidates(account: WARPAccount, previous: NodeCache?, family: IPAddressFamily = .ipv4, limit: Int = 48) -> [WARPEndpoint] {
        let kind = account.kind
        var nodes = (previous?.results.map(\.endpoint) ?? []) + account.endpoints
        if family == .ipv6 {
            // Consumer WARP ingress pools, matching the Windows client's pools.
            // Registration-provided endpoints and previously measured endpoints take priority.
            let ports = kind == .masque ? [443, 500, 1701, 4500, 4443, 8443, 8095] : [2408, 500, 1701, 4500]
            var hosts: [String]
            if kind == .masque {
                hosts = ["2606:4700:103::1", "2606:4700:103::2", "2606:4700:104::1", "2606:4700:104::2"]
            } else {
                hosts = ["2606:4700:d0::a29f:c001", "2606:4700:d1::a29f:c001", "2606:4700:d0::1", "2606:4700:d1::1"]
                for prefix in ["2606:4700:d0", "2606:4700:d1"] {
                    for _ in 0..<max(4, (limit + 7) / 8) {
                        let suffix = (0..<4).map { _ in String(UInt16.random(in: 1...UInt16.max), radix: 16) }.joined(separator: ":")
                        hosts.append("\(prefix):0:\(suffix)")
                    }
                }
            }
            for port in ports {
                nodes += hosts.map { WARPEndpoint(host: $0, port: port, kind: kind) }
            }
        } else if kind == .masque {
            nodes += WARPEndpoint.fixtures(for: .masque)
            for port in [443, 500, 1701, 4500, 4443, 8443, 8095] {
                for host in ["162.159.198.2", "162.159.198.1"] {
                    nodes.append(WARPEndpoint(host: host, port: port, kind: kind))
                }
            }
        } else {
            // Warm hints are public server addresses only; all probes use the newly registered identity.
            nodes += WARPEndpoint.fixtures.filter { $0.kind != .masque }.map { WARPEndpoint(host: $0.host, port: $0.port, kind: kind) }
            nodes.append(campusEndpoint(kind))
            let ports = [2408, 500, 1701, 4500]
            for round in 0..<(limit / wireguardNetworks.count + 1) {
                for prefix in wireguardNetworks.shuffled() {
                    nodes.append(WARPEndpoint(host: "\(prefix).\(Int.random(in: 1...254))", port: ports[round % ports.count], kind: kind))
                }
            }

        }
        var seen = Set<String>()
        return Array(nodes.filter { $0.kind == kind && $0.isValid && $0.family == family && seen.insert($0.id).inserted }.prefix(limit))
    }

    static func supplementalCandidates(for primary: [WARPEndpoint]) -> [WARPEndpoint] {
        guard let first = primary.first, first.kind != .masque else { return primary }
        var candidates: [WARPEndpoint] = []
        var seen = Set<String>()
        func add(_ endpoint: WARPEndpoint) {
            if candidates.count < primary.count, seen.insert(endpoint.id).inserted { candidates.append(endpoint) }
        }
        if first.family == .ipv4 { add(campusEndpoint(first.kind)) }
        // Retry a few original endpoints with DNS removed from the screening request.
        for endpoint in primary.prefix(8) { add(endpoint) }
        var seenHosts = Set<String>()
        let hosts = primary.map(\.host).filter { seenHosts.insert($0).inserted }
        // Cover the port list before revisiting a port. On the next lap use a different host.
        for lap in hosts.indices {
            for (index, port) in alternatePorts.enumerated() {
                add(WARPEndpoint(host: hosts[(index + lap) % hosts.count], port: port, kind: first.kind))
                if candidates.count == primary.count { return candidates }
            }
        }
        return candidates
    }
}

actor MihomoOptimizer: NodeOptimizing {
    private let probe = EndpointProbe()
    private let quality = NodeQualityProbe()
    private let checkpoints: any OptimizationCheckpointStoring
    private let userInitiated: Bool
    let configuration: UserSettings
    init(family: IPAddressFamily = .ipv4, settings: UserSettings? = nil,
        checkpoints: any OptimizationCheckpointStoring = OptimizationCheckpointStore(), userInitiated: Bool = false) {
        var value = settings ?? UserSettings(); value.addressFamily = family; configuration = value
        self.checkpoints = checkpoints
        self.userInitiated = userInitiated
    }
    func optimize(account: WARPAccount, previous: NodeCache?,
        progress: @escaping @Sendable (PreparationUpdate) async -> Void) async throws -> [ProbeResult] {
        try await optimize(account: account, previous: previous, steps: PreparationProgress.plan(existing: account, download: configuration.downloadTestEnabled), progress: progress)
    }
    func optimize(account: WARPAccount, previous: NodeCache?, steps: [PreparationProgress.Stage],
        progress: @escaping @Sendable (PreparationUpdate) async -> Void) async throws -> [ProbeResult] {
        var value = configuration; value.tunnelProtocol = account.kind
        let config = value
        let saved = try checkpoints.load(account.kind, family: config.addressFamily)
        var initial: OptimizationCheckpoint
        if let saved, saved.isValid(account: account, settings: config, now: Date()) {
            initial = saved
            Diagnostics.record("optimization resumed id=\(saved.id) screeningRounds=\(saved.screening.values.reduce(0) { $0 + $1.samples.count }) completedNodes=\(saved.completed.count) partialRounds=\(saved.partial?.samples.count ?? 0) downloads=\(saved.partial?.downloadMbps?.count ?? 0)", process: "app")
        } else {
            let candidates = EndpointCatalog.candidates(account: account, previous: previous,
                family: config.addressFamily, limit: config.strength.candidates)
            initial = OptimizationCheckpoint(account: account, settings: config, candidates: candidates, userInitiated: userInitiated)
            try checkpoints.save(initial)
            Diagnostics.record("optimization started id=\(initial.id) candidates=\(candidates.count)", process: "app")
        }
        initial.progress.steps = initial.progress.steps ?? steps
        try checkpoints.save(initial)
        let journal = OptimizationJournal(initial, store: checkpoints)
        let publish: @Sendable (PreparationUpdate) async -> Void = { await journal.publish($0, to: progress) }
        await publish(.progress(initial.progress))
        for result in initial.displayResults { await publish(.sample(result)) }
        var finalists = initial.finalists
        if finalists == nil {
            let screened = try await probe.run(journal: journal, account: account, settings: config, progress: publish)
            try Task.checkCancellation()
            let selected = screened.sorted(by: ProbeResult.isBetter).map(\.endpoint)
            guard !selected.isEmpty else {
                try checkpoints.remove(account.kind, family: config.addressFamily)
                throw WARPError.message("当前网络未找到可用的 \(account.kind.label) · \(config.addressFamily.label) 端点，可切换网络或地址族后重试。注册身份已保留。")
            }
            await publish(.progress(.init(stage: .shortlist, fraction: 0.58, title: "整理候选节点",
                detail: "入围 \(selected.count) 个节点，取得 \(config.strength.desiredResults) 个合格节点即结束；\(config.downloadTestEnabled ? "检查稳定性、YouTube 连通和下载速度" : "只检查稳定性与 YouTube 连通，跳过下载测速")")))
            try await journal.shortlist(selected)
            finalists = selected
        }
        let snapshot = await journal.snapshot()
        return try await quality.run(endpoints: finalists ?? [], account: account, settings: config,
            completed: snapshot.completed, partial: snapshot.partial, useLiteralTrace: snapshot.supplementalScreening == true,
            checkpoint: { try await journal.sample($0) }, didComplete: { try await journal.finish($0) }, progress: publish)
    }
}

struct NodePreparation: Sendable {
    let accounts: any AccountStoring
    let caches: any NodeCacheStoring
    let registration: any WARPRegistering
    let optimizer: any NodeOptimizing
    var family: IPAddressFamily = .ipv4
    var settings: UserSettings? = nil
    var checkpoints: (any OptimizationCheckpointStoring)? = nil
    var now: @Sendable () -> Date = { Date() }

    func prepare(kind: WARPProtocol, force: Bool = false,
        progress sink: @escaping @Sendable (PreparationUpdate) async -> Void) async throws -> PreparedNodes {
        let started = Date()
        try Task.checkCancellation()
        var config = try (settings ?? UserSettings()).validated(); config.addressFamily = family; config.tunnelProtocol = kind
        let existing = try accounts.load(kind)
        let previous = try caches.load(kind, family: family)
        if force { try checkpoints?.remove(kind, family: family) }
        let saved = try checkpoints?.load(kind, family: family)
        let pending = !force && existing.map { account in saved?.isValid(account: account, settings: config, now: now()) == true } == true ? saved : nil
        let steps = pending?.progress.steps ?? PreparationProgress.plan(existing: existing, download: config.downloadTestEnabled)
        let progress: @Sendable (PreparationUpdate) async -> Void = { update in
            if case .progress(var value) = update { value.steps = steps; await sink(.progress(value)) }
            else { await sink(update) }
        }
        let validCache = existing.flatMap { account in previous.flatMap { $0.isValid(for: account, now: now(), family: family, settings: config) ? $0 : nil } }
        // A kill after cache.save but before checkpoint deletion must not refresh the cache timestamp.
        if !force, let previous = validCache,
           pending == nil || previous.createdAt >= pending!.startedAt || config.cacheNeverExpires && pending?.userInitiated != true {
            try checkpoints?.remove(kind, family: family)
            await progress(.progress(.init(stage: .ready, fraction: 1, title: "连接已就绪", detail: "已恢复有效缓存，无需重复注册或优选")))
            return PreparedNodes(cache: previous, reusedCache: true)
        }
        if let pending { await progress(.progress(pending.progress)) }
        else { await progress(.progress(.init(stage: .checking, fraction: 0.02, title: "检查注册与缓存", detail: "\(kind.label) · \(family.label) · 缓存\(config.cacheDurationText)"))) }
        let store = accounts
        let account = try await registration.ensureRegistered(kind: kind, existing: existing,
            checkpoint: { account in try store.save(account) }, progress: { update in
                if pending == nil { await progress(.progress(update)) }
            })
        try Task.checkCancellation()
        let results = try await optimizer.optimize(account: account, previous: previous, steps: steps, progress: progress)
        try Task.checkCancellation()
        let requirement: LocalizedText = config.downloadTestEnabled ? "稳定性、YouTube 连通和 \(config.minimumDownloadMbps.formatted()) Mbps 下载" : "稳定性与 YouTube 连通"
        await progress(.progress(.init(stage: .ranking, fraction: 0.96, title: "整理优选结果", detail: "按\(requirement)要求筛选，按延迟排序")))
        guard results.contains(where: { $0.qualifies(settings: config) }) else {
            try checkpoints?.remove(kind, family: family)
            throw WARPError.message("没有节点同时达到\(requirement)要求，未更新缓存。可更换网络、协议或地址族后重试。")
        }
        let cache = try NodeCache(account: account, results: results, now: now(), family: family, settings: config)
        await progress(.progress(.init(stage: .saving, fraction: 0.98, title: "保存节点缓存", detail: "写入 \(cache.results.count) 个可用节点，缓存\(config.cacheDurationText)")))
        try Task.checkCancellation()
        try caches.save(cache)
        await progress(.progress(.init(stage: .finalizing, fraction: 0.99, title: "完成优选", detail: "节点缓存已写入，清理已完成的优选进度")))
        try checkpoints?.remove(kind, family: family)
        Diagnostics.record("preparation completed protocol=\(kind.rawValue) family=\(family.rawValue) nodes=\(cache.results.count) cacheDays=\(config.cacheDays) neverExpires=\(config.cacheNeverExpires) download=\(config.downloadTestEnabled) elapsed=\(Int(Date().timeIntervalSince(started)))s", process: "app")
        await progress(.progress(.init(stage: .ready, fraction: 1, title: "连接已就绪", detail: "优选完成，已保存 \(cache.results.count) 个节点")))
        return PreparedNodes(cache: cache, reusedCache: false)
    }
}
