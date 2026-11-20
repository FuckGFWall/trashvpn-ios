import Clash
import Foundation

actor EndpointProbe {
    func run(journal: OptimizationJournal, account: WARPAccount, settings: UserSettings,
        progress: @escaping @Sendable (PreparationUpdate) async -> Void) async throws -> [ProbeResult] {
        let state = await journal.snapshot()
        if state.screening.isEmpty && state.supplementalScreening != true { Diagnostics.reset("probe") }
        let platform = CorePlatform(isExtension: false)
        try platform.prepare(family: settings.addressFamily)
        defer { platform.shutdown() }
        try CoreRuntime.setup(isExtension: false, family: settings.addressFamily, mtu: settings.effectiveMTU)
        Diagnostics.record("probe started tun=false proxy listeners=none control=loopback-only timeout=\(settings.probeTimeout)s mtu=\(settings.effectiveMTU)", process: "probe")
        return try await Self.screen(journal: journal, settings: settings, progress: progress) { endpoint, target in
            try await self.sample(endpoint, account: account, configuration: settings, platform: platform, target: target)
        }
    }

    static func screen(journal: OptimizationJournal, settings: UserSettings,
        progress: @escaping @Sendable (PreparationUpdate) async -> Void,
        measure: (WARPEndpoint, String) async throws -> Int32) async throws -> [ProbeResult] {
        var state = await journal.snapshot()
        while true {
            let supplemental = state.supplementalScreening == true
            let target = supplemental ? WARPConfiguration.literalTraceURL : WARPConfiguration.testURL
            let title: LocalizedText = supplemental ? "补充连通检查" : "连通筛选"
            let detail: LocalizedText = !supplemental ? "首次探测"
                : state.kind == .masque ? "通过备用网址复测" : "通过备用网址探测候选端口"
            let total = state.candidates.count
            var reachable: [ProbeResult] = []
            for index in 0..<total {
                try Task.checkCancellation()
                let endpoint = state.candidates[index]
                let result: ProbeResult
                if let saved = state.screening[endpoint.id] {
                    result = saved
                } else {
                    let position = Double(index) / Double(total)
                    let fraction = supplemental ? 0.50 + 0.07 * position : 0.38 + 0.12 * position
                    await progress(.progress(.init(stage: .screening, fraction: fraction, title: title,
                        detail: "\(endpoint.address) · \(detail) · 超时 \(settings.probeTimeout) 秒",
                        substep: index + 1, substepTotal: total, substepLabel: "候选节点")))
                    let delay = try await measure(endpoint, target)
                    try Task.checkCancellation()
                    result = ProbeResult(endpoint: endpoint, samples: [delay], testedAt: Date())
                    state = try await journal.screen(result, at: index, followupLimit: settings.strength.qualityCandidates)
                    await progress(.sample(result))
                }
                if result.median != nil {
                    reachable.append(result)
                    if reachable.count >= settings.strength.qualityCandidates { break }
                }
            }
            try Task.checkCancellation()
            if !reachable.isEmpty || supplemental { return reachable }
            state = try await journal.beginSupplement()
        }
    }

    private func sample(_ endpoint: WARPEndpoint, account: WARPAccount, configuration: UserSettings,
        platform: CorePlatform, target: String) async throws -> Int32 {
        let controller = try ProbeController.allocate()
        let content = try WARPConfiguration.render(endpoints: [endpoint], selected: endpoint,
            account: account, tunnel: false, family: configuration.addressFamily, settings: configuration, controller: controller)
        var error: NSError?
        guard let service = ClashNewService(platform, &error) else { throw error ?? WARPError.message("测速内核创建失败") }
        defer { try? service.close() }
        try service.start(content)
        let options = URLSessionConfiguration.ephemeral
        options.connectionProxyDictionary = [:]
        options.timeoutIntervalForRequest = TimeInterval(configuration.probeTimeout + 2)
        options.timeoutIntervalForResource = TimeInterval(configuration.probeTimeout + 3)
        let session = URLSession(configuration: options)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: controller.url(endpoint: endpoint, timeout: configuration.probeTimeout, target: target))
        request.setValue("Bearer \(controller.secret)", forHTTPHeaderField: "Authorization")
        do {
            let (data, response) = try await session.data(for: request)
            try Task.checkCancellation()
            guard let http = response as? HTTPURLResponse, [200, 503, 504].contains(http.statusCode) else {
                throw WARPError.message("测速控制接口响应异常。")
            }
            let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            let delay = http.statusCode == 200 ? (object?["delay"] as? NSNumber)?.int32Value ?? -1 : -1
            let outcome = delay > 0 ? "ok" : Self.failureReason(status: http.statusCode, response: object)
            Diagnostics.record("\(endpoint.id) sample=\(delay)ms target=\(target) result=\(outcome) timeout=\(configuration.probeTimeout)s", process: "probe")
            return delay > 0 ? delay : -1
        } catch {
            if Task.isCancelled { throw CancellationError() }
            if (error as? URLError)?.code == .timedOut {
                Diagnostics.record("\(endpoint.id) sample=-1ms target=\(target) result=controller-timeout", process: "probe")
                return -1
            }
            throw error
        }
    }

    static func failureReason(status: Int, response: [String: Any]?) -> String {
        // The SDK can return only a deadline. Preserve that uncertainty, and avoid logging raw errors.
        let failure = response?["failure"] as? [String: Any]
        let message = ((failure?["message"] ?? response?["message"]) as? String ?? "").lowercased()
        if let http = response?["httpStatus"] as? Int, http > 0 { return "http-\(http)" }
        if message.contains("tls handshake") || message.contains("x509") { return "tls" }
        if message.contains("no such host") || message.contains("dns") || message.contains("lookup ") { return "dns" }
        if message.contains("handshake") { return "handshake" }
        if status == 504 || failure?["kind"] as? String == "timeout" { return "timeout" }
        return "probe-failed"
    }
}
