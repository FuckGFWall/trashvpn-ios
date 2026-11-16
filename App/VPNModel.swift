import Clash
import Foundation
import NetworkExtension
import SwiftUI
import UIKit

@MainActor
final class VPNModel: ObservableObject {
    @Published var status: NEVPNStatus = .invalid
    @Published private(set) var selected = WARPEndpoint.fixtures[0]
    @Published private(set) var settings = UserSettings()
    @Published private(set) var progress = PreparationProgress.initial
    @Published private(set) var automaticSelection = true
    @Published private(set) var switching = false
    @Published private(set) var measurementKind: NodeMeasurementKind?
    @Published private(set) var testingNodeID: String?
    @Published private(set) var measurements: [String: NodeMeasurement] = [:]
    @Published private(set) var connectionLocation: ConnectionLocation?
    @Published private(set) var preparingApp = false
    @Published private(set) var authorizingVPN = false
    private let networkAccessPrimer = NetworkAccessPrimer()
    @Published private(set) var locatingConnection = false
    private var locationTask: Task<Void, Never>?
    private var locationKey: String?
    private var measurementTask: Task<Void, Never>?
    private var measurementOrigin: CachedNodeChoice?
    var measuring: Bool { measurementKind != nil }
    var displaySelected: WARPEndpoint { measurementOrigin?.endpoint ?? selected }
    var displayAutomatic: Bool { measurementOrigin?.automatic ?? automaticSelection }
    var selectionUnavailable: Bool { switching || scanning || measuring || active && !connected }
    private var runningSettings: UserSettings?
    private var runtimeState: ActiveTunnelState?
    private var switchingTask: Task<Void, Never>?
    private var verificationID = UUID()
    var effectiveSettings: UserSettings { active ? runningSettings ?? settings : settings }
    private var cacheValidationSettings: UserSettings { effectiveSettings.withCachePolicy(from: settings) }
    var addressFamily: IPAddressFamily { effectiveSettings.addressFamily }
    var selectionKey: String { "\(selected.kind.rawValue):\(addressFamily.rawValue)" }
    private var choiceKey: String { "node-choice.\(selectionKey)" }
    @Published var results: [String: ProbeResult] = [:]
    @Published var endpoints: [WARPEndpoint] = []
    @Published var scanning = false
    @Published private(set) var resumablePreparation = false
    @Published var verifying = false
    @Published var message: LocalizedText = "正在检查注册与节点缓存"
    @Published var trace = ""
    @Published var diagnostics = ""
    @Published var errorMessage: String?
    @Published var cache: NodeCache?
    private var manager: NETunnelProviderManager?
    private let accounts = KeychainAccountStore()
    private let caches = NodeCacheStore()
    private let checkpoints = OptimizationCheckpointStore()
    private var preparationTask: Task<Void, Never>?
    private var generation = UUID()
    private var taskKind: WARPProtocol?
    private var taskFamily: IPAddressFamily?
    private var observer: NSObjectProtocol?
    private var polling: Task<Void, Never>?
    private var backgroundTask = UIBackgroundTaskIdentifier.invalid
    #if DEBUG
    private var testBackgroundDeadline: Task<Void, Never>?
    #endif
    private var initialized = false
    private var foreground = true
    private var taskFingerprint: String?
    private var taskCacheHours: Int?

