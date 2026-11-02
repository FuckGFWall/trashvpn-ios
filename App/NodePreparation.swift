import Foundation

enum PreparationUpdate: Sendable {
    case status(String)
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
}

struct EndpointCatalog {
    static let wireguardNetworks = ["8.6.112", "8.34.70", "8.34.146", "8.35.211", "8.39.125", "8.39.204",
        "8.39.214", "8.47.69", "162.159.192", "162.159.195", "188.114.96", "188.114.97", "188.114.98", "188.114.99"]
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
}

actor MihomoOptimizer: NodeOptimizing {
    private let probe = EndpointProbe()
    private let quality = NodeQualityProbe()
    let configuration: UserSettings
    init(family: IPAddressFamily = .ipv4, settings: UserSettings? = nil) {
        var value = settings ?? UserSettings(); value.addressFamily = family; configuration = value
    }
    func optimize(account: WARPAccount, previous: NodeCache?,
        progress: @escaping @Sendable (PreparationUpdate) async -> Void) async throws -> [ProbeResult] {
        let config = configuration
        let candidates = EndpointCatalog.candidates(account: account, previous: previous,
            family: config.addressFamily, limit: config.strength.candidates)
        await progress(.progress(.init(stage: .candidates, fraction: 0.53, title: "生成候选端点",
            detail: "已汇总 \(candidates.count) 个 \(config.addressFamily.label) 端点，准备逐个检查")))
        let screened = try await probe.run(endpoints: candidates, account: account, samples: account.kind == .masque ? 3 : 2,
            stopAfterSuccesses: config.strength.finalists, family: config.addressFamily, settings: config, willTest: { step in
                await progress(.progress(.init(stage: .screening, fraction: 0.55 + Double(step.index - 1) / Double(step.total) * 0.13,
                    title: "初筛端点 \(step.index)/\(step.total) · 尝试 \(step.round)/\(step.rounds)", detail: "\(step.endpoint.address) · 超时 \(config.probeTimeout) 秒")))
            }) { result in
                await progress(.sample(result))
                let index = (candidates.firstIndex(of: result.endpoint) ?? 0) + 1
                await progress(.progress(.init(stage: .screening, fraction: 0.55 + Double(index) / Double(candidates.count) * 0.13,
                    title: "已检查 \(index) 个端点", detail: "\(result.endpoint.address) · \(result.label)")))
            }
        try Task.checkCancellation()
        let finalists = Array(screened.filter { $0.median != nil }.sorted(by: ProbeResult.isBetter).prefix(config.strength.finalists)).map(\.endpoint)
        guard !finalists.isEmpty else { throw WARPError.message("当前网络未找到可用的 \(account.kind.label) · \(config.addressFamily.label) 端点，可切换网络或地址族后重试。注册身份已保留。") }
        await progress(.progress(.init(stage: .shortlist, fraction: 0.70, title: "完成初筛，整理候选",
            detail: "入围 \(finalists.count) 个节点，逐个检查稳定性、YouTube 连通和下载速度")))
        return try await quality.run(endpoints: finalists, account: account, settings: config, progress: progress)
    }
}

struct NodePreparation: Sendable {
    let accounts: any AccountStoring
    let caches: any NodeCacheStoring
    let registration: any WARPRegistering
    let optimizer: any NodeOptimizing
    var family: IPAddressFamily = .ipv4
    var settings: UserSettings? = nil
    var now: @Sendable () -> Date = { Date() }

    func prepare(kind: WARPProtocol, force: Bool = false,
        progress: @escaping @Sendable (PreparationUpdate) async -> Void) async throws -> PreparedNodes {
        try Task.checkCancellation()
        var config = try (settings ?? UserSettings()).validated(); config.addressFamily = family
        await progress(.progress(.init(stage: .checking, fraction: 0.02, title: "检查注册与缓存", detail: "\(kind.label) · \(family.label) · \(config.cacheHours) 小时有效期")))
        let existing = try accounts.load(kind)
        let previous = try caches.load(kind, family: family)
        if !force, let existing, let previous, previous.isValid(for: existing, now: now(), family: family, settings: config) {
            await progress(.progress(.init(stage: .ready, fraction: 1, title: "连接已就绪", detail: "已恢复有效缓存，无需重复注册或优选")))
            return PreparedNodes(cache: previous, reusedCache: true)
        }
        let store = accounts
        let account = try await registration.ensureRegistered(kind: kind, existing: existing,
            checkpoint: { account in try store.save(account) }, progress: { update in await progress(.progress(update)) })
        try Task.checkCancellation()
        let results = try await optimizer.optimize(account: account, previous: previous, progress: progress)
        try Task.checkCancellation()
        await progress(.progress(.init(stage: .ranking, fraction: 0.96, title: "整理优选结果", detail: "剔除不稳定或下载不足 3 Mbps 的节点，按延迟排序")))
        guard results.contains(where: { $0.qualifies(config.strength) }) else {
            throw WARPError.message("没有节点同时达到稳定性、YouTube 连通和 3 Mbps 下载要求，未更新缓存。可更换网络、协议或地址族后重试。")
        }
        let cache = try NodeCache(account: account, results: results, now: now(), family: family, settings: config)
        await progress(.progress(.init(stage: .saving, fraction: 0.98, title: "保存节点缓存", detail: "写入 \(cache.results.count) 个可用节点，有效期 \(config.cacheHours) 小时")))
        try Task.checkCancellation()
        try caches.save(cache)
        Diagnostics.record("preparation completed protocol=\(kind.rawValue) family=\(family.rawValue) nodes=\(cache.results.count) cacheHours=\(config.cacheHours)", process: "app")
        await progress(.progress(.init(stage: .ready, fraction: 1, title: "连接已就绪", detail: "优选完成，已保存 \(cache.results.count) 个节点")))
        return PreparedNodes(cache: cache, reusedCache: false)
    }
}
