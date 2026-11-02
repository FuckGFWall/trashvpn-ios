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
    private var runningSettings: UserSettings?
    var effectiveSettings: UserSettings { active ? runningSettings ?? settings : settings }
    var addressFamily: IPAddressFamily { effectiveSettings.addressFamily }
    var selectionKey: String { "\(selected.kind.rawValue):\(addressFamily.rawValue)" }
    private var choiceKey: String { "node-choice.\(selectionKey)" }
    @Published var results: [String: ProbeResult] = [:]
    @Published var endpoints: [WARPEndpoint] = []
    @Published var scanning = false
    @Published var verifying = false
    @Published var message = "正在检查注册与节点缓存"
    @Published var trace = ""
    @Published var diagnostics = ""
    @Published var errorMessage: String?
    @Published var cache: NodeCache?
    private var manager: NETunnelProviderManager?
    private let accounts = KeychainAccountStore()
    private let caches = NodeCacheStore()
    private var preparationTask: Task<Void, Never>?
    private var generation = UUID()
    private var taskKind: WARPProtocol?
    private var taskFamily: IPAddressFamily?
    private var observer: NSObjectProtocol?
    private var polling: Task<Void, Never>?
    private var backgroundTask = UIBackgroundTaskIdentifier.invalid
    private var initialized = false
    private var foreground = true
    private var taskFingerprint: String?
    private var taskCacheHours: Int?

    var active: Bool { [.connected, .connecting, .reasserting, .disconnecting].contains(status) }
    var connected: Bool { status == .connected }
    var cacheIsFresh: Bool {
        guard let cache, let account = try? accounts.load(selected.kind) else { return false }
        return cache.isValid(for: account, now: Date(), family: addressFamily, settings: effectiveSettings)
    }
    var cacheStatus: String {
        guard let cache, cache.kind == selected.kind else { return scanning ? "正在准备节点" : "暂无有效节点缓存" }
        guard cacheIsFresh else { return "节点缓存已过期" }
        return "缓存有效至 " + cache.expiry(settings: effectiveSettings).formatted(date: .abbreviated, time: .shortened) + " · \(addressFamily.label)"
    }
    var versionLabel: String {
        "\(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") ?? "1.0.0") (\(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") ?? ""))"
    }
    var statusLabel: String {
        switch status {
        case .connected: return "已连接"
        case .connecting: return "正在连接"
        case .disconnecting: return "正在断开"
        case .reasserting: return "正在恢复"
        default: return "未连接"
        }
    }

    func prepare() async {
        guard !initialized else { return }
        // Unit-test hosts must not register real devices or start the process-global core.
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
            || NSClassFromString("XCTestCase") != nil { return }
        initialized = true
        Diagnostics.reset("app")
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
        do {
            let managers = try await NETunnelProviderManager.loadAllFromPreferences()
            manager = managers.first { ($0.protocolConfiguration as? NETunnelProviderProtocol)?.providerBundleIdentifier == WARPConfiguration.providerID }
            refreshStatus()
            observer = NotificationCenter.default.addObserver(forName: .NEVPNStatusDidChange, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.refreshStatus() }
            }
            polling = Task { [weak self] in
                while !Task.isCancelled {
                    await self?.refreshDiagnostics()
                    try? await Task.sleep(for: .seconds(3))
                }
            }
            startPreparation()
        } catch { fail(error) }
    }

    func selectProtocol(_ kind: WARPProtocol) {
        guard !active, kind != settings.tunnelProtocol else { return }
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
        guard !active || value.tunnelProtocol == settings.tunnelProtocol else { throw WARPError.message("请先断开 VPN 再切换协议。") }
        let old = settings
        try value.save()
        settings = value
        UserDefaults.standard.set(value.tunnelProtocol.rawValue, forKey: "selectedProtocol")
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
        guard !active, !scanning else { return }
        automaticSelection = true; UserDefaults.standard.set("auto", forKey: choiceKey)
        if let cache, let fastest = ProbeResult.fastest(cache.results) { selected = fastest }
    }
    func chooseNode(_ endpoint: WARPEndpoint) {
        guard !active, !scanning, cache?.results.contains(where: { $0.endpoint == endpoint }) == true else { return }
        automaticSelection = false; selected = endpoint
        UserDefaults.standard.set(endpoint.id, forKey: choiceKey)
    }

    private func refreshStatus() {
        let old = status
        status = manager?.connection.status ?? .invalid
        if active, let config = (manager?.protocolConfiguration as? NETunnelProviderProtocol)?.providerConfiguration,
           let host = config["host"] as? String, let port = config["port"] as? Int {
            let kind = WARPProtocol(rawValue: config["kind"] as? String ?? "wg") ?? .wg
            selected = WARPEndpoint(host: host, port: port, kind: kind)
            if let data = config["settings"] as? Data, let value = try? JSONDecoder().decode(UserSettings.self, from: data) { runningSettings = value }
            else {
                var legacy = UserSettings(); legacy.tunnelProtocol = kind
                legacy.addressFamily = IPAddressFamily(rawValue: config["family"] as? String ?? "ipv4") ?? .ipv4
                runningSettings = legacy
            }
        }
        if !active {
            runningSettings = nil
            if selected.kind != settings.tunnelProtocol || selected.family != settings.addressFamily && old != status {
                selected = WARPEndpoint.fixtures(for: settings.tunnelProtocol)[0]
            }
        }
        if old != status {
            Diagnostics.record("VPN status=\(statusLabel)", process: "app")
            if connected { message = "隧道已建立，请验证出口" }
            if [.invalid, .disconnected].contains(status) {
                trace = ""
                if foreground { startPreparation() }
            }
        }
    }

    private func startPreparation(force: Bool = false) {
        guard initialized, foreground else { return }
        let kind = selected.kind
        let family = addressFamily
        let configuration = effectiveSettings
        if active {
            do {
                cache = try caches.load(kind, family: family)
                if let cache {
                    apply(cache)
                    if cacheIsFresh { progress = .init(stage: .ready, fraction: 1, title: "连接准备已完成", detail: "节点缓存有效") }
                }
                if !cacheIsFresh { message = "当前 VPN 正在运行，断开后会自动注册并更新节点" }
            } catch { fail(error) }
            return
        }
        if scanning, taskKind == kind, taskFamily == family, taskFingerprint == configuration.measurementFingerprint,
           taskCacheHours == configuration.cacheHours, preparationTask?.isCancelled == false, !force { return }
        if cache?.kind != kind || cache?.addressFamily != family { cache = nil; results = [:]; endpoints = [] }
        let previous = preparationTask
        previous?.cancel()
        let ticket = UUID(); generation = ticket; taskKind = kind; taskFamily = family; taskFingerprint = configuration.measurementFingerprint
        taskCacheHours = configuration.cacheHours
        scanning = true
        progress = .initial
        message = "正在检查 \(kind.label) · \(family.label) 注册与 \(configuration.cacheHours) 小时缓存"
        preparationTask = Task { [self] in
            // The SDK owns process-global state. A protocol switch must await teardown first.
            await previous?.value
            guard generation == ticket else { return }
            if Task.isCancelled { scanning = false; return }
            do {
                let preparation = NodePreparation(accounts: accounts, caches: caches,
                    registration: WARPRegistration(), optimizer: MihomoOptimizer(family: family, settings: configuration), family: family, settings: configuration)
                let ready = try await preparation.prepare(kind: kind, force: force) { [weak self] update in
                    await self?.receive(update, ticket: ticket, kind: kind)
                }
                try Task.checkCancellation()
                guard generation == ticket, selected.kind == kind, addressFamily == family else { return }
                cache = ready.cache
                apply(ready.cache)
                message = ready.reusedCache ? "已使用 \(kind.label) 节点缓存，无需重复注册或优选（\(family.label)）" : "\(kind.label) · \(family.label) 优选完成，节点缓存有效 \(configuration.cacheHours) 小时"
                Diagnostics.record("cache \(ready.reusedCache ? "hit" : "saved") protocol=\(kind.rawValue) family=\(family.rawValue)", process: "app")
            } catch {
                guard generation == ticket else { return }
                if Task.isCancelled || error is CancellationError {
                    message = "已暂停；重新进入应用后会自动继续检查"
                    progress = progress.stopped(failed: false, detail: message)
                }
                else { fail(error) }
            }
            guard generation == ticket else { return }
            scanning = false
            if backgroundTask != .invalid { UIApplication.shared.endBackgroundTask(backgroundTask); backgroundTask = .invalid }
            await refreshDiagnostics()
        }
    }

    private func receive(_ update: PreparationUpdate, ticket: UUID, kind: WARPProtocol) {
        guard generation == ticket, selected.kind == kind else { return }
        switch update {
        case .status(let text): message = text
        case .progress(let value): progress = value; message = value.detail
        case .sample(let result):
            results[result.endpoint.id] = result
            endpoints = results.values.filter { $0.endpoint.kind == kind }.sorted(by: ProbeResult.isBetter).map(\.endpoint)
        }
    }

    private func apply(_ cache: NodeCache) {
        guard cache.kind == selected.kind, cache.addressFamily == addressFamily else { return }
        results = Dictionary(cache.results.map { ($0.endpoint.id, $0) }, uniquingKeysWith: { _, new in new })
        endpoints = cache.results.map(\.endpoint)
        let stored = UserDefaults.standard.string(forKey: choiceKey)
        automaticSelection = stored == nil || stored == "auto"
        if !active {
            if let stored, stored != "auto", let manual = endpoints.first(where: { $0.id == stored }) {
                automaticSelection = false; selected = manual
            } else {
                automaticSelection = true
                if let fastest = ProbeResult.fastest(cache.results) { selected = fastest }
            }
        }
    }

    func enteredForeground() {
        foreground = true
        if backgroundTask != .invalid { UIApplication.shared.endBackgroundTask(backgroundTask); backgroundTask = .invalid }
        startPreparation()
    }
    func enteredBackground() {
        foreground = false
        guard scanning else { return }
        backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "Finish node preparation") { [weak self] in
            Task { @MainActor in self?.preparationTask?.cancel() }
        }
        preparationTask?.cancel()
    }
    func scan() { startPreparation(force: true) }
    func stopScan() { preparationTask?.cancel() }

    func connect() async {
        guard !scanning, !active else { return }
        guard cacheIsFresh else { startPreparation(); return }
        do {
            trace = ""
            let manager = self.manager ?? NETunnelProviderManager()
            let config = NETunnelProviderProtocol()
            config.providerBundleIdentifier = WARPConfiguration.providerID
            config.serverAddress = selected.address
            config.providerConfiguration = ["host": selected.host, "port": selected.port, "kind": selected.kind.rawValue,
                "family": addressFamily.rawValue, "settings": try JSONEncoder().encode(settings)]
            config.disconnectOnSleep = false
            // IPv6 fake-IP uses ULA space; keep it inside the tunnel's default route.
            config.excludeLocalNetworks = settings.doNotSetDNS || (!settings.dnsLeakProtection && addressFamily == .ipv4)
            manager.protocolConfiguration = config
            manager.localizedDescription = "TrashVPN · WARP"
            manager.isEnabled = true
            try await manager.saveToPreferences()
            try await manager.loadFromPreferences()
            self.manager = manager
            try manager.connection.startVPNTunnel()
            message = "正在建立 \(selected.kind.detail) 隧道"
            refreshStatus()
        } catch { fail(error) }
    }

    func disconnect() { manager?.connection.stopVPNTunnel(); trace = ""; message = "正在断开隧道" }

    func verify() async {
        guard connected, !verifying else { return }
        verifying = true; trace = ""; defer { verifying = false }
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
            trace = "WARP 已验证 · \(fields["loc"] ?? "")\n\(addressFamily == .ipv6 ? "IPv6 出口" : "出口 IP")：\(fields["ip"] ?? "")"
                + (addressFamily == .ipv6 ? "\nIPv4 HTTPS 可达 · IPv6 HTTPS 可达" : "")
            message = "\(selected.kind.detail) 数据链路验证成功"
            Diagnostics.record("verification passed protocol=\(selected.kind.rawValue) family=\(addressFamily.rawValue) endpoint=\(selected.address) warp=\(fields["warp"] ?? "") exit=\(fields["ip"] ?? "")", process: "app")
        } catch { trace = "验证失败"; fail(error) }
        await refreshDiagnostics()
    }

    func refreshDiagnostics() async {
        var text = "MTU: \(effectiveSettings.effectiveMTU)\nDNS issued: \(!effectiveSettings.doNotSetDNS)\nDNS protection: \(effectiveSettings.dnsLeakProtection)\nStage: \(progress.stage.rawValue) \(progress.fraction)\nCore: \(ClashVersion())\nVPN: \(statusLabel)\nProtocol: \(selected.kind.rawValue)\nFamily: \(addressFamily.rawValue)\nCache: \(cacheStatus)\n"
        #if DEBUG
        if let encoded = try? JSONEncoder().encode(settings) {
            text += "Settings snapshot: " + String(decoding: encoded, as: UTF8.self) + "\n"
        }
        #endif
        if connected, let session = manager?.connection as? NETunnelProviderSession {
            let reply: Data? = await withCheckedContinuation { continuation in
                do { try session.sendProviderMessage(Data("status".utf8)) { continuation.resume(returning: $0) } }
                catch { continuation.resume(returning: nil) }
            }
            if let reply, let object = try? JSONSerialization.jsonObject(with: reply) as? [String: Any] {
                text += "Provider MTU: \(object["mtu"] ?? "") · DNS issued: \(object["dnsIssued"] ?? "")\n端点：\(object["endpoint"] ?? "")\n上行包：\(object["packetsFromSystem"] ?? 0) · 下行包：\(object["packetsToSystem"] ?? 0)\n内存：\((object["memoryBytes"] as? Int64 ?? 0) / 1024 / 1024) MB\n"
            }
        }
        text += "\n" + Diagnostics.read("app") + "\n" + Diagnostics.read("probe") + "\n" + Diagnostics.read("tunnel")
        diagnostics = text
        try? text.write(to: reportURL, atomically: true, encoding: .utf8)
    }
    var reportURL: URL { FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("WARP-Diagnostics.txt") }
    private func fail(_ error: Error) {
        errorMessage = error.localizedDescription; message = error.localizedDescription
        if scanning { progress = progress.stopped(failed: true, detail: message) }
        Diagnostics.record(error.localizedDescription, process: "app")
    }
}

private final class NoRedirectDelegate: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}
