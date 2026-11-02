import Clash
import Foundation

struct ProbeStep: Sendable {
    let endpoint: WARPEndpoint
    let index: Int
    let total: Int
    let round: Int
    let rounds: Int
}

actor EndpointProbe {
    func run(endpoints: [WARPEndpoint], account: WARPAccount, samples sampleCount: Int = 3, stopAfterSuccesses: Int? = nil,
        family: IPAddressFamily = .ipv4, settings: UserSettings? = nil,
        willTest: (@Sendable (ProbeStep) async -> Void)? = nil,
        update: @escaping @Sendable (ProbeResult) async -> Void) async throws -> [ProbeResult] {
        var configuration = try (settings ?? UserSettings()).validated(); configuration.addressFamily = family
        Diagnostics.reset("probe")
        let platform = CorePlatform(isExtension: false)
        try platform.prepare(family: family)
        defer { platform.shutdown() }
        try CoreRuntime.setup(isExtension: false, family: family, mtu: configuration.effectiveMTU)
        Diagnostics.record("probe started tun=false proxy listeners=none control=loopback-only timeout=\(configuration.probeTimeout)s mtu=\(configuration.effectiveMTU)", process: "probe")
        var results: [ProbeResult] = []
        for (index, endpoint) in endpoints.enumerated() {
            var samples: [Int32] = []
            for round in 1...sampleCount {
                try Task.checkCancellation()
                await willTest?(ProbeStep(endpoint: endpoint, index: index + 1, total: endpoints.count, round: round, rounds: sampleCount))
                // Each sample owns its adapter; a cancelled MASQUE URL-test must not poison the next sample.
                let delay = try await sample(endpoint, account: account, configuration: configuration, platform: platform)
                samples.append(delay)
                await update(ProbeResult(endpoint: endpoint, samples: samples, testedAt: Date()))
            }
            results.append(ProbeResult(endpoint: endpoint, samples: samples, testedAt: Date()))
            if let stopAfterSuccesses, results.filter({ $0.median != nil }).count >= stopAfterSuccesses { break }
        }
        return results
    }

    private func sample(_ endpoint: WARPEndpoint, account: WARPAccount, configuration: UserSettings,
        platform: CorePlatform) async throws -> Int32 {
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
        var request = URLRequest(url: controller.url(endpoint: endpoint, timeout: configuration.probeTimeout))
        request.setValue("Bearer \(controller.secret)", forHTTPHeaderField: "Authorization")
        do {
            let (data, response) = try await session.data(for: request)
            try Task.checkCancellation()
            guard let http = response as? HTTPURLResponse, [200, 503, 504].contains(http.statusCode) else {
                throw WARPError.message("测速控制接口响应异常。")
            }
            let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            let delay = http.statusCode == 200 ? (object?["delay"] as? NSNumber)?.int32Value ?? -1 : -1
            Diagnostics.record("\(endpoint.id) sample=\(delay)ms timeout=\(configuration.probeTimeout)s", process: "probe")
            return delay > 0 ? delay : -1
        } catch {
            if Task.isCancelled { throw CancellationError() }
            if (error as? URLError)?.code == .timedOut { return -1 }
            throw error
        }
    }
}
