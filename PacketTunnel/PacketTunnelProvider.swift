import Clash
import Foundation
import NetworkExtension

final class PacketTunnelProvider: NEPacketTunnelProvider {
    private let queue = DispatchQueue(label: "com.leo.TrashVPN.tunnel")
    private var core: ClashBoxService?
    private var platform: CorePlatform?
    private var bridge: PacketFlowBridge?
    private var selected: WARPEndpoint?
    private var started: Date?
    private var preferences = UserSettings()
    private var physicalDNS: [String] = []
    private var appliedMTU: Int?

    override func startTunnel(options: [String: NSObject]?, completionHandler: @escaping (Error?) -> Void) {
        queue.async { [self] in
            do {
                signal(SIGPIPE, SIG_IGN)
                Diagnostics.reset("tunnel")
                guard let config = (protocolConfiguration as? NETunnelProviderProtocol)?.providerConfiguration,
                      let host = config["host"] as? String, let port = config["port"] as? Int,
                      let kind = WARPProtocol(rawValue: config["kind"] as? String ?? "wg"),
                      let family = IPAddressFamily(rawValue: config["family"] as? String ?? "ipv4") else {
                    throw WARPError.message("缺少节点配置。")
                }
                let endpoint = WARPEndpoint(host: host, port: port, kind: kind)
                var preferences = UserSettings(); preferences.addressFamily = family; preferences.tunnelProtocol = kind
                if let data = config["settings"] as? Data { preferences = try JSONDecoder().decode(UserSettings.self, from: data).validated() }
                guard preferences.addressFamily == family, preferences.tunnelProtocol == kind else { throw WARPError.message("隧道设置与节点不匹配。") }
                self.preferences = preferences
                physicalDNS = TunnelNetworkSettings.parseSystemDNS(ClashSystemResolverLines())
                guard endpoint.isValid, endpoint.family == family, let account = try KeychainAccountStore().load(kind), account.isRegistered,
                      let cache = try NodeCacheStore().load(kind, family: family), cache.isValid(for: account, now: Date(), family: family, settings: preferences),
                      cache.results.contains(where: { $0.endpoint == endpoint }) else {
                    throw WARPError.message("注册身份或节点缓存无效，请打开应用自动更新。")
                }
                selected = endpoint
                Diagnostics.record("start build=\(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") ?? "?") endpoint=\(endpoint.id)", process: "tunnel")
                let platform = CorePlatform(isExtension: true)
                self.platform = platform
                platform.failure = { [weak self] message in self?.cancelTunnelWithError(WARPError.message(message)) }
                platform.openTunnel = { [weak self] options in
                    guard let self else { throw CancellationError() }
                    return try self.openTunnel(options)
                }
                try platform.prepare(family: family)
                try CoreRuntime.setup(isExtension: true, family: family, mtu: preferences.effectiveMTU)
                var error: NSError?
                guard let service = ClashNewService(platform, &error) else { throw error ?? WARPError.message("内核创建失败") }
                core = service
                let content = try WARPConfiguration.render(endpoints: [endpoint], selected: endpoint,
                    account: account, tunnel: true, family: family, settings: preferences)
                try service.start(content)
                started = Date()
                Diagnostics.record("tunnel started core=\(ClashVersion())", process: "tunnel")
                completionHandler(nil)
            } catch {
                cleanup()
                Diagnostics.record("start failed: \(error.localizedDescription)", process: "tunnel")
                completionHandler(error)
            }
        }
    }

    private func openTunnel(_ options: any ClashTunOptionsProtocol) throws -> Int32 {
        guard let selected else { throw WARPError.message("缺少隧道端点。") }
        let settings = try TunnelNetworkSettings.make(endpoint: selected, mtu: Int(options.getMTU()),
            dnsAddress: options.getDNSServerAddress().value, preferences: preferences, systemDNS: physicalDNS)
        let semaphore = DispatchSemaphore(value: 0)
        var settingsError: Error?
        setTunnelNetworkSettings(settings) { error in settingsError = error; semaphore.signal() }
        // Do not abandon an in-flight settings callback and leave a stale route installation.
        semaphore.wait()
        if let settingsError { throw settingsError }
        appliedMTU = Int(options.getMTU())
        let made = PacketFlowBridge(packetFlow: packetFlow, maxPendingPackets: 256, maxPendingBytes: 512 * 1024,
            logLine: { Diagnostics.record($0, process: "tunnel") }) { [weak self] error in
                self?.cancelTunnelWithError(error)
            }
        let descriptor = try made.start()
        bridge = made
        Diagnostics.record("public packet bridge ready MTU=\(options.getMTU())", process: "tunnel")
        return descriptor
    }

    override func stopTunnel(with reason: NEProviderStopReason, completionHandler: @escaping () -> Void) {
        queue.async { [self] in
            Diagnostics.record("stop reason=\(reason.rawValue)", process: "tunnel")
            cleanup()
            completionHandler()
        }
    }

    private func cleanup() {
        try? core?.close(); core = nil
        bridge?.stop(); bridge = nil
        platform?.shutdown(); platform = nil
        started = nil
    }

    override func handleAppMessage(_ messageData: Data, completionHandler: ((Data?) -> Void)?) {
        queue.async { [self] in
            let snapshot = bridge?.snapshot()
            let reply: [String: Any] = ["core": ClashVersion(), "endpoint": selected?.id ?? "", "family": selected?.family?.rawValue ?? "",
                "started": started?.timeIntervalSince1970 ?? 0, "mtu": appliedMTU ?? 0,
                "dnsIssued": !preferences.doNotSetDNS, "dnsLeakProtection": preferences.dnsLeakProtection,
                "packetsFromSystem": snapshot?.packetsFromSystem ?? 0,
                "packetsToSystem": snapshot?.packetsToSystem ?? 0,
                "memoryBytes": ClashMemoryFootprint(), "logs": Diagnostics.read("tunnel")]
            completionHandler?(try? JSONSerialization.data(withJSONObject: reply))
        }
    }

    override func sleep(completionHandler: @escaping () -> Void) { completionHandler() }
    override func wake() { Diagnostics.record("device wake", process: "tunnel") }
}
