import Foundation

/// Uses the system VPN after the provider acknowledges the selected cached endpoint.
/// Every node gets a fresh session so pooled connections cannot belong to an earlier node.
enum LiveNodeProbe {
    static func measure(_ kind: NodeMeasurementKind, settings: UserSettings) async throws -> Double {
        let options = URLSessionConfiguration.ephemeral
        options.connectionProxyDictionary = [:]
        options.urlCredentialStorage = nil
        options.timeoutIntervalForResource = 40
        let session = URLSession(configuration: options)
        defer { session.invalidateAndCancel() }
        let traceURL = settings.doNotSetDNS ? "https://1.1.1.1/cdn-cgi/trace" : "https://www.cloudflare.com/cdn-cgi/trace"
        let (trace, response) = try await session.data(for: request(traceURL, timeout: max(8, settings.probeTimeout)))
        guard (response as? HTTPURLResponse)?.statusCode == 200, confirmsWARP(trace) else {
            throw WARPError.message("所选节点未通过 WARP 连通验证。")
        }
        try Task.checkCancellation()
        if kind == .latency {
            let start = ContinuousClock.now
            let (_, response) = try await session.data(for: request(WARPConfiguration.testURL, timeout: settings.probeTimeout))
            guard (response as? HTTPURLResponse)?.statusCode == 204 else { throw WARPError.message("节点连通测试失败。") }
            return max(1, seconds(start.duration(to: .now)) * 1000)
        }
        let (warmup, warmupResponse) = try await session.data(for: request("https://speed.cloudflare.com/__down?bytes=\(settings.downloadWarmupBytes)", timeout: max(10, settings.probeTimeout)))
        guard (warmupResponse as? HTTPURLResponse)?.statusCode == 200, warmup.count == settings.downloadWarmupBytes else {
            throw WARPError.message("下载预热失败。")
        }
        try Task.checkCancellation()
        let start = ContinuousClock.now
        let (data, response2) = try await session.data(for: request("https://speed.cloudflare.com/__down?bytes=\(settings.measuredDownloadBytes)", timeout: max(15, settings.probeTimeout)))
        guard (response2 as? HTTPURLResponse)?.statusCode == 200, data.count == settings.measuredDownloadBytes else { throw WARPError.message("下载测速未完成。") }
        return Double(data.count) * 8 / max(0.001, seconds(start.duration(to: .now))) / 1_000_000
    }
    static func confirmsWARP(_ data: Data) -> Bool {
        String(decoding: data, as: UTF8.self).split(separator: "\n").contains { $0 == "warp=on" || $0 == "warp=plus" }
    }
    private static func seconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
    }
    private static func request(_ url: String, timeout: Int) -> URLRequest {
        var value = URLRequest(url: URL(string: url + (url.contains("?") ? "&" : "?") + "trashvpn=" + UUID().uuidString)!)
        value.timeoutInterval = TimeInterval(timeout)
        value.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        value.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        return value
    }
}
