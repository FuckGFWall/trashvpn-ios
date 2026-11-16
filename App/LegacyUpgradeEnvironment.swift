import Foundation
import NetworkExtension
import Security
import UIKit
import UserNotifications

@MainActor
final class InstalledUpgradeEnvironment: LegacyUpgradeEnvironment {
    private let files: UpgradeDataFiles
    private let defaults = UserDefaults.standard
    private let groupDefaults: UserDefaults
    private let groups: [String]
    private var managers: [NETunnelProviderManager]?
    private static let bundleID = "com.leo.TrashVPN"

    init() throws {
        let fm = FileManager.default
        files = UpgradeDataFiles(group: try WARPConfiguration.container(),
            documents: fm.urls(for: .documentDirectory, in: .userDomainMask)[0],
            library: fm.urls(for: .libraryDirectory, in: .userDomainMask)[0], temporary: fm.temporaryDirectory)
        guard let shared = Bundle.main.object(forInfoDictionaryKey: "WARPKeychainGroup") as? String,
              let legacy = Bundle.main.object(forInfoDictionaryKey: "WARPLegacyKeychainGroup") as? String,
              shared.hasSuffix(".com.leo.TrashVPN.shared"), legacy.hasSuffix(".com.leo.TrashVPN"),
              !shared.contains("$("), !legacy.contains("$("),
              let groupDefaults = UserDefaults(suiteName: WARPConfiguration.group) else { throw UpgradeResetError.invalidKeychainGroup }
        groups = [legacy, shared, WARPConfiguration.group]
        self.groupDefaults = groupDefaults
    }
    func loadState() throws -> UpgradeLaunchState? { try files.loadState() }
    func saveState(_ state: UpgradeLaunchState) throws { try files.saveState(state) }

    func inspect() async throws -> LegacyUpgradeEvidence {
        let keys = ["com.leo.TrashVPN.terms.accepted.v1", "com.leo.TrashVPN.first-run-guide.eligible.v1",
            "com.leo.TrashVPN.first-run-guide.completed.v1", "cached-node-count-hint", "ad_cache.last_launch_maintenance_at"]
        let domain = defaults.persistentDomain(forName: Self.bundleID) ?? [:]
        // No keychain or Network Extension probe on first launch. Those records can survive
        // uninstall, contain system-created items, or be unavailable before authorization.
        return .init(modernData: files.hasModernData,
            legacyData: files.hasLegacyContainerData || keys.contains(where: { domain[$0] != nil }),
            legacyRemnants: files.hasLegacyData)
    }

    private func ownedManagers() async throws -> [NETunnelProviderManager] {
        if let managers { return managers }
        #if targetEnvironment(simulator)
        let loaded: [NETunnelProviderManager] = []
        #else
        let loaded = try await NETunnelProviderManager.loadAllFromPreferences().filter(Self.owns)
        #endif
        managers = loaded; return loaded
    }
    static func owns(_ profile: NETunnelProviderManager) -> Bool {
        (profile.protocolConfiguration as? NETunnelProviderProtocol)?.providerBundleIdentifier == WARPConfiguration.providerID
    }
    func stopAndRemoveVPN() async throws {
        for profile in try await ownedManagers() {
            profile.isOnDemandEnabled = false; profile.onDemandRules = nil; profile.isEnabled = false
            try await profile.saveToPreferences()
            profile.connection.stopVPNTunnel()
            let deadline = ContinuousClock.now.advanced(by: .seconds(20))
            while [.connecting, .connected, .reasserting, .disconnecting].contains(profile.connection.status) {
                guard ContinuousClock.now < deadline else { throw UpgradeResetError.vpnStillRunning }
                try await Task.sleep(for: .milliseconds(100))
            }
            try await profile.removeFromPreferences()
        }
    }

    static let itemClasses: [CFString] = [kSecClassGenericPassword, kSecClassInternetPassword, kSecClassKey, kSecClassCertificate]
    static func keychainQuery(itemClass: CFString, group: String) -> [String: Any] {
        [kSecClass as String: itemClass, kSecAttrAccessGroup as String: group]
    }
    func eraseLocalData() async throws {
        guard UIApplication.shared.isProtectedDataAvailable else { throw UpgradeResetError.protectedDataUnavailable }
        // Never issue an unscoped keychain delete: these groups belong exclusively to this app.
        for group in groups {
            for itemClass in Self.itemClasses {
                let status = SecItemDelete(Self.keychainQuery(itemClass: itemClass, group: group) as CFDictionary)
                guard status == errSecSuccess || status == errSecItemNotFound else { throw UpgradeResetError.keychain(status) }
            }
        }
        defaults.removePersistentDomain(forName: Self.bundleID)
        groupDefaults.removePersistentDomain(forName: WARPConfiguration.group)
        defaults.synchronize(); groupDefaults.synchronize()
        URLCache.shared.removeAllCachedResponses()
        HTTPCookieStorage.shared.removeCookies(since: .distantPast)
        UNUserNotificationCenter.current().removeAllPendingNotificationRequests()
        UNUserNotificationCenter.current().removeAllDeliveredNotifications()
        UIApplication.shared.applicationIconBadgeNumber = 0
        try files.erase()
    }
}
