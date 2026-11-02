import Clash
import Foundation

/// All requests belong to this app's authenticated loopback proxy; no system proxy or TUN is installed.
actor NodeQualityProbe {
    func run(endpoints: [WARPEndpoint], account: WARPAccount, settings: UserSettings,
        progress: @escaping @Sendable (PreparationUpdate) async -> Void) async throws -> [ProbeResult] {
        let platform = CorePlatform(isExtension: false)
        try platform.prepare(family: settings.addressFamily)
        defer { platform.shutdown() }
        try CoreRuntime.setup(isExtension: false, family: settings.addressFamily, mtu: settings.effectiveMTU)
        var results: [ProbeResult] = []
        for (index, endpoint) in endpoints.enumerated() {
            try Task.checkCancellation()
            let result = try await measure(endpoint, account: account, settings: settings, platform: platform,
                index: index, total: endpoints.count, progress: progress)
            results.append(result)
            await progress(.sample(result))
        }
        return results
    }

    private func measure(_ endpoint: WARPEndpoint, account: WARPAccount, settings: UserSettings, platform: CorePlatform,
        index: Int, total: Int, progress: @escaping @Sendable (PreparationUpdate) async -> Void) async throws -> ProbeResult {
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
        var samples: [Int32] = []
        var speeds: [Double] = []
        var google = 0
        let strength = settings.strength
        func emit(_ stage: PreparationProgress.Stage, _ local: Double, _ title: String, _ detail: String) async {
            await progress(.progress(.init(stage: stage, fraction: 0.72 + (Double(index) + local) / Double(total) * 0.22,
                title: title, detail: "节点 \(index + 1)/\(total) · \(endpoint.address)\n\(detail)")))
        }
        func result() -> ProbeResult {
            ProbeResult(endpoint: endpoint, samples: samples, testedAt: Date(), downloadMbps: speeds, googleSuccesses: google, qualityVersion: 2)
        }
        do {
            await emit(.retesting, 0, "校验测速链路", "确认实际经过 WARP，预热连接")
            let (trace, response) = try await session.data(for: request("https://speed.cloudflare.com/cdn-cgi/trace", timeout: max(8, settings.probeTimeout)))
            let text = String(decoding: trace, as: UTF8.self)
            guard (response as? HTTPURLResponse)?.statusCode == 200, authentication.wasUsed,
                  text.split(separator: "\n").contains(where: { $0 == "warp=on" || $0 == "warp=plus" }) else {
                throw WARPError.message("未确认测速请求通过所选 WARP 节点")
            }
            // Warm both origins before recording latency. Keep the adapter and proxy sessions alive.
            for url in [WARPConfiguration.testURL, "https://www.youtube.com/generate_204"] {
                _ = try await session.data(for: request(url, timeout: max(8, settings.probeTimeout)))
            }
            for round in 0..<strength.rounds {
                try Task.checkCancellation()
                await emit(.retesting, Double(round) / Double(strength.rounds) * 0.5,
                    "稳定性复测 \(round + 1)/\(strength.rounds)", round % 2 == 0 ? "检查 Cloudflare 连通与延迟" : "检查 YouTube 连通与延迟")
                let url = round % 2 == 0 ? WARPConfiguration.testURL : "https://www.youtube.com/generate_204"
                let start = Date()
                do {
                    let (_, response) = try await session.data(for: request(url, timeout: settings.probeTimeout))
                    let good = (response as? HTTPURLResponse)?.statusCode == 204
                    samples.append(good ? max(1, Int32(Date().timeIntervalSince(start) * 1000)) : -1)
                    if good && round % 2 == 1 { google += 1 }
                } catch {
                    if Task.isCancelled { throw CancellationError() }
                    samples.append(-1)
                }
            }
            guard result().passesStability(strength) else { return result() }
            await emit(.downloading, 0.5, "预热下载连接", "排除 TCP 慢启动影响，再测持续下载速度")
            let (warmup, warmupResponse) = try await session.data(for: request("https://speed.cloudflare.com/__down?bytes=\(strength.warmupBytes)", timeout: max(10, settings.probeTimeout)))
            guard (warmupResponse as? HTTPURLResponse)?.statusCode == 200, warmup.count == strength.warmupBytes else { return result() }
            for round in 0..<strength.downloadRounds {
                try Task.checkCancellation()
                await emit(.downloading, 0.5 + Double(round) / Double(strength.downloadRounds) * 0.5,
                    "下载测速 \(round + 1)/\(strength.downloadRounds)", "连续下载 \(strength.downloadBytes / 1024) KiB，检查实际速度与稳定性")
                let start = Date()
                let transferTimeout = max(settings.probeTimeout, Int(ceil(Double(strength.downloadBytes) * 8 / (ProbeResult.minimumMbps * 1_000_000))) + 8)
                let (data, response) = try await session.data(for: request("https://speed.cloudflare.com/__down?bytes=\(strength.downloadBytes)", timeout: transferTimeout))
                guard (response as? HTTPURLResponse)?.statusCode == 200, data.count == strength.downloadBytes else { return result() }
                let mbps = Double(data.count) * 8 / max(0.001, Date().timeIntervalSince(start)) / 1_000_000
                speeds.append(mbps)
                Diagnostics.record("quality \(endpoint.id) download=\(String(format: "%.2f", mbps))Mbps bytes=\(data.count)", process: "probe")
                if mbps < ProbeResult.minimumMbps { return result() }
            }
        } catch {
            if Task.isCancelled { throw CancellationError() }
            Diagnostics.record("quality rejected \(endpoint.id): \(error.localizedDescription)", process: "probe")
        }
        let measured = result()
        await emit(.downloading, 1, measured.qualifies(strength) ? "节点通过质量筛选" : "节点未达到质量要求", measured.label)
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

private final class ProbeProxyAuthentication: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    let proxy: ProbeProxy
    private let lock = NSLock()
    private var used = false
    var wasUsed: Bool { lock.lock(); defer { lock.unlock() }; return used }
    init(proxy: ProbeProxy) { self.proxy = proxy }
    func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        guard challenge.protectionSpace.isProxy(), challenge.protectionSpace.host == "127.0.0.1",
              challenge.protectionSpace.port == Int(proxy.port), challenge.previousFailureCount == 0 else {
            completionHandler(.performDefaultHandling, nil); return
        }
        lock.lock(); used = true; lock.unlock()
        completionHandler(.useCredential, URLCredential(user: proxy.username, password: proxy.password, persistence: .forSession))
    }
}
