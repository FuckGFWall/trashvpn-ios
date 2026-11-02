import Clash
import Darwin
import Foundation

final class CorePlatform: NSObject, ClashPlatformInterfaceProtocol {
    let isExtension: Bool
    var openTunnel: ((any ClashTunOptionsProtocol) throws -> Int32)?
    var failure: ((String) -> Void)?
    private let monitor = ApplePhysicalPathMonitor()
    private let pathQueue = DispatchQueue(label: "com.leo.TrashVPN.physical-path")
    private let lock = NSLock()
    private var path: PhysicalPathSnapshot?
    private var listener: (any ClashInterfaceUpdateListenerProtocol)?
    private let ready = DispatchSemaphore(value: 0)
    private var process: String { isExtension ? "tunnel" : "probe" }

    init(isExtension: Bool) { self.isExtension = isExtension; super.init() }

    func prepare(family: IPAddressFamily = .ipv4) throws {
        monitor.updateHandler = { [weak self] snapshot in
            guard let self else { return }
            lock.lock(); path = snapshot; let current = listener; lock.unlock()
            publish(snapshot, to: current)
            if snapshot.isReady { ready.signal() }
            Diagnostics.record("physical path \(snapshot.interfaceName), ready=\(snapshot.isReady), ipv4=\(snapshot.supportsIPv4), ipv6=\(snapshot.supportsIPv6)", process: process)
        }
        monitor.start(queue: pathQueue)
        guard ready.wait(timeout: .now() + 8) == .success else {
            monitor.cancel()
            throw WARPError.message("未找到可用的 Wi-Fi 或蜂窝网络。")
        }
        lock.lock(); let supportsIPv6 = path?.supportsIPv6 == true; lock.unlock()
        if family == .ipv6 && !supportsIPv6 {
            monitor.cancel()
            throw WARPError.message("当前 Wi-Fi 或蜂窝网络未提供 IPv6，请切换网络或使用 IPv4。")
        }
    }

    func shutdown() { monitor.cancel(); lock.lock(); listener = nil; lock.unlock() }

    private func publish(_ path: PhysicalPathSnapshot, to listener: (any ClashInterfaceUpdateListenerProtocol)?) {
        listener?.updateDefaultInterface(path.interfaceName, interfaceIndex: Int32(bitPattern: path.interfaceIndex),
            isExpensive: path.expensive, isConstrained: path.constrained,
            supportsIPv4: path.supportsIPv4, supportsIPv6: path.supportsIPv6)
    }

    func openTun(_ options: (any ClashTunOptionsProtocol)?, ret0_: UnsafeMutablePointer<Int32>?) throws {
        guard isExtension, let options, let ret0_, let openTunnel else {
            throw WARPError.message("前台筛选禁止创建 TUN。")
        }
        ret0_.pointee = try openTunnel(options)
    }
    func underNetworkExtension() -> Bool { isExtension }
    func usePlatformAutoDetectControl() -> Bool { isExtension }
    func autoDetectControl(_ fd: Int32) throws {
        lock.lock(); let index = path?.interfaceIndex ?? 0; lock.unlock()
        guard index != 0 else { throw WARPError.message("物理网络暂不可用。") }
        try PhysicalEgressBinding.apply(.bound(index: index), to: fd)
    }
    func startDefaultInterfaceMonitor(_ listener: (any ClashInterfaceUpdateListenerProtocol)?) throws {
        lock.lock(); self.listener = listener; let current = path; lock.unlock()
        guard let current, current.isReady else { throw WARPError.message("物理网络暂不可用。") }
        publish(current, to: listener)
    }
    func closeDefaultInterfaceMonitor(_ listener: (any ClashInterfaceUpdateListenerProtocol)?) throws {
        lock.lock(); self.listener = nil; lock.unlock()
    }
    func getInterfaces() throws -> any ClashNetworkInterfaceIteratorProtocol {
        lock.lock(); let current = path; lock.unlock()
        let records = PhysicalInterfaceInventory.build(raw: PhysicalInterfaceInventory.enumerate(),
            available: current?.availableInterfaces ?? [], pathIsExpensive: current?.expensive ?? false,
            defaultInterfaceIndex: current?.interfaceIndex ?? 0, ownTunnelAddresses: ["198.18.0.1", "fdfe:dcba:9876::1"])
        return CoreInterfaceIterator(records.map { record in
            let item = ClashNetworkInterface()
            item.name = record.name; item.index = Int32(bitPattern: record.index)
            item.mtu = record.mtu; item.flags = record.flags.rawValue
            item.type = record.type.rawValue; item.metered = record.metered
            item.addresses = CoreStringIterator(record.addresses)
            return item
        })
    }
    func tunFailed(_ reason: String?) { failure?(reason ?? "内核 TUN 故障") }
    func writeLog(_ message: String?) {
        guard let message else { return }
        Diagnostics.record(message, process: process)
    }
}

final class CoreStringIterator: NSObject, ClashStringIteratorProtocol {
    private let values: [String]
    private var index = 0
    init(_ values: [String]) { self.values = values }
    func hasNext() -> Bool { index < values.count }
    func len() -> Int32 { Int32(values.count) }
    func next() -> String { guard hasNext() else { return "" }; defer { index += 1 }; return values[index] }
}

final class CoreInterfaceIterator: NSObject, ClashNetworkInterfaceIteratorProtocol {
    private let values: [ClashNetworkInterface]
    private var index = 0
    init(_ values: [ClashNetworkInterface]) { self.values = values }
    func hasNext() -> Bool { index < values.count }
    func len() -> Int32 { Int32(values.count) }
    func next() -> ClashNetworkInterface? { guard hasNext() else { return nil }; defer { index += 1 }; return values[index] }
}

enum CoreRuntime {
    static func setup(isExtension: Bool, family: IPAddressFamily = .ipv4, mtu: Int = 1280) throws {
        // Darwin sockaddr_un.sun_path allows only 103 bytes including this directory.
        let directory = try WARPConfiguration.container().appendingPathComponent(isExtension ? "t" : "p")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
            attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
        let options = ClashSetupOptions()
        options.basePath = directory.path
        options.workingPath = directory.appendingPathComponent("working").path
        options.tempPath = directory.appendingPathComponent("temp").path
        options.timeZone = TimeZone.current.identifier
        options.runtimeProfile = "iosPacketTunnel"
        options.logMaxLines = 100
        // The SDK reserves DisablePersistentCache for parser-only application use.
        // NewService requires a writable per-process working directory.
        options.disablePersistentCache = false
        options.memoryLimit = (isExtension ? 45 : 192) * 1024 * 1024
        options.memoryPressureShed = isExtension
        options.maxProcs = 2
        options.tunMTU = mtu
        options.ipQueryMode = family.queryMode
        options.tunIPv6Mode = "enabled"
        options.systemDNSServerLines = ClashSystemResolverLines()
        guard directory.appendingPathComponent("clash.sock").path.utf8.count <= 103 else {
            throw WARPError.message("内核控制接口路径过长。")
        }
        var error: NSError?
        guard ClashSetup(options, &error) else { throw error ?? WARPError.message("内核初始化失败") }
    }
}