    var active: Bool { [.connected, .connecting, .reasserting, .disconnecting].contains(status) }
    var connected: Bool { status == .connected }
    var cacheIsFresh: Bool {
        guard let cache, let account = try? accounts.load(selected.kind) else { return false }
        return cache.isValid(for: account, now: Date(), family: addressFamily, settings: cacheValidationSettings)
    }
    var cacheStatus: String {
        guard let cache, cache.kind == selected.kind else { return scanning ? "正在准备节点" : "暂无有效节点缓存" }
        guard cacheIsFresh else { return "节点缓存已过期" }
        if cacheValidationSettings.cacheNeverExpires { return "节点缓存永不过期 · \(addressFamily.label)" }
        return "缓存有效至 " + cache.expiry(settings: cacheValidationSettings).formatted(date: .abbreviated, time: .shortened) + " · \(addressFamily.label)"
    }
    var versionLabel: String {
        "\(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") ?? "1.0.0") (\(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") ?? ""))"
    }
    var statusLabel: String {
        if authorizingVPN && !active { return "正在连接" }
        if switching { return "正在切换" }
        switch status {
        case .connected: return "已连接"
        case .connecting: return "正在连接"
        case .disconnecting: return "正在断开"
        case .reasserting: return "正在恢复"
        default: return "未连接"
        }
    }

    func prepare() async {
        guard !initialized, !preparingApp else { return }
        // Unit-test hosts must not register real devices or start the process-global core.
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
            || NSClassFromString("XCTestCase") != nil { return }
        preparingApp = true
        defer { preparingApp = false }
        do {
            #if DEBUG
            let offlineUI = ProcessInfo.processInfo.arguments.contains("--test-offline-ui")
            #else
            let offlineUI = false
            #endif
            guard let build = (Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String).flatMap(Int.init) else {
                throw UpgradeResetError.invalidJournal
            }
            if !offlineUI { try await LegacyUpgradeMigration.run(currentBuild: build, environment: InstalledUpgradeEnvironment()) }
        } catch {
            Diagnostics.record("legacy upgrade not committed: \(error)", process: "app")
            fail(WARPError.message("清理旧版数据失败，请重新打开应用重试。"))
            return
        }
        initialized = true
        Diagnostics.reset("app")
        #if DEBUG
        if !ProcessInfo.processInfo.arguments.contains("--test-offline-ui") { networkAccessPrimer.start() }
        #else
        networkAccessPrimer.start()
        #endif
        do { settings = try UserSettings.load() } catch { fail(error); return }
        #if DEBUG
        let arguments = ProcessInfo.processInfo.arguments
        if let argument = arguments.first(where: { $0.hasPrefix("--protocol=") }),
           let kind = WARPProtocol(rawValue: String(argument.dropFirst("--protocol=".count))) { settings.tunnelProtocol = kind }
        if let argument = arguments.first(where: { $0.hasPrefix("--family=") }),
           let family = IPAddressFamily(rawValue: String(argument.dropFirst("--family=".count))) { settings.addressFamily = family }
        if arguments.contains("--default-settings") {
            let kind = settings.tunnelProtocol; let family = settings.addressFamily
            settings = UserSettings(); settings.tunnelProtocol = kind; settings.addressFamily = family
        }
        if let argument = arguments.first(where: { $0.hasPrefix("--settings-json=") }),
           let data = Data(base64Encoded: String(argument.dropFirst("--settings-json=".count))),
           let value = try? JSONDecoder().decode(UserSettings.self, from: data).validated() { settings = value }
        try? settings.save()
        #endif
        selected = WARPEndpoint.fixtures(for: settings.tunnelProtocol)[0]
        #if DEBUG
        // Exercise UI compatibility on older simulators without registering identities or running VPN.
        if arguments.contains("--test-offline-ui") { initialized = false; return }
        #endif
        do {
            let managers = try await NETunnelProviderManager.loadAllFromPreferences()
            manager = managers.first { ($0.protocolConfiguration as? NETunnelProviderProtocol)?.providerBundleIdentifier == WARPConfiguration.providerID }
            refreshStatus()
        } catch {
            // Discovering a saved VPN is optional before the user's first connection. System
            // preference authorization errors must not stop internet access or registration.
            Diagnostics.record("VPN preferences not yet available: \(error.localizedDescription)", process: "app")
        }
        observer = NotificationCenter.default.addObserver(forName: .NEVPNStatusDidChange, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.refreshStatus() }
        }
        polling = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refreshDiagnostics()
                try? await Task.sleep(for: .seconds(3))
            }
        }
        if active, selected.kind != settings.tunnelProtocol {
            beginProtocolSwitch(to: settings.tunnelProtocol, previousSettings: settings.forProtocol(selected.kind))
        } else { startPreparation() }
    }

    func selectProtocol(_ kind: WARPProtocol) {
        guard !switching, !measuring, (!active || connected), kind != settings.tunnelProtocol else { return }
        var value = settings; value.tunnelProtocol = kind
        do { try applySettings(value) } catch { fail(error) }
    }

    func selectAddressFamily(_ family: IPAddressFamily) {
        var value = settings; value.addressFamily = family
        do { try applySettings(value) } catch { fail(error) }
    }

    func setTheme(_ theme: UserSettings.Theme) {
        var value = settings; value.theme = theme
        do { try applySettings(value) } catch { fail(error) }
    }

    func applySettings(_ value: UserSettings) throws {
        let value = try value.validated()
        guard !switching, !measuring else { throw WARPError.message("正在切换或测试，请稍候。") }
        guard !active || connected || value.tunnelProtocol == settings.tunnelProtocol else { throw WARPError.message("连接状态正在变化，请稍后切换协议。") }
        let old = settings
        try value.save()
        settings = value
        UserDefaults.standard.set(value.tunnelProtocol.rawValue, forKey: "selectedProtocol")
        if connected, old.tunnelProtocol != value.tunnelProtocol {
            beginProtocolSwitch(to: value.tunnelProtocol, previousSettings: old)
            return
        }
        if active {
            if old.measurementFingerprint != value.measurementFingerprint || old.cacheHours != value.cacheHours {
                message = "设置已保存，网络与优选设置将在断开后应用"
            }
            return
        }
        let changed = old.tunnelProtocol != value.tunnelProtocol || old.measurementFingerprint != value.measurementFingerprint
        if changed {
            selected = WARPEndpoint.fixtures(for: value.tunnelProtocol)[0]
            cache = nil; endpoints = []; results = [:]; trace = ""; errorMessage = nil
        }
        if changed || old.cacheHours != value.cacheHours { startPreparation() }
    }

    func chooseAutomatic() {
        guard !selectionUnavailable, let cache, let fastest = fastestNode(in: cache) else { return }
        if connected { beginNodeSwitch(to: fastest, automatic: true); return }
        automaticSelection = true; UserDefaults.standard.set("auto", forKey: choiceKey)
        selected = fastest
    }
    func chooseNode(_ endpoint: WARPEndpoint) {
        guard !selectionUnavailable, cache?.results.contains(where: { $0.endpoint == endpoint }) == true else { return }
        if connected { beginNodeSwitch(to: endpoint, automatic: false); return }
        automaticSelection = false; selected = endpoint
        UserDefaults.standard.set(endpoint.id, forKey: choiceKey)
    }

    private func beginNodeSwitch(to endpoint: WARPEndpoint, automatic: Bool) {
        guard cacheIsFresh else { fail(WARPError.message("节点缓存已过期，请先断开 VPN 更新节点。")); return }
        switching = true; invalidateVerification(); message = "正在切换到 \(endpoint.address)"
        switchingTask = Task { [self] in
            defer { switching = false; switchingTask = nil }
            do {
                let state = try await hotSwitch(to: endpoint, automatic: automatic)
                acceptRuntime(state)
                storeChoice(endpoint: endpoint, automatic: automatic)
                message = "已热切换到 \(endpoint.address)"
            } catch { fail(error) }
            await refreshDiagnostics()
        }
    }

    private func beginProtocolSwitch(to kind: WARPProtocol, previousSettings: UserSettings) {
        guard !switching else { return }
        let running = effectiveSettings
        switching = true; invalidateVerification(); message = "正在检查 \(kind.label) 本地缓存"
        switchingTask = Task { [self] in
            var disconnectingForPreparation = false
            do {
                if let cached = try CachedTunnelTarget.load(kind: kind, running: running, latest: settings, accounts: accounts, caches: caches),
                   let choice = CachedNodeChoice.resolve(cached, stored: UserDefaults.standard.string(forKey: nodeChoiceKey(kind, family: running.addressFamily)), measurements: NodeMeasurementStore().load(for: cached)) {
                    let state = try await hotSwitch(to: choice.endpoint, automatic: choice.automatic)
                    acceptRuntime(state); cache = cached; apply(cached)
                    storeChoice(endpoint: choice.endpoint, automatic: choice.automatic)
                    progress = .init(stage: .ready, fraction: 1, title: "连接已就绪", detail: "已使用本地缓存热切换协议")
                    message = "已热切换至 \(kind.label)，VPN 保持连接"
                } else {
                    disconnectingForPreparation = true
                    message = "\(kind.label) 暂无有效缓存，正在断开 VPN，随后注册和优选"
                    try await DisconnectedPreparation.run(disconnect: { self.manager?.connection.stopVPNTunnel() },
                        waitUntilDisconnected: { try await self.waitUntilDisconnected() }, prepare: {
                            self.selected = WARPEndpoint.fixtures(for: kind)[0]
                            self.cache = nil; self.endpoints = []; self.results = [:]; self.trace = ""; self.errorMessage = nil
                            self.switching = false; self.switchingTask = nil
                            self.startPreparation()
                        })
                    return // Preparation deliberately never calls connect().
                }
            } catch {
                if !disconnectingForPreparation {
                    do {
                        try previousSettings.save(); settings = previousSettings
                        UserDefaults.standard.set(previousSettings.tunnelProtocol.rawValue, forKey: "selectedProtocol")
                    } catch { Diagnostics.record("switch preference rollback failed: \(error.localizedDescription)", process: "app") }
                }
                fail(error)
            }
            switching = false; switchingTask = nil
            refreshStatus()
            await refreshDiagnostics()
        }
    }

    private func hotSwitch(to endpoint: WARPEndpoint, automatic: Bool) async throws -> ActiveTunnelState {
        guard connected, let session = manager?.connection as? NETunnelProviderSession,
              let current = runtimeState else { throw WARPError.message("当前隧道不支持热切换，请重新连接一次。") }
        let request = TunnelSwitchRequest(id: UUID(), sessionID: current.sessionID, expectedRevision: current.revision, endpoint: endpoint, automatic: automatic)
        do {
            let data = try await ProviderMessageClient.send(JSONEncoder().encode(request)) { try session.sendProviderMessage($0, responseHandler: $1) }
            let reply = try JSONDecoder().decode(TunnelSwitchReply.self, from: data)
            guard reply.requestID == request.id, reply.success, let state = reply.state, request.isConfirmed(by: state) else {
                throw WARPError.message(LocalizedText(reply.error ?? "无法确认热切换结果。"))
            }
            guard [.connected, .reasserting].contains(session.status) else { throw WARPError.message("VPN 已断开。") }
            Diagnostics.record("hot switch acknowledged session=\(state.sessionID) revision=\(state.revision) endpoint=\(state.endpoint.id) tunOpens=\(state.tunOpenCount)", process: "app")
            return state
        } catch {
            // A lost acknowledgement must not make the UI claim a node the provider is no longer using.
            if let state = try? await queryRuntime(session), state.sessionID == request.sessionID {
                if request.isConfirmed(by: state), [.connected, .reasserting].contains(session.status) { return state }
                acceptRuntime(state)
            } else { manager?.connection.stopVPNTunnel() }
            throw error
        }
    }

    private func queryRuntime(_ session: NETunnelProviderSession) async throws -> ActiveTunnelState {
        let data = try await ProviderMessageClient.send(Data("status".utf8), timeout: 5) { try session.sendProviderMessage($0, responseHandler: $1) }
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard let runtime = object?["runtime"] else { throw WARPError.message("无法读取运行中的隧道状态。") }
        return try JSONDecoder().decode(ActiveTunnelState.self, from: JSONSerialization.data(withJSONObject: runtime))
    }
    private func waitUntilDisconnected() async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(20))
        while manager.map({ [.connected, .connecting, .reasserting, .disconnecting].contains($0.connection.status) }) == true {
            guard ContinuousClock.now < deadline else { throw WARPError.message("VPN 尚未断开，暂未开始注册和优选。") }
            try await Task.sleep(for: .milliseconds(100))
        }
        refreshStatus()
    }
    private func nodeChoiceKey(_ kind: WARPProtocol, family: IPAddressFamily) -> String { "node-choice.\(kind.rawValue):\(family.rawValue)" }
    private func storeChoice(endpoint: WARPEndpoint, automatic: Bool) {
        automaticSelection = automatic
        UserDefaults.standard.set(automatic ? "auto" : endpoint.id, forKey: nodeChoiceKey(endpoint.kind, family: endpoint.family ?? addressFamily))
    }
    private func acceptRuntime(_ state: ActiveTunnelState) {
        guard state.settings.tunnelProtocol == state.endpoint.kind, state.endpoint.family == state.settings.addressFamily else { return }
        runtimeState = state; runningSettings = state.settings; selected = state.endpoint; automaticSelection = state.automatic
        if !measuring { storeChoice(endpoint: state.endpoint, automatic: state.automatic) }
        refreshConnectionLocation()
    }
    private func invalidateVerification() { verificationID = UUID(); verifying = false; trace = "" }

    private func clearConnectionLocation() {
        locationTask?.cancel(); locationTask = nil; locationKey = nil
        connectionLocation = nil; locatingConnection = false
    }

    private func refreshConnectionLocation() {
        guard connected, !measuring, let runtimeState else { return }
        let key = "\(runtimeState.sessionID):\(runtimeState.revision):\(runtimeState.endpoint.id)"
        guard key != locationKey else { return }
        clearConnectionLocation()
        locationKey = key; locatingConnection = true
        let configuration = runtimeState.settings
        locationTask = Task { [weak self] in
            do {
                let location = try await ConnectionLocation.fetch(settings: configuration)
                try Task.checkCancellation()
                guard let self, self.connected, self.locationKey == key else { return }
                self.connectionLocation = location
                Diagnostics.record("connection location country=\(location.country) colo=\(location.colo)", process: "app")
            } catch {
                if !Task.isCancelled { Diagnostics.record("connection location unavailable: \(error.localizedDescription)", process: "app") }
            }
            guard let self, self.locationKey == key else { return }
            self.locatingConnection = false; self.locationTask = nil
        }
    }

    func nodeName(_ endpoint: WARPEndpoint) -> String {
        let index = endpoints.firstIndex(of: endpoint).map { $0 + 1 } ?? 1
        return "\(endpoint.kind.label)\(String(format: "%02d", index))"
    }
    var automaticEndpoint: WARPEndpoint { cache.flatMap { fastestNode(in: $0) } ?? displaySelected }
    var selectedNodeName: String { displayAutomatic ? "自动选择" : nodeName(displaySelected) }
    func latency(for endpoint: WARPEndpoint) -> Int? { measurements[endpoint.id]?.latencyMS ?? results[endpoint.id]?.median.map(Int.init) }
    func speed(for endpoint: WARPEndpoint) -> Double? { measurements[endpoint.id]?.downloadMbps ?? results[endpoint.id]?.speedMbps }
    private func fastestNode(in cache: NodeCache) -> WARPEndpoint? {
        CachedNodeChoice.resolve(cache, stored: "auto", measurements: measurements)?.endpoint
    }

    func testCachedNodes(_ kind: NodeMeasurementKind) {
        if measurementKind == kind { measurementTask?.cancel(); return }
        guard !selectionUnavailable, cacheIsFresh, let cached = cache, !cached.results.isEmpty else { return }
        measurementOrigin = CachedNodeChoice(endpoint: selected, automatic: automaticSelection)
        measurementKind = kind; invalidateVerification(); clearConnectionLocation(); errorMessage = nil
        measurementTask = Task { [self] in
            defer {
                testingNodeID = nil; measurementKind = nil; measurementOrigin = nil; measurementTask = nil
                refreshConnectionLocation()
                endBackgroundExecution()
            }
            do {
                if !connected {
                    await connect()
                    if let errorMessage { throw WARPError.message(LocalizedText(errorMessage)) }
                    try await VPNConnectionAwaiter.wait(status: { self.manager?.connection.status ?? .invalid }, refresh: { self.refreshStatus() })
                }
                guard let original = measurementOrigin, let sessionID = runtimeState?.sessionID else { throw WARPError.message("无法读取隧道状态。") }
                for (index, result) in cached.results.enumerated() {
                    try Task.checkCancellation()
                    guard manager?.connection.status == .connected, runtimeState?.sessionID == sessionID else { throw WARPError.message("VPN 已断开，测试已停止。") }
                    let endpoint = result.endpoint
                    testingNodeID = endpoint.id
                    message = "\(kind == .latency ? "延迟测试" : "下载测速") · \(index + 1)/\(cached.results.count) · \(nodeName(endpoint))"
                    var value: Double = -1
                    do {
                        if selected != endpoint {
                            acceptRuntime(try await hotSwitch(to: endpoint, automatic: original.automatic))
                        }
                        value = try await LiveNodeProbe.measure(kind, settings: effectiveSettings)
                        try Task.checkCancellation()
                    } catch {
                        if Task.isCancelled { throw CancellationError() }
                        Diagnostics.record("cached test \(kind.rawValue) \(endpoint.id) failed: \(error.localizedDescription)", process: "app")
                    }
                    var measurement = measurements[endpoint.id] ?? NodeMeasurement()
                    if kind == .latency { measurement.latencyMS = value > 0 ? Int(value.rounded()) : -1 }
                    else { measurement.downloadMbps = value }
                    measurements[endpoint.id] = measurement
                    try NodeMeasurementStore().save(measurements, for: cached)
                    Diagnostics.record("cached test \(kind.rawValue) \(endpoint.id) value=\(value)", process: "app")
                }
                message = "\(kind == .latency ? "延迟测试" : "下载测速")完成，VPN 保持连接"
            } catch {
                message = Task.isCancelled ? "测试已停止" : LocalizedText(error.localizedDescription)
                Diagnostics.record("cached test stopped: \(error.localizedDescription)", process: "app")
            }
            testingNodeID = nil
            // Restore the user's manual choice; automatic mode follows the lowest successful latency.
            if let original = measurementOrigin, manager?.connection.status == .connected {
                let endpoint = original.automatic ? fastestNode(in: cached) ?? original.endpoint : original.endpoint
                do {
                    if selected != endpoint || automaticSelection != original.automatic {
                        acceptRuntime(try await hotSwitch(to: endpoint, automatic: original.automatic))
                    }
                    storeChoice(endpoint: endpoint, automatic: original.automatic)
                } catch { message = "测试已结束，当前节点保持连接；恢复原选择失败：\(error.localizedDescription)" }
            }
            await refreshDiagnostics()
        }
    }

    func cachedExportCount(kind: WARPProtocol, family: IPAddressFamily) throws -> Int {
        try NodeExportService(accounts: accounts, caches: caches).count(kind: kind, family: family)
    }
    func exportCachedNodes(kind: WARPProtocol, family: IPAddressFamily, format: NodeExportFormat) throws -> NodeExportPayload {
        guard kind == settings.tunnelProtocol else { throw WARPError.message("请先在设置中选择需要导出的协议。") }
        return try NodeExportService(accounts: accounts, caches: caches).export(kind: kind, family: family, format: format, mtu: settings.effectiveMTU)
    }

    private func refreshStatus() {
        let old = status
        status = manager?.connection.status ?? .invalid
        if !connected { clearConnectionLocation() }
        if active, !switching, let config = (manager?.protocolConfiguration as? NETunnelProviderProtocol)?.providerConfiguration,
           let host = config["host"] as? String, let port = config["port"] as? Int {
            if let id = (config["sessionID"] as? String).flatMap(UUID.init(uuidString:)),
               let state = try? ActiveTunnelStore().load(), state.sessionID == id {
                acceptRuntime(state)
            } else if runtimeState == nil {
                let kind = WARPProtocol(rawValue: config["kind"] as? String ?? "wg") ?? .wg
                selected = WARPEndpoint(host: host, port: port, kind: kind)
                automaticSelection = config["automatic"] as? Bool ?? true
                if let data = config["settings"] as? Data, let value = try? JSONDecoder().decode(UserSettings.self, from: data) { runningSettings = value }
                else {
                    var legacy = UserSettings(); legacy.tunnelProtocol = kind
                    legacy.addressFamily = IPAddressFamily(rawValue: config["family"] as? String ?? "ipv4") ?? .ipv4
                    runningSettings = legacy
                }
            }
        }
        if !active {
            runningSettings = nil; runtimeState = nil
            if selected.kind != settings.tunnelProtocol || selected.family != settings.addressFamily && old != status {
                selected = WARPEndpoint.fixtures(for: settings.tunnelProtocol)[0]
            }
        }
        if old != status {
            Diagnostics.record("VPN status=\(statusLabel)", process: "app")
            if connected && !switching { message = "隧道已建立"; refreshConnectionLocation() }
            if [.invalid, .disconnected].contains(status) {
                trace = ""
                if foreground && !switching { startPreparation() }
            }
        }
    }

    private func startPreparation(force: Bool = false) {
        guard initialized, foreground, !switching, !measuring else { return }
        let kind = selected.kind
        let family = addressFamily
        let configuration = effectiveSettings
        if active {
            do {
                cache = try caches.load(kind, family: family)
                if let cache {
                    apply(cache)
                    if cacheIsFresh { progress = .init(stage: .ready, fraction: 1, title: "连接已就绪", detail: "节点缓存有效") }
                }
                if !cacheIsFresh { message = "当前 VPN 正在运行，断开后会自动注册并更新节点" }
            } catch { fail(error) }
            return
        }
        if scanning, taskKind == kind, taskFamily == family, taskFingerprint == configuration.measurementFingerprint,
           taskCacheHours == configuration.cacheHours, preparationTask?.isCancelled == false, !force { return }
        let pending: OptimizationCheckpoint?
        do { pending = force ? nil : try pendingCheckpoint(kind: kind, settings: configuration) }
        catch { fail(error); return }
        // A valid cache is already ready. Never publish .initial just to rediscover it asynchronously:
        // foregrounding and normal disconnects would briefly animate the green bar back to zero.
        if !force, pending == nil {
            do {
                if let account = try accounts.load(kind), let saved = try caches.load(kind, family: family),
                   saved.isValid(for: account, now: Date(), family: family, settings: configuration) {
                    preparationTask?.cancel(); generation = UUID()
                    cache = saved; apply(saved)
                    scanning = false; resumablePreparation = false
                    progress = .init(stage: .ready, fraction: 1, title: "连接已就绪", detail: "节点缓存有效")
                    message = "节点缓存有效"
                    try checkpoints.remove(kind, family: family)
                    return
                }
            } catch { fail(error); return }
        }
        if cache?.kind != kind || cache?.addressFamily != family { cache = nil; results = [:]; endpoints = [] }
        let previous = preparationTask
        previous?.cancel()
        let ticket = UUID(); generation = ticket; taskKind = kind; taskFamily = family; taskFingerprint = configuration.measurementFingerprint
        taskCacheHours = configuration.cacheHours
        scanning = true
        resumablePreparation = pending != nil
        progress = pending?.progress ?? .initial
        message = pending.map { "继续上次优选 · 已保留 \($0.screening.values.reduce(0) { $0 + $1.samples.count }) 轮初筛、\($0.completed.count) 个节点的质量复测" }
            ?? "正在检查 \(kind.label) · \(family.label) 注册与\(configuration.cacheDurationText)缓存"
        preparationTask = Task { [self] in
            // The SDK owns process-global state. A protocol switch must await teardown first.
            await previous?.value
            guard generation == ticket else { return }
            if Task.isCancelled { scanning = false; return }
            do {
                let preparation = NodePreparation(accounts: accounts, caches: caches,
                    registration: WARPRegistration(), optimizer: MihomoOptimizer(family: family, settings: configuration, checkpoints: checkpoints, userInitiated: force),
                    family: family, settings: configuration, checkpoints: checkpoints)
                let ready = try await preparation.prepare(kind: kind, force: force) { [weak self] update in
                    await self?.receive(update, ticket: ticket, kind: kind)
                }
                try Task.checkCancellation()
                guard generation == ticket, selected.kind == kind, addressFamily == family else { return }
                cache = ready.cache
                resumablePreparation = false
                apply(ready.cache)
                message = ready.reusedCache ? "已使用 \(kind.label) 节点缓存，无需重复注册或优选（\(family.label)）" : "\(kind.label) · \(family.label) 优选完成，缓存\(configuration.cacheDurationText)"
                Diagnostics.record("cache \(ready.reusedCache ? "hit" : "saved") protocol=\(kind.rawValue) family=\(family.rawValue)", process: "app")
            } catch {
                guard generation == ticket else { return }
                if Task.isCancelled || error is CancellationError {
                    message = "已暂停，已完成的探测已保存；回来后会继续优选"
                    progress = progress.stopped(failed: false, detail: message)
                }
                else { fail(error) }
                resumablePreparation = (try? pendingCheckpoint(kind: kind, settings: configuration)) != nil
            }
            guard generation == ticket else { return }
            scanning = false
            endBackgroundExecution()
            await refreshDiagnostics()
        }
    }

    private func receive(_ update: PreparationUpdate, ticket: UUID, kind: WARPProtocol) {
        guard generation == ticket, selected.kind == kind else { return }
        switch update {
        case .status(let text): message = text
        case .progress(let value): progress = value; message = value.detail
        case .sample(let result):
            resumablePreparation = true
            if !foreground { Diagnostics.record("background measurement saved endpoint=\(result.endpoint.id) rounds=\(result.samples.count)", process: "app") }
            results[result.endpoint.id] = result
            endpoints = results.values.filter { $0.endpoint.kind == kind }.sorted(by: ProbeResult.isBetter).map(\.endpoint)
        }
    }

    private func pendingCheckpoint(kind: WARPProtocol, settings: UserSettings) throws -> OptimizationCheckpoint? {
        guard let account = try accounts.load(kind), let saved = try checkpoints.load(kind, family: settings.addressFamily),
              saved.isValid(account: account, settings: settings, now: Date()) else { return nil }
        if let cached = try caches.load(kind, family: settings.addressFamily),
           cached.isValid(for: account, now: Date(), family: settings.addressFamily, settings: settings),
           cached.createdAt >= saved.startedAt || settings.cacheNeverExpires && saved.userInitiated != true { return nil }
        return saved
    }

    private func apply(_ cache: NodeCache) {
        guard cache.kind == selected.kind, cache.addressFamily == addressFamily else { return }
        results = Dictionary(cache.results.map { ($0.endpoint.id, $0) }, uniquingKeysWith: { _, new in new })
        endpoints = cache.results.map(\.endpoint)
        measurements = NodeMeasurementStore().load(for: cache)
        let stored = UserDefaults.standard.string(forKey: choiceKey)
        automaticSelection = stored == nil || stored == "auto"
        if !active {
            if let stored, stored != "auto", let manual = endpoints.first(where: { $0.id == stored }) {
                automaticSelection = false; selected = manual
            } else {
                automaticSelection = true
                if let fastest = fastestNode(in: cache) { selected = fastest }
            }
        }
    }

    func enteredForeground() {
        foreground = true
        endBackgroundExecution()
        if !initialized {
            Task { await prepare() }
            return
        }
        startPreparation()
        if connected, connectionLocation == nil, locationTask == nil {
            locationKey = nil; refreshConnectionLocation()
        }
    }
    func enteredBackground() {
        foreground = false
        guard scanning || measuring, backgroundTask == .invalid else { return }
        backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "Continue node preparation") { [weak self] in
            Task { @MainActor in self?.backgroundTimeExpired() }
        }
        if backgroundTask == .invalid { backgroundTimeExpired() }
        else { Diagnostics.record("preparation continues in background; measurements checkpointed after each round", process: "app") }
        #if DEBUG
        // UI tests exercise the same expiry path without assuming an iOS-specific time budget.
        if let argument = ProcessInfo.processInfo.arguments.first(where: { $0.hasPrefix("--test-background-expiry=") }),
           let seconds = Int(argument.dropFirst("--test-background-expiry=".count)), (1...60).contains(seconds), backgroundTask != .invalid {
            testBackgroundDeadline = Task { [weak self] in
                do { try await Task.sleep(for: .seconds(seconds)) } catch { return }
                self?.backgroundTimeExpired()
            }
        }
        #endif
    }
    private func endBackgroundExecution() {
        #if DEBUG
        testBackgroundDeadline?.cancel(); testBackgroundDeadline = nil
        #endif
        if backgroundTask != .invalid { UIApplication.shared.endBackgroundTask(backgroundTask); backgroundTask = .invalid }
    }
    private func backgroundTimeExpired() {
        guard !foreground else { return }
        preparationTask?.cancel()
        measurementTask?.cancel()
        endBackgroundExecution()
        if scanning {
            message = "系统后台执行时间已用完，进度已保存；回来后继续优选"
            progress = progress.stopped(failed: false, detail: message)
            Diagnostics.record("background time expired; preparation paused with durable checkpoint", process: "app")
        }
    }
    func scan() { startPreparation(force: !resumablePreparation) }
    func stopScan() { preparationTask?.cancel() }

    func connect() async {
        guard !preparingApp, !authorizingVPN, !scanning, !switching, !active else { return }
        guard cacheIsFresh else { startPreparation(); return }
        authorizingVPN = true
        defer { authorizingVPN = false }
        do {
            trace = ""
            let manager = self.manager ?? NETunnelProviderManager()
            let config = NETunnelProviderProtocol()
            config.providerBundleIdentifier = WARPConfiguration.providerID
            config.serverAddress = selected.address
            config.providerConfiguration = ["host": selected.host, "port": selected.port, "kind": selected.kind.rawValue,
                "family": addressFamily.rawValue, "settings": try JSONEncoder().encode(settings),
                "sessionID": UUID().uuidString, "automatic": automaticSelection]
            config.disconnectOnSleep = false
            // IPv6 fake-IP uses ULA space; keep it inside the tunnel's default route.
            config.excludeLocalNetworks = settings.doNotSetDNS || (!settings.dnsLeakProtection && addressFamily == .ipv4)
            manager.protocolConfiguration = config
            manager.localizedDescription = "TrashVPN · WARP"
            manager.isEnabled = true
            try await VPNAuthorizationFlow.start(save: { try await manager.saveToPreferences() },
                reload: { try await manager.loadFromPreferences(); self.manager = manager },
                start: { try manager.connection.startVPNTunnel() })
            message = "正在建立 \(selected.kind.detail) 隧道"
            refreshStatus()
        } catch { fail(error) }
    }

    func disconnect() { measurementTask?.cancel(); invalidateVerification(); manager?.connection.stopVPNTunnel(); trace = ""; message = "正在断开隧道" }

    func verify() async {
        guard connected, !switching, !verifying else { return }
        let ticket = UUID(); verificationID = ticket
        verifying = true; trace = ""; defer { if verificationID == ticket { verifying = false } }
        do {
            let config = URLSessionConfiguration.ephemeral
            config.timeoutIntervalForRequest = 15
            config.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
            let session = URLSession(configuration: config, delegate: effectiveSettings.doNotSetDNS ? NoRedirectDelegate() : nil, delegateQueue: nil)
            defer { session.invalidateAndCancel() }
            let target = effectiveSettings.doNotSetDNS
                ? (addressFamily == .ipv6 ? "https://[2606:4700:4700::1111]/cdn-cgi/trace" : "https://1.1.1.1/cdn-cgi/trace")
                : "https://www.cloudflare.com/cdn-cgi/trace"
            var request = URLRequest(url: URL(string: target + "?trashvpn=\(UUID().uuidString)")!)
            if effectiveSettings.doNotSetDNS { request.setValue("one.one.one.one", forHTTPHeaderField: "Host") }
            var (data, response) = try await session.data(for: request)
            if effectiveSettings.doNotSetDNS, (response as? HTTPURLResponse)?.statusCode != 200 {
                (data, response) = try await session.data(from: URL(string: "https://one.one.one.one/cdn-cgi/trace?trashvpn=\(UUID().uuidString)")!)
            }
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw WARPError.message("出口验证 HTTP 状态异常") }
            let text = String(decoding: data, as: UTF8.self)
            let fields = Dictionary(text.split(separator: "\n").compactMap { line -> (String, String)? in
                let parts = line.split(separator: "=", maxSplits: 1); return parts.count == 2 ? (String(parts[0]), String(parts[1])) : nil
            }, uniquingKeysWith: { _, new in new })
            guard fields["warp"] == "on" || fields["warp"] == "plus" else { throw WARPError.message("HTTPS 可达，但出口未确认 WARP。") }
            if addressFamily == .ipv6 {
                guard IPAddressFamily.ipv6.contains(fields["ip"] ?? "") else {
                    throw WARPError.message("WARP 已连通，但尚未验证到 IPv6 出口。请重试验证或切换节点。")
                }
                // IP literals exercise both packet families without DNS or redirects.
                let literalSession = URLSession(configuration: config, delegate: NoRedirectDelegate(), delegateQueue: nil)
                defer { literalSession.invalidateAndCancel() }
                for (label, url) in [("IPv4", "https://1.1.1.1/cdn-cgi/trace"),
                                     ("IPv6", "https://[2606:4700:4700::1111]/cdn-cgi/trace")] {
                    let (_, response) = try await literalSession.data(from: URL(string: url)!)
                    guard let code = (response as? HTTPURLResponse)?.statusCode, (200..<400).contains(code) else {
                        throw WARPError.message("IPv6 出口正常，但 \(label) HTTPS 验证失败。")
                    }
                }
            }
            guard verificationID == ticket else { return }
            trace = "WARP 已验证 · \(fields["loc"] ?? "")\n\(addressFamily == .ipv6 ? "IPv6 出口" : "出口 IP")：\(fields["ip"] ?? "")"
                + (addressFamily == .ipv6 ? "\nIPv4 HTTPS 可达 · IPv6 HTTPS 可达" : "")
            message = "\(selected.kind.detail) 数据链路验证成功"
            Diagnostics.record("verification passed protocol=\(selected.kind.rawValue) family=\(addressFamily.rawValue) endpoint=\(selected.address) warp=\(fields["warp"] ?? "") exit=\(fields["ip"] ?? "")", process: "app")
        } catch { if verificationID == ticket { trace = "验证失败"; fail(error) } }
        await refreshDiagnostics()
    }

    func refreshDiagnostics() async {
        var text = "MTU: \(effectiveSettings.effectiveMTU)\nDNS issued: \(!effectiveSettings.doNotSetDNS)\nDNS protection: \(effectiveSettings.dnsLeakProtection)\nStage: \(progress.stage.rawValue) \(progress.fraction)\nCore: \(ClashVersion())\nVPN: \(statusLabel)\nProtocol: \(selected.kind.rawValue)\nFamily: \(addressFamily.rawValue)\nCache: \(cacheStatus)\n"
        if let connectionLocation { text += "Connection location: \(connectionLocation.country) \(connectionLocation.colo)\n" }
        #if DEBUG
        if let data = try? JSONEncoder().encode(measurements) {
            text += "Cached measurements: " + String(decoding: data, as: UTF8.self) + "\n"
        }
        text += "Cached test: \(measurementKind?.rawValue ?? "none") node=\(testingNodeID ?? "none")\n"
        if let encoded = try? JSONEncoder().encode(settings) {
            text += "Settings snapshot: " + String(decoding: encoded, as: UTF8.self) + "\n"
        }
        let counts = Dictionary(uniqueKeysWithValues: WARPProtocol.allCases.map { kind in
            (kind.rawValue, (try? CachedTunnelTarget.load(kind: kind, running: effectiveSettings, latest: settings, accounts: accounts, caches: caches))?.results.count ?? 0)
        })
        if let data = try? JSONSerialization.data(withJSONObject: counts, options: [.sortedKeys]) {
            text += "Local caches: " + String(decoding: data, as: UTF8.self) + "\n"
        }
        #endif
        if let cache {
            let quality: [String: Any] = ["schema": cache.schema, "nodes": cache.results.count,
                "latencyRounds": cache.results.map { $0.samples.count },
                "downloadRounds": cache.results.map { $0.downloadMbps?.count ?? 0 },
                "downloadEnabled": cache.results.first?.qualityProfile?.downloadEnabled ?? true,
                "minimumMbps": cache.results.first?.qualityProfile?.minimumMbps ?? ProbeResult.minimumMbps]
            if let data = try? JSONSerialization.data(withJSONObject: quality, options: [.sortedKeys]) {
                text += "Quality cache: " + String(decoding: data, as: UTF8.self) + "\n"
            }
        }
        if let saved = try? pendingCheckpoint(kind: selected.kind, settings: effectiveSettings) {
            let summary: [String: Any] = ["id": saved.id.uuidString, "screeningRounds": saved.screening.values.reduce(0) { $0 + $1.samples.count },
                "completedNodes": saved.completed.count, "latencyRounds": saved.partial?.samples.count ?? 0,
                "downloadRounds": saved.partial?.downloadMbps?.count ?? 0, "fraction": saved.progress.fraction,
                "totalDownloadRounds": saved.completed.reduce(0) { $0 + ($1.downloadMbps?.count ?? 0) } + (saved.partial?.downloadMbps?.count ?? 0),
                "startedAt": saved.startedAt.timeIntervalSince1970]
            if let data = try? JSONSerialization.data(withJSONObject: summary, options: [.sortedKeys]) {
                text += "Checkpoint: " + String(decoding: data, as: UTF8.self) + "\n"
            }
        }
        if connected, let session = manager?.connection as? NETunnelProviderSession {
            let reply = try? await ProviderMessageClient.send(Data("status".utf8), timeout: 5) { try session.sendProviderMessage($0, responseHandler: $1) }
            if let reply, let object = try? JSONSerialization.jsonObject(with: reply) as? [String: Any] {
                text += "Provider MTU: \(object["mtu"] ?? "") · DNS issued: \(object["dnsIssued"] ?? "")\n端点：\(object["endpoint"] ?? "")\n上行包：\(object["packetsFromSystem"] ?? 0) · 下行包：\(object["packetsToSystem"] ?? 0)\n内存：\((object["memoryBytes"] as? Int64 ?? 0) / 1024 / 1024) MB\n"
                if let runtime = object["runtime"], let data = try? JSONSerialization.data(withJSONObject: runtime),
                   let state = try? JSONDecoder().decode(ActiveTunnelState.self, from: data) {
                    text += "Live tunnel: session=\(state.sessionID) revision=\(state.revision) tunOpens=\(state.tunOpenCount) endpoint=\(state.endpoint.id) started=\(state.startedAt.timeIntervalSince1970)\n"
                    text += "Live snapshot: " + String(decoding: data, as: UTF8.self) + "\n"
                }
            }
        }
        text += "\n" + Diagnostics.read("app") + "\n" + Diagnostics.read("probe") + "\n" + Diagnostics.read("tunnel")
        diagnostics = text
        try? text.write(to: reportURL, atomically: true, encoding: .utf8)
    }
    var reportURL: URL { FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("WARP-Diagnostics.txt") }
    private func fail(_ error: Error) {
        errorMessage = error.localizedDescription; message = LocalizedText(error.localizedDescription)
        if scanning { progress = progress.stopped(failed: true, detail: message) }
        Diagnostics.record(error.localizedDescription, process: "app")
    }
}

private final class NoRedirectDelegate: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}
