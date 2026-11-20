import Clash
import Foundation

/// Requests use the app's authenticated loopback proxy; no system proxy or TUN is installed.
actor NodeQualityProbe {
    func run(endpoints: [WARPEndpoint], account: WARPAccount, settings: UserSettings,
        completed: [ProbeResult] = [], partial: ProbeResult? = nil, useLiteralTrace: Bool = false,
        checkpoint: (@Sendable (ProbeResult) async throws -> Void)? = nil,
        didComplete: (@Sendable (ProbeResult) async throws -> Void)? = nil,
        progress: @escaping @Sendable (PreparationUpdate) async -> Void) async throws -> [ProbeResult] {
        func enough(_ values: [ProbeResult]) -> Bool { values.filter { $0.qualifies(settings: settings) }.count >= settings.strength.desiredResults }
        if completed.count == endpoints.count || enough(completed) { return completed }
        let platform = CorePlatform(isExtension: false)
        try platform.prepare(family: settings.addressFamily)
        defer { platform.shutdown() }
        try CoreRuntime.setup(isExtension: false, family: settings.addressFamily, mtu: settings.effectiveMTU)
        var results = completed
        for (index, endpoint) in endpoints.enumerated() where index >= completed.count {
            try Task.checkCancellation()
            let result = try await measure(endpoint, account: account, settings: settings, platform: platform,
                index: index, total: endpoints.count, partial: partial?.endpoint == endpoint ? partial : nil,
                useLiteralTrace: useLiteralTrace, checkpoint: checkpoint, progress: progress)
            try await didComplete?(result)
            results.append(result)
            await progress(.sample(result))
            if enough(results) { break }
        }
        return results
    }

    private func measure(_ endpoint: WARPEndpoint, account: WARPAccount, settings: UserSettings, platform: CorePlatform,
        index: Int, total: Int, partial: ProbeResult?, useLiteralTrace: Bool, checkpoint: (@Sendable (ProbeResult) async throws -> Void)?,
        progress: @escaping @Sendable (PreparationUpdate) async -> Void) async throws -> ProbeResult {
        let strength = settings.strength, profile = settings.qualityProfile
        // Covers a process kill between committing the last measurement and completing the node.
        if let partial, partial.measurementFinished { return partial }
        let proxy = try ProbeProxy.allocate()
        var error: NSError?
        guard let service = ClashNewService(platform, &error) else { throw error ?? WARPError.message("质量测试内核创建失败") }
        defer { try? service.close() }
        try service.start(WARPConfiguration.render(endpoints: [endpoint], selected: endpoint, account: account,
            tunnel: false, family: settings.addressFamily, settings: settings, probeProxy: proxy))
        let authentication = ProbeProxyAuthentication(proxy: proxy)
        let options = URLSessionConfiguration.ephemeral
        options.connectionProxyDictionary = ["HTTPEnable": 1, "HTTPProxy": "127.0.0.1", "HTTPPort": Int(proxy.port),
            "HTTPSEnable": 1, "HTTPSProxy": "127.0.0.1", "HTTPSPort": Int(proxy.port), "ExceptionsList": []]
        options.timeoutIntervalForRequest = TimeInterval(max(5, settings.probeTimeout))
        options.timeoutIntervalForResource = 30
        options.httpMaximumConnectionsPerHost = 1
        options.urlCredentialStorage = nil
        let session = URLSession(configuration: options, delegate: authentication, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        var samples = partial?.samples ?? []
        var speeds = partial?.downloadMbps ?? []
        var google = partial?.googleSuccesses ?? 0
        func emit(_ stage: PreparationProgress.Stage, _ local: Double, _ title: LocalizedText, _ detail: LocalizedText) async {
            await progress(.progress(.init(stage: stage, fraction: 0.60 + (Double(index) + local) / Double(total) * 0.34,
                title: title, detail: "\(endpoint.address)\n\(detail)", substep: index + 1, substepTotal: total, substepLabel: "测速节点")))
        }
        func result() -> ProbeResult {
            ProbeResult(endpoint: endpoint, samples: samples, testedAt: Date(), downloadMbps: speeds,
                googleSuccesses: google, qualityVersion: 3, qualityProfile: profile)
        }
        do {
            await emit(.retesting, 0, partial == nil ? "校验测速链路" : "恢复测速链路",
                "确认实际经过 WARP，保留已完成的连通与下载结果")
            let traceURL = useLiteralTrace ? WARPConfiguration.literalTraceURL : "https://speed.cloudflare.com/cdn-cgi/trace"
            let cloudflareURL = useLiteralTrace ? traceURL : WARPConfiguration.testURL
            let (trace, response) = try await session.data(for: request(traceURL, timeout: max(8, settings.probeTimeout)))
            guard (response as? HTTPURLResponse)?.statusCode == 200, authentication.wasUsed,
                  LiveNodeProbe.confirmsWARP(trace) else {
                throw WARPError.message("未确认测速请求通过所选 WARP 节点")
            }
            // Warm each origin once so a cold TLS handshake does not look like latency jitter.
            if !result().passesStability(profile) {
                for url in [cloudflareURL, "https://www.youtube.com/generate_204"] where url != traceURL {
                    _ = try await session.data(for: request(url, timeout: max(8, settings.probeTimeout)))
                }
            }
            while result().needsMoreLatency(profile) {
                try Task.checkCancellation()
                let round = samples.count
                await emit(.retesting, Double(round) / Double(strength.maximumRounds) * 0.5,
                    "稳定性检查", "\(round < strength.minimumRounds ? "检查" : "补测")第 \(round + 1) 次（最多 \(strength.maximumRounds) 次） · \(round % 2 == 0 ? "Cloudflare" : "YouTube")，达标即结束")
                let url = round % 2 == 0 ? cloudflareURL : "https://www.youtube.com/generate_204"
                let start = Date()
                do {
                    let (data, response) = try await session.data(for: request(url, timeout: settings.probeTimeout))
                    let status = (response as? HTTPURLResponse)?.statusCode
                    let good = url == traceURL ? status == 200 && LiveNodeProbe.confirmsWARP(data) : status == 204
                    samples.append(good ? max(1, Int32(Date().timeIntervalSince(start) * 1000)) : -1)
                    if good && round % 2 == 1 { google += 1 }
                } catch {
                    if Task.isCancelled { throw CancellationError() }
                    samples.append(-1)
                }
                try await checkpoint?(result())
            }
            guard result().passesStability(profile) else { return result() }
            if settings.downloadTestEnabled && speeds.isEmpty {
                await emit(.downloading, 0.5, "下载预热", "预热 \(settings.downloadWarmupBytes / 1024) KiB，随后只测一次下载")
                let (warmup, warmupResponse) = try await session.data(for: request("https://speed.cloudflare.com/__down?bytes=\(settings.downloadWarmupBytes)", timeout: max(10, settings.probeTimeout)))
                guard (warmupResponse as? HTTPURLResponse)?.statusCode == 200, warmup.count == settings.downloadWarmupBytes else { return result() }
                try Task.checkCancellation()
                await emit(.downloading, 0.65, "下载测速", "下载 \(settings.measuredDownloadBytes / 1024) KiB · 最低要求 \(settings.minimumDownloadMbps.formatted()) Mbps")
                let start = Date()
                let transferTimeout = min(30, max(settings.probeTimeout, Int(ceil(Double(settings.measuredDownloadBytes) * 8 / (profile.minimumMbps * 1_000_000))) + 4))
                let (data, response) = try await session.data(for: request("https://speed.cloudflare.com/__down?bytes=\(settings.measuredDownloadBytes)", timeout: transferTimeout))
                guard (response as? HTTPURLResponse)?.statusCode == 200, data.count == settings.measuredDownloadBytes else { return result() }
                let mbps = Double(data.count) * 8 / max(0.001, Date().timeIntervalSince(start)) / 1_000_000
                speeds.append(mbps)
                try await checkpoint?(result())
                Diagnostics.record("quality \(endpoint.id) download=\(String(format: "%.2f", mbps))Mbps bytes=\(data.count) rounds=1", process: "probe")
            }
        } catch {
            if Task.isCancelled { throw CancellationError() }
            if error is OptimizationCheckpointWriteError { throw error }
            Diagnostics.record("quality rejected \(endpoint.id): \(error.localizedDescription)", process: "probe")
        }
        let measured = result()
        await emit(settings.downloadTestEnabled ? .downloading : .retesting, 1,
            measured.qualifies(profile) ? "节点通过筛选" : "节点未达到要求", measured.localizedLabel)
        return measured
    }

    private func request(_ url: String, timeout: Int) -> URLRequest {
        var value = URLRequest(url: URL(string: url + (url.contains("?") ? "&" : "?") + "trashvpn=" + UUID().uuidString)!)
        value.timeoutInterval = TimeInterval(timeout)
        value.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        value.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        value.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        return value
    }
}

final class ProbeProxyAuthentication: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    let proxy: ProbeProxy
    private let lock = NSLock()
    private var used = false
    var wasUsed: Bool { lock.lock(); defer { lock.unlock() }; return used }
    init(proxy: ProbeProxy) { self.proxy = proxy }
    func disposition(for space: URLProtectionSpace, requestHost: String?, previousFailures: Int) -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        guard space.isProxy() else { return (.performDefaultHandling, nil) }
        // Older CFNetwork versions report the CONNECT destination as the host
        // while still reporting the explicitly configured loopback proxy port.
        guard space.port == Int(proxy.port), space.authenticationMethod == NSURLAuthenticationMethodHTTPBasic,
              space.host == "127.0.0.1" || space.host == requestHost, previousFailures == 0 else {
            return (.cancelAuthenticationChallenge, nil)
        }
        lock.lock(); used = true; lock.unlock()
        return (.useCredential, URLCredential(user: proxy.username, password: proxy.password, persistence: .forSession))
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        let (disposition, credential) = disposition(for: challenge.protectionSpace,
            requestHost: task.currentRequest?.url?.host ?? task.originalRequest?.url?.host,
            previousFailures: challenge.previousFailureCount)
        completionHandler(disposition, credential)
    }
}
