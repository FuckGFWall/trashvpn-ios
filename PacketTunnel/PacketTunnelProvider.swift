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
    private var tunDNSAddress = ""
    private var tunOpenCount = 0
    private var installedOuterHosts = Set<String>()
    private var runtimeState: ActiveTunnelState?
    private var runningCache: NodeCache?
    private var runningConfiguration = ""
    private let runtimeStore = ActiveTunnelStore()

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
                let cachePolicy = preferences.withCachePolicy(from: try? UserSettings.load())
                guard endpoint.isValid, endpoint.family == family, let account = try KeychainAccountStore().load(kind), account.isRegistered,
                      let cache = try NodeCacheStore().load(kind, family: family), cache.isValid(for: account, now: Date(), family: family, settings: cachePolicy),
                      cache.results.contains(where: { $0.endpoint == endpoint }) else {
                    throw WARPError.message("注册身份或节点缓存无效，请打开应用自动更新。")
                }
                selected = endpoint
                Diagnostics.record("start build=\(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") ?? "?") endpoint=\(endpoint.id)", process: "tunnel")
                let platform = CorePlatform(isExtension: true)
                self.platform = platform
                platform.failure = { [weak self] message in self?.cancelTunnelWithError(WARPError.message(LocalizedText(message))) }
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
                runningConfiguration = content
                var state = ActiveTunnelState(sessionID: (config["sessionID"] as? String).flatMap(UUID.init(uuidString:)) ?? UUID(),
                    startedAt: started!, endpoint: endpoint, settings: preferences, automatic: config["automatic"] as? Bool ?? true)
                state.tunOpenCount = tunOpenCount
                try runtimeStore.save(state)
                runtimeState = state
                runningCache = cache
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
        tunDNSAddress = try options.getDNSServerAddress().value
        tunOpenCount += 1
        installedOuterHosts = [selected.host]
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
        if let runtimeState { try? runtimeStore.remove(sessionID: runtimeState.sessionID) }
        runtimeState = nil; runningCache = nil; runningConfiguration = ""; tunOpenCount = 0; installedOuterHosts = []
        try? core?.close(); core = nil
        bridge?.stop(); bridge = nil
        platform?.shutdown(); platform = nil
        started = nil
    }

    override func handleAppMessage(_ messageData: Data, completionHandler: ((Data?) -> Void)?) {
        queue.async { [self] in
            if messageData != Data("status".utf8) {
                guard messageData.count <= 16 * 1024, let request = try? JSONDecoder().decode(TunnelSwitchRequest.self, from: messageData) else {
                    completionHandler?(try? JSONSerialization.data(withJSONObject: ["error": LocalizedText("无效的切换请求。").localized()])); return
                }
                let reply: TunnelSwitchReply
                do {
                    let state = try switchNode(request)
                    reply = TunnelSwitchReply(requestID: request.id, success: true, state: state, error: nil)
                } catch {
                    let fatal = (error as? TunnelSwitchFailure)?.restored == false
                    reply = TunnelSwitchReply(requestID: request.id, success: false, state: fatal ? nil : runtimeState, error: error.localizedDescription)
                    Diagnostics.record("hot switch failed restored=\(!fatal): \(error.localizedDescription)", process: "tunnel")
                    if fatal { cancelTunnelWithError(error) }
                }
                completionHandler?(try? JSONEncoder().encode(reply)); return
            }
            let snapshot = bridge?.snapshot()
            var reply: [String: Any] = ["core": ClashVersion(), "endpoint": selected?.id ?? "", "family": selected?.family?.rawValue ?? "",
                "started": started?.timeIntervalSince1970 ?? 0, "mtu": appliedMTU ?? 0,
                "dnsIssued": !preferences.doNotSetDNS, "dnsLeakProtection": preferences.dnsLeakProtection,
                "packetsFromSystem": snapshot?.packetsFromSystem ?? 0,
                "packetsToSystem": snapshot?.packetsToSystem ?? 0,
                "memoryBytes": ClashMemoryFootprint(), "logs": Diagnostics.read("tunnel")]
            if let runtimeState, let data = try? JSONEncoder().encode(runtimeState), let object = try? JSONSerialization.jsonObject(with: data) {
                reply["runtime"] = object
            }
            completionHandler?(try? JSONSerialization.data(withJSONObject: reply))
        }
    }

    private func switchNode(_ request: TunnelSwitchRequest) throws -> ActiveTunnelState {
        guard let previous = runtimeState, let core, !runningConfiguration.isEmpty else { throw WARPError.message("隧道尚未就绪。") }
        try request.validate(current: previous)
        if previous.lastRequestID == request.id { return previous }
        let target = request.endpoint
        let nextPreferences = preferences.forProtocol(target.kind).withCachePolicy(from: try? UserSettings.load())
        guard let account = try KeychainAccountStore().load(target.kind),
              let cache = try NodeCacheStore().load(target.kind, family: nextPreferences.addressFamily),
              request.usesMeasurementCache(cache, runningCache: runningCache, account: account, current: previous)
                || cache.isValid(for: account, now: Date(), family: nextPreferences.addressFamily, settings: nextPreferences),
              cache.results.contains(where: { $0.endpoint == target }) else {
            throw WARPError.message("目标协议或节点缓存已失效，请断开 VPN 后重新优选。")
        }
        let next = previous.selecting(target, automatic: request.automatic, requestID: request.id, settings: nextPreferences)
        if target != previous.endpoint {
            let oldContent = runningConfiguration
            let content = try WARPConfiguration.render(endpoints: [target], selected: target, account: account,
                tunnel: true, family: nextPreferences.addressFamily, settings: nextPreferences)
            let transaction = TunnelSwitchTransaction(
                installUnionRoutes: { try self.installRoutes(previous.endpoint, additional: [target]) },
                closeConnections: {
                    ClashCloseAllConnections()
                    // Retire unreferenced WG adapters promptly, including their periodic keepalives.
                    ClashFreeMemory()
                },
                reloadTarget: { try self.reload(core, content: content) },
                installTargetRoutes: { try self.installRoutes(target) },
                saveTarget: { try self.runtimeStore.save(next) },
                reloadPrevious: { try self.reload(core, content: oldContent) },
                installPreviousRoutes: { try self.installRoutes(previous.endpoint) },
                savePrevious: { try self.runtimeStore.save(previous) })
            try transaction.perform()
            runningConfiguration = content
        } else { try runtimeStore.save(next) }
        selected = target; preferences = nextPreferences; runtimeState = next; runningCache = cache
        Diagnostics.record("hot switch session=\(next.sessionID) revision=\(next.revision) endpoint=\(target.id) tunOpens=\(tunOpenCount)", process: "tunnel")
        return next
    }

    private func reload(_ service: ClashBoxService, content: String) throws {
        guard let outcome = service.reloadClassified(content) else {
            throw TunnelReloadFailure(message: "内核未返回重载状态。", mayHaveChangedCore: true)
        }
        guard outcome.errorClass.isEmpty || outcome.errorClass == "committed" else {
            throw TunnelReloadFailure(message: LocalizedText(outcome.message), mayHaveChangedCore: !["config", "memory", "restart"].contains(outcome.errorClass))
        }
    }

    private func installRoutes(_ endpoint: WARPEndpoint, additional: [WARPEndpoint] = []) throws {
        guard let appliedMTU else { throw WARPError.message("隧道网络设置尚未就绪。") }
        let hosts = Set(([endpoint] + additional).map(\.host))
        guard hosts != installedOuterHosts else { return }
        let settings = try TunnelNetworkSettings.make(endpoint: endpoint, mtu: appliedMTU, dnsAddress: tunDNSAddress,
            preferences: preferences, systemDNS: physicalDNS, additionalEndpoints: additional)
        let semaphore = DispatchSemaphore(value: 0)
        var failure: Error?
        installedOuterHosts = [] // A failed OS update must force the rollback to reinstall old routes.
        setTunnelNetworkSettings(settings) { error in failure = error; semaphore.signal() }
        semaphore.wait()
        if let failure { throw failure }
        installedOuterHosts = hosts
    }

    override func sleep(completionHandler: @escaping () -> Void) { completionHandler() }
    override func wake() { Diagnostics.record("device wake", process: "tunnel") }
}
