import Foundation
import Security

struct UpgradeLaunchState: Codable, Equatable {
    enum CleanupOrigin: String, Codable { case recordedBuild, legacyContainer }
    let schema: Int
    let lastBuild: Int
    let cleanupPending: Bool
    let cleanupOrigin: CleanupOrigin?
    init(lastBuild: Int, cleanupPending: Bool = false, cleanupOrigin: CleanupOrigin? = nil) {
        schema = 2; self.lastBuild = lastBuild; self.cleanupPending = cleanupPending; self.cleanupOrigin = cleanupOrigin
    }
}

struct LegacyUpgradeEvidence {
    var modernData = false
    var legacyData = false
    var legacyRemnants = false
}

@MainActor
protocol LegacyUpgradeEnvironment {
    func loadState() throws -> UpgradeLaunchState?
    func saveState(_ state: UpgradeLaunchState) throws
    func inspect() async throws -> LegacyUpgradeEvidence
    func stopAndRemoveVPN() async throws
    func eraseLocalData() async throws
}

enum LegacyUpgradeMigration {
    static let lastLegacyBuild = 10009

    /// A pending journal survives every cleanup step. New data may only be created after commit.
    @MainActor
    @discardableResult
    static func run(currentBuild: Int, environment: any LegacyUpgradeEnvironment) async throws -> Bool {
        guard currentBuild > lastLegacyBuild else { return false }
        let saved = try environment.loadState()
        if let saved, ![1, 2].contains(saved.schema) || saved.lastBuild <= 0 { throw UpgradeResetError.invalidJournal }
        let reset: Bool
        let origin: UpgradeLaunchState.CleanupOrigin?
        if let saved, saved.cleanupPending {
            if let confirmed = saved.cleanupOrigin {
                reset = true; origin = confirmed
            } else {
                // 10024 could infer an upgrade from unrelated keychain entries. Its pending
                // journal is not authorization to erase a fresh installation.
                let evidence = try await environment.inspect()
                reset = evidence.legacyData || evidence.legacyRemnants
                origin = reset ? .legacyContainer : nil
            }
        } else if let saved {
            reset = saved.lastBuild <= lastLegacyBuild
            origin = reset ? .recordedBuild : nil
        } else {
            // An in-place update retains the old app's own container. Keychain and shared
            // container remnants may survive uninstall and cannot establish an upgrade.
            let evidence = try await environment.inspect()
            reset = evidence.legacyData && !evidence.modernData
            origin = reset ? .legacyContainer : nil
        }
        if reset {
            try environment.saveState(.init(lastBuild: saved?.lastBuild ?? lastLegacyBuild, cleanupPending: true, cleanupOrigin: origin))
            try await environment.stopAndRemoveVPN()
            try await environment.eraseLocalData()
        }
        try environment.saveState(.init(lastBuild: currentBuild))
        return reset
    }
}

enum UpgradeResetError: Error {
    case invalidJournal, invalidKeychainGroup, unsafeJournal, vpnStillRunning, protectedDataUnavailable, keychain(OSStatus)
}

/// Deletes contents of app-owned data roots, retaining only the durable migration journal and
/// Apple's container metadata. Removing child symlinks removes the link, not its destination.
struct UpgradeDataFiles {
    static let journalName = ".warp-upgrade-state-v1.json"
    let group: URL
    let documents: URL
    let library: URL
    let temporary: URL
    private var journal: URL { group.appendingPathComponent(Self.journalName) }

    func loadState() throws -> UpgradeLaunchState? {
        guard FileManager.default.fileExists(atPath: journal.path) else { return nil }
        try checkJournal()
        return try JSONDecoder().decode(UpgradeLaunchState.self, from: Data(contentsOf: journal))
    }
    func saveState(_ state: UpgradeLaunchState) throws {
        try checkJournal()
        try JSONEncoder().encode(state).write(to: journal, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }
    private func checkJournal() throws {
        if (try? FileManager.default.destinationOfSymbolicLink(atPath: journal.path)) != nil { throw UpgradeResetError.unsafeJournal }
    }
    var hasModernData: Bool {
        if ["settings.json", "network-preferences.json", "active-tunnel.json"].contains(where: { hasData(group.appendingPathComponent($0)) }) { return true }
        return ["node-cache", "optimization-checkpoints"].contains { name in
            ((try? FileManager.default.contentsOfDirectory(at: group.appendingPathComponent(name), includingPropertiesForKeys: nil)) ?? [])
                .contains { $0.pathExtension == "json" && hasData($0) }
        }
    }
    var hasLegacyData: Bool {
        legacyPayload(in: group) || hasLegacyContainerData
    }
    var hasLegacyContainerData: Bool { legacyPayload(in: library.appendingPathComponent("Application Support/TrshVPNShared")) }
    private func hasData(_ url: URL) -> Bool {
        guard let value = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]) else { return false }
        return value.isRegularFile == true && (value.fileSize ?? 0) > 0
    }
    private func legacyPayload(in root: URL) -> Bool {
        let names = ["node-snapshot", "server-directory", "selection", "settings", "latencies", "account-usage-monitor", "app-runtime-state", "ad-config-cache"]
        return names.contains { hasData(root.appendingPathComponent("SecureStore/\($0).secure")) }
            || hasData(root.appendingPathComponent("ConnectionTimeQuota/vpn-time-quota-v1.json"))
    }
    func erase() throws {
        for root in [documents, library, temporary, group] {
            guard FileManager.default.fileExists(atPath: root.path) else { continue }
            guard (try root.resourceValues(forKeys: [.isSymbolicLinkKey])).isSymbolicLink != true else { throw UpgradeResetError.unsafeJournal }
            try eraseContents(root)
        }
    }
    private func eraseContents(_ root: URL) throws {
        let children: [URL]
        do { children = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey]) }
        catch {
            guard isProtectedSystemEntry(root, error: error) else { throw error }
            return
        }
        for child in children {
            if root == group && child.lastPathComponent == ".com.apple.mobile_container_manager.metadata.plist" { continue }
            if root == group && child.lastPathComponent == Self.journalName { continue }
            do {
                let values = try child.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                if values.isDirectory == true && values.isSymbolicLink != true {
                // iOS protects directories such as Library/Caches from removal even
                // inside our sandbox. Clear their contents and retain the containers.
                    try eraseContents(child)
                } else { try FileManager.default.removeItem(at: child) }
            } catch {
                guard isProtectedSystemEntry(child, error: error) else { throw error }
            }
        }
    }
    func isProtectedSystemEntry(_ url: URL, error: Error) -> Bool {
        let e = error as NSError
        let denied = e.domain == NSCocoaErrorDomain && [NSFileReadNoPermissionError, NSFileWriteNoPermissionError].contains(e.code)
            || e.domain == NSPOSIXErrorDomain && [1, 13].contains(e.code)
        guard denied else { return false }
        let roots = ["Caches", "Preferences", "SplashBoard", "Cookies", "WebKit", "HTTPStorages"].map { library.appendingPathComponent($0) }
            + [group.appendingPathComponent("Library/Caches"), group.appendingPathComponent("Library/Preferences")]
        let path = url.standardizedFileURL.path
        return roots.contains { path == $0.standardizedFileURL.path || path.hasPrefix($0.standardizedFileURL.path + "/") }
    }
}
