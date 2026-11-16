import Foundation
import NetworkExtension
import Security
import XCTest
@testable import TrashVPN

@MainActor
final class LegacyUpgradeTests: XCTestCase {
    private final class Environment: LegacyUpgradeEnvironment {
        var state: UpgradeLaunchState?
        var evidence = LegacyUpgradeEvidence()
        var events: [String] = []
        var failAt: String?
        var erase: (() throws -> Void)?
        func loadState() throws -> UpgradeLaunchState? { state }
        func saveState(_ value: UpgradeLaunchState) throws {
            let event = value.cleanupPending ? "pending" : "commit"
            events.append(event)
            if failAt == event { throw UpgradeResetError.invalidJournal }
            state = value
        }
        func inspect() async throws -> LegacyUpgradeEvidence { events.append("inspect"); return evidence }
        func stopAndRemoveVPN() async throws {
            events.append("stop")
            if failAt == "stop" { throw UpgradeResetError.vpnStillRunning }
        }
        func eraseLocalData() async throws {
            events.append("erase"); try erase?()
            if failAt == "erase" { throw UpgradeResetError.invalidJournal }
        }
    }
    func testBuild10009UpgradeJournalsBeforeStoppingAndWiping() async throws {
        let env = Environment(); env.state = .init(lastBuild: 10009)
        let didReset1 = try await LegacyUpgradeMigration.run(currentBuild: 10024, environment: env)
        XCTAssertTrue(didReset1)
        XCTAssertEqual(env.events, ["pending", "stop", "erase", "commit"])
        XCTAssertEqual(env.state, .init(lastBuild: 10024))
    }
    func testEarlierBuildAlsoResetsBut10010AndLaterNeverReset() async throws {
        for build in [1, 10000, 10008] {
            let env = Environment(); env.state = .init(lastBuild: build)
            let didReset2 = try await LegacyUpgradeMigration.run(currentBuild: 10024, environment: env)
            XCTAssertTrue(didReset2)
        }
        for build in [10010, 10023, 10024, 10025] {
            let env = Environment(); env.state = .init(lastBuild: build); env.evidence.legacyData = true
            let didReset3 = try await LegacyUpgradeMigration.run(currentBuild: 10026, environment: env)
            XCTAssertFalse(didReset3)
            XCTAssertEqual(env.events, ["commit"])
        }
    }
    func testUnrecordedLegacyInstallationResetsButExistingWARPDataIsProtected() async throws {
        let legacy = Environment(); legacy.evidence.legacyData = true
        let didReset4 = try await LegacyUpgradeMigration.run(currentBuild: 10024, environment: legacy)
        XCTAssertTrue(didReset4)
        let modern = Environment(); modern.evidence = .init(modernData: true, legacyData: true)
        let didReset5 = try await LegacyUpgradeMigration.run(currentBuild: 10024, environment: modern)
        XCTAssertFalse(didReset5)
        XCTAssertEqual(modern.events, ["inspect", "commit"])
        let fresh = Environment()
        let didReset6 = try await LegacyUpgradeMigration.run(currentBuild: 10024, environment: fresh)
        XCTAssertFalse(didReset6)
        XCTAssertEqual(fresh.events, ["inspect", "commit"])
    }
    func testFailureToStopDoesNotTouchDataAndIsRetried() async throws {
        let env = Environment(); env.state = .init(lastBuild: 10009); env.failAt = "stop"
        do { try await LegacyUpgradeMigration.run(currentBuild: 10024, environment: env); XCTFail("must stop startup") } catch {}
        XCTAssertEqual(env.events, ["pending", "stop"])
        XCTAssertEqual(env.state?.cleanupPending, true)
        env.failAt = nil; env.events = []
        let didReset7 = try await LegacyUpgradeMigration.run(currentBuild: 10024, environment: env)
        XCTAssertTrue(didReset7)
        XCTAssertEqual(env.events, ["pending", "stop", "erase", "commit"])
    }
    func testPartialWipeOrCommitFailureCannotBeMistakenForFreshInstall() async throws {
        for failure in ["erase", "commit"] {
            let env = Environment(); env.evidence.legacyData = true; env.failAt = failure
            do { try await LegacyUpgradeMigration.run(currentBuild: 10024, environment: env); XCTFail("must stop startup") } catch {}
            XCTAssertEqual(env.state?.cleanupPending, true)
            env.evidence = .init(); env.failAt = nil; env.events = []
            let didReset8 = try await LegacyUpgradeMigration.run(currentBuild: 10025, environment: env)
            XCTAssertTrue(didReset8)
            XCTAssertEqual(env.events, ["pending", "stop", "erase", "commit"])
            env.events = []
            let didReset9 = try await LegacyUpgradeMigration.run(currentBuild: 10026, environment: env)
            XCTAssertFalse(didReset9)
            XCTAssertEqual(env.events, ["commit"])
        }
    }
    func testInvalidJournalDoesNotAuthorizeDeletion() async throws {
        let env = Environment(); env.state = .init(lastBuild: 0)
        do { try await LegacyUpgradeMigration.run(currentBuild: 10024, environment: env); XCTFail("must reject journal") } catch {}
        XCTAssertTrue(env.events.isEmpty)
    }
    func testFreshInstallWithSharedRemnantsDoesNotEraseAnything() async throws {
        let env = Environment(); env.evidence = .init(legacyRemnants: true)
        let reset = try await LegacyUpgradeMigration.run(currentBuild: 10025, environment: env)
        XCTAssertFalse(reset)
        XCTAssertEqual(env.events, ["inspect", "commit"])
        XCTAssertEqual(env.state, .init(lastBuild: 10025))
    }
    func testUnproven10024PendingJournalIsCancelledOnFreshInstall() async throws {
        let env = Environment()
        env.state = try JSONDecoder().decode(UpgradeLaunchState.self, from: Data(#"{"schema":1,"lastBuild":10009,"cleanupPending":true}"#.utf8))
        let reset = try await LegacyUpgradeMigration.run(currentBuild: 10025, environment: env)
        XCTAssertFalse(reset)
        XCTAssertEqual(env.events, ["inspect", "commit"])
        XCTAssertEqual(env.state?.cleanupPending, false)
    }
    func test10024PendingJournalWithRealLegacyFilesContinuesCleanup() async throws {
        let env = Environment(); env.evidence.legacyRemnants = true
        env.state = try JSONDecoder().decode(UpgradeLaunchState.self, from: Data(#"{"schema":1,"lastBuild":10009,"cleanupPending":true}"#.utf8))
        let reset = try await LegacyUpgradeMigration.run(currentBuild: 10025, environment: env)
        XCTAssertTrue(reset)
        XCTAssertEqual(env.events, ["inspect", "pending", "stop", "erase", "commit"])
    }
    func testCleanupDeletesAllOwnedStoresButPreservesJournalMetadataAndExternalSymlinkTargets() throws {
        let fm = FileManager.default, root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? fm.removeItem(at: root) }
        func directory(_ name: String) throws -> URL {
            let url = root.appendingPathComponent(name); try fm.createDirectory(at: url, withIntermediateDirectories: true); return url
        }
        let group = try directory("group"), docs = try directory("documents"), library = try directory("library"), temp = try directory("tmp"), outside = try directory("unrelated")
        let files = UpgradeDataFiles(group: group, documents: docs, library: library, temporary: temp)
        for name in ["SecureStore", "ConnectionTimeQuota", "Working", "RouteData"] { _ = try directory("group/" + name) }
        XCTAssertFalse(files.hasLegacyData, "Empty directories do not prove an old installation")
        try Data("legacy".utf8).write(to: group.appendingPathComponent("SecureStore/settings.secure"))
        XCTAssertTrue(files.hasLegacyData); XCTAssertFalse(files.hasModernData)
        let cache = try directory("group/node-cache")
        try Data("private".utf8).write(to: cache.appendingPathComponent("node.json"))
        XCTAssertTrue(files.hasModernData)
        let sentinel = outside.appendingPathComponent("keep"); try Data("unrelated".utf8).write(to: sentinel)
        try fm.createSymbolicLink(at: docs.appendingPathComponent("link"), withDestinationURL: outside)
        try Data([1]).write(to: library.appendingPathComponent("ad-cache"))
        let caches = try directory("library/Caches"), preferences = try directory("library/Preferences")
        try Data("old ads".utf8).write(to: caches.appendingPathComponent("ads.dat"))
        try Data("old prefs".utf8).write(to: preferences.appendingPathComponent("old.plist"))
        try Data([2]).write(to: temp.appendingPathComponent("old-log"))
        let metadata = group.appendingPathComponent(".com.apple.mobile_container_manager.metadata.plist")
        try Data([3]).write(to: metadata)
        let pending = UpgradeLaunchState(lastBuild: 10009, cleanupPending: true)
        try files.saveState(pending); try files.erase()
        XCTAssertEqual(try files.loadState(), pending)
        XCTAssertEqual(try Data(contentsOf: sentinel), Data("unrelated".utf8))
        XCTAssertTrue(fm.fileExists(atPath: metadata.path))
        for url in [docs, temp, caches, preferences] { XCTAssertTrue(try fm.contentsOfDirectory(atPath: url.path).isEmpty) }
        XCTAssertTrue(fm.fileExists(atPath: caches.path), "iOS owns the cache directory itself")
        XCTAssertTrue(fm.fileExists(atPath: preferences.path))
        XCTAssertFalse(files.hasLegacyData); XCTAssertFalse(files.hasModernData)
    }
    func testJournalSymlinkCannotWriteOutsideTheContainer() throws {
        let fm = FileManager.default, root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let outside = root.appendingPathComponent("outside")
        try Data("keep".utf8).write(to: outside)
        let group = root.appendingPathComponent("group"); try fm.createDirectory(at: group, withIntermediateDirectories: true)
        try fm.createSymbolicLink(at: group.appendingPathComponent(UpgradeDataFiles.journalName), withDestinationURL: outside)
        let files = UpgradeDataFiles(group: group, documents: root, library: root, temporary: root)
        XCTAssertThrowsError(try files.saveState(.init(lastBuild: 10024)))
        XCTAssertThrowsError(try files.loadState())
        XCTAssertEqual(try String(contentsOf: outside), "keep")
    }
    func testOnlyPermissionErrorsInSystemManagedStoresMayBeSkipped() {
        let root = URL(fileURLWithPath: "/isolated")
        let files = UpgradeDataFiles(group: root.appendingPathComponent("group"), documents: root.appendingPathComponent("docs"),
            library: root.appendingPathComponent("library"), temporary: root.appendingPathComponent("tmp"))
        let denied = CocoaError(.fileWriteNoPermission)
        XCTAssertTrue(files.isProtectedSystemEntry(root.appendingPathComponent("library/Caches/system.db"), error: denied))
        XCTAssertTrue(files.isProtectedSystemEntry(root.appendingPathComponent("library/Caches"), error: denied))
        XCTAssertFalse(files.isProtectedSystemEntry(root.appendingPathComponent("library/Caches2/private.db"), error: denied))
        XCTAssertFalse(files.isProtectedSystemEntry(root.appendingPathComponent("group/SecureStore/settings.secure"), error: denied))
        XCTAssertFalse(files.isProtectedSystemEntry(root.appendingPathComponent("docs/private"), error: denied))
        XCTAssertFalse(files.isProtectedSystemEntry(root.appendingPathComponent("library/Caches"), error: CocoaError(.fileWriteOutOfSpace)))
    }
    func testOnlyOurVPNProviderAndExplicitKeychainGroupsAreEligible() {
        for provider in [WARPConfiguration.providerID, "com.unrelated.VPN", ""] {
            let manager = NETunnelProviderManager(), proto = NETunnelProviderProtocol()
            proto.providerBundleIdentifier = provider; manager.protocolConfiguration = proto
            XCTAssertEqual(InstalledUpgradeEnvironment.owns(manager), provider == WARPConfiguration.providerID)
        }
        for itemClass in InstalledUpgradeEnvironment.itemClasses {
            let query = InstalledUpgradeEnvironment.keychainQuery(itemClass: itemClass, group: "TEAM.com.leo.TrashVPN")
            XCTAssertEqual(query[kSecAttrAccessGroup as String] as? String, "TEAM.com.leo.TrashVPN")
            XCTAssertEqual(Set(query.keys), Set([kSecClass as String, kSecAttrAccessGroup as String]))
        }
    }
    func testSignedGroupsAllowScopedQueriesWithoutReadingOrDeletingValues() throws {
        let legacy = try XCTUnwrap(Bundle.main.object(forInfoDictionaryKey: "WARPLegacyKeychainGroup") as? String)
        let shared = try XCTUnwrap(Bundle.main.object(forInfoDictionaryKey: "WARPKeychainGroup") as? String)
        for group in [legacy, shared, WARPConfiguration.group] {
            for itemClass in InstalledUpgradeEnvironment.itemClasses {
                var query = InstalledUpgradeEnvironment.keychainQuery(itemClass: itemClass, group: group)
                query[kSecMatchLimit as String] = kSecMatchLimitOne
                let status = SecItemCopyMatching(query as CFDictionary, nil)
                XCTAssertTrue(status == errSecSuccess || status == errSecItemNotFound, "Scoped keychain query returned \(status)")
            }
        }
    }
}
