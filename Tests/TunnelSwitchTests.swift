import Clash
import Darwin
import Foundation
import XCTest
@testable import TrashVPN

final class TunnelSwitchTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_790_000_000)
    private var settings: UserSettings { var s = UserSettings(); s.strength = .low; s.downloadTestEnabled = false; return s }
    private func account(_ kind: WARPProtocol = .wg) -> WARPAccount {
        var account = WARPAccount.make(kind: kind)
        account.id = "switch-test"; account.token = "mock"; account.ipv4 = "172.16.0.2"
        account.ipv6 = WARPConfiguration.masqueIPv6
        account.peerPublicKey = kind == .masque ? WARPConfiguration.masquePeerPEM : WARPConfiguration.peerKey
        account.state = .registered
        return account
    }
    private func cache(_ account: WARPAccount, settings: UserSettings? = nil) throws -> NodeCache {
        let s = (settings ?? self.settings).forProtocol(account.kind)
        let results = WARPEndpoint.fixtures(for: account.kind).prefix(2).enumerated().map { i, node in
            ProbeResult(endpoint: node, samples: Array(repeating: Int32(200 - i * 100), count: s.strength.minimumRounds), testedAt: now,
                downloadMbps: [], googleSuccesses: s.strength.minimumRounds / 2, qualityVersion: 3, qualityProfile: s.qualityProfile)
        }
        return try NodeCache(account: account, results: results, now: now, settings: s)
    }
    private func state() -> ActiveTunnelState {
        ActiveTunnelState(sessionID: UUID(), startedAt: now, endpoint: WARPEndpoint.fixtures[0], settings: settings, automatic: true)
    }
    func testCachedTargetsRequireCorrectIdentityFamilyPolicyAndUnexpiredCache() throws {
        let accounts = MemoryAccounts(), caches = MemoryCaches(), identity = account()
        try accounts.save(identity); try caches.save(cache(identity))
        XCTAssertNotNil(try CachedTunnelTarget.load(kind: .wg, running: settings, latest: settings, accounts: accounts, caches: caches, now: now))
        XCTAssertNil(try CachedTunnelTarget.load(kind: .awg, running: settings, latest: settings, accounts: accounts, caches: caches, now: now))
        XCTAssertNil(try CachedTunnelTarget.load(kind: .wg, running: settings, latest: settings, accounts: accounts, caches: caches, now: now.addingTimeInterval(21600)))
        var v6 = settings; v6.addressFamily = .ipv6
        XCTAssertNil(try CachedTunnelTarget.load(kind: .wg, running: v6, latest: v6, accounts: accounts, caches: caches, now: now))
        var rotated = identity; rotated.id = "rotated"; try accounts.save(rotated)
        XCTAssertNil(try CachedTunnelTarget.load(kind: .wg, running: settings, latest: settings, accounts: accounts, caches: caches, now: now))
    }
    func testHotSwitchUsesRunningNetworkSnapshotAndLatestCacheLifetime() throws {
        let accounts = MemoryAccounts(), caches = MemoryCaches(), identity = account(.awg)
        try accounts.save(identity); try caches.save(cache(identity))
        var latest = settings; latest.mtu = 1400; latest.customDNS = "8.8.8.8"; latest.addressFamily = .ipv6
        XCTAssertNotNil(try CachedTunnelTarget.load(kind: .awg, running: settings, latest: latest, accounts: accounts, caches: caches, now: now))
        latest.cacheHours = 0
        XCTAssertNotNil(try CachedTunnelTarget.load(kind: .awg, running: settings, latest: latest, accounts: accounts, caches: caches, now: now.addingTimeInterval(100 * 86400)))
    }
    func testCachedProtocolRestoresManualChoiceOrFastestAutomaticNode() throws {
        let cache = try cache(account())
        let fastest = try XCTUnwrap(ProbeResult.fastest(cache.results))
        XCTAssertEqual(CachedNodeChoice.resolve(cache, stored: "auto"), CachedNodeChoice(endpoint: fastest, automatic: true))
        XCTAssertEqual(CachedNodeChoice.resolve(cache, stored: "missing")?.endpoint, fastest)
        let manual = cache.results.last!.endpoint
        XCTAssertEqual(CachedNodeChoice.resolve(cache, stored: manual.id), CachedNodeChoice(endpoint: manual, automatic: false))
    }
    func testRequestRejectsOtherSessionsStaleRevisionsAndAddressFamilies() throws {
        let state = state(), id = UUID()
        XCTAssertNoThrow(try TunnelSwitchRequest(id: id, sessionID: state.sessionID, expectedRevision: 0, endpoint: WARPEndpoint.fixtures[1], automatic: false).validate(current: state))
        XCTAssertThrowsError(try TunnelSwitchRequest(id: id, sessionID: UUID(), expectedRevision: 0, endpoint: state.endpoint, automatic: false).validate(current: state))
        XCTAssertThrowsError(try TunnelSwitchRequest(id: id, sessionID: state.sessionID, expectedRevision: 1, endpoint: state.endpoint, automatic: false).validate(current: state))
        XCTAssertThrowsError(try TunnelSwitchRequest(id: id, sessionID: state.sessionID, expectedRevision: 0, endpoint: WARPEndpoint(host: "2606:4700:d0::1", port: 2408), automatic: false).validate(current: state))
    }
    func testCompletedRequestIsIdempotentButCannotReuseAnIDForAnotherNode() throws {
        let original = state(), id = UUID(), endpoint = WARPEndpoint.fixtures[1]
        let next = original.selecting(endpoint, automatic: false, requestID: id, settings: settings)
        XCTAssertEqual(next.sessionID, original.sessionID); XCTAssertEqual(next.startedAt, original.startedAt)
        XCTAssertEqual(next.revision, 1); XCTAssertEqual(next.tunOpenCount, 1)
        XCTAssertNoThrow(try TunnelSwitchRequest(id: id, sessionID: next.sessionID, expectedRevision: 0, endpoint: endpoint, automatic: false).validate(current: next))
        XCTAssertThrowsError(try TunnelSwitchRequest(id: id, sessionID: next.sessionID, expectedRevision: 0, endpoint: original.endpoint, automatic: false).validate(current: next))
    }
    func testLostAcknowledgementMustMatchRequestNodeModeAndSession() {
        let original = state(), id = UUID(), endpoint = WARPEndpoint.fixtures[1]
        let request = TunnelSwitchRequest(id: id, sessionID: original.sessionID, expectedRevision: 0, endpoint: endpoint, automatic: false)
        let committed = original.selecting(endpoint, automatic: false, requestID: id, settings: settings)
        XCTAssertTrue(request.isConfirmed(by: committed))
        XCTAssertFalse(request.isConfirmed(by: original))
        XCTAssertFalse(request.isConfirmed(by: original.selecting(endpoint, automatic: true, requestID: id, settings: settings)))
        XCTAssertFalse(request.isConfirmed(by: original.selecting(endpoint, automatic: false, requestID: UUID(), settings: settings)))
    }
    func testRuntimeStateSurvivesAppRelaunchAndOldSessionCannotDeleteNewState() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ActiveTunnelStore(root: root), original = state()
        let next = original.selecting(WARPEndpoint.fixtures(for: .awg)[0], automatic: false, requestID: UUID(), settings: settings.forProtocol(.awg))
        try store.save(next)
        XCTAssertEqual(try store.load(), next)
        try store.remove(sessionID: UUID()); XCTAssertEqual(try store.load(), next)
        try store.remove(sessionID: next.sessionID); XCTAssertNil(try store.load())
    }
    func testUnionRoutesExcludeBothOuterServersWithHostPrefixesAndPreserveDNS() throws {
        let old = WARPEndpoint.fixtures[0], next = WARPEndpoint.fixtures[1]
        let network = try TunnelNetworkSettings.make(endpoint: old, mtu: 1280, dnsAddress: "198.18.0.2", additionalEndpoints: [next, next])
        XCTAssertEqual(network.ipv4Settings?.excludedRoutes?.map(\.destinationAddress), [old.host, next.host])
        XCTAssertTrue(network.ipv4Settings?.excludedRoutes?.allSatisfy { $0.destinationSubnetMask == "255.255.255.255" } == true)
        XCTAssertEqual(network.dnsSettings?.matchDomains, [""])
        let v6 = WARPEndpoint(host: "2606:4700:d0::1", port: 2408)
        let routes = try TunnelNetworkSettings.make(endpoint: v6, mtu: 1280, dnsAddress: "198.18.0.2", additionalEndpoints: [old])
        XCTAssertEqual(routes.ipv6Settings?.excludedRoutes?.first?.destinationNetworkPrefixLength, 128)
        XCTAssertEqual(routes.ipv4Settings?.excludedRoutes?.first?.destinationAddress, old.host)
    }
    private final class Steps {
        var events: [String] = []
        var failing: Set<String> = []
        var uncertain = false
        func step(_ name: String) throws {
            events.append(name)
            if failing.contains(name) { throw TunnelReloadFailure(message: LocalizedText(name), mayHaveChangedCore: uncertain) }
        }
        func transaction() -> TunnelSwitchTransaction {
            .init(installUnionRoutes: { try self.step("union") }, closeConnections: { self.events.append("close") },
                reloadTarget: { try self.step("reload-new") }, installTargetRoutes: { try self.step("routes-new") }, saveTarget: { try self.step("save-new") },
                reloadPrevious: { try self.step("reload-old") }, installPreviousRoutes: { try self.step("routes-old") }, savePrevious: { try self.step("save-old") })
        }
    }
    func testSuccessfulSwitchInstallsRoutesBeforeReloadAndCommitsLast() throws {
        let s = Steps(); try s.transaction().perform()
        XCTAssertEqual(s.events, ["union", "close", "reload-new", "close", "routes-new", "save-new"])
    }
    func testPrecommitRefusalKeepsOldCoreAndRestoresRoutes() {
        let s = Steps(); s.failing = ["reload-new"]
        XCTAssertThrowsError(try s.transaction().perform()) { XCTAssertEqual(($0 as? TunnelSwitchFailure)?.restored, true) }
        XCTAssertEqual(s.events, ["union", "close", "reload-new", "routes-old"])
    }
    func testUnknownReloadOutcomeRestoresOldCoreBeforeOldRoutes() {
        let s = Steps(); s.failing = ["reload-new"]; s.uncertain = true
        XCTAssertThrowsError(try s.transaction().perform()) { XCTAssertEqual(($0 as? TunnelSwitchFailure)?.restored, true) }
        XCTAssertEqual(s.events, ["union", "close", "reload-new", "close", "reload-old", "routes-old"])
    }
    func testFailedStateCommitRollsBackCoreRoutesAndPersistedSelection() {
        let s = Steps(); s.failing = ["save-new"]
        XCTAssertThrowsError(try s.transaction().perform()) { XCTAssertEqual(($0 as? TunnelSwitchFailure)?.restored, true) }
        XCTAssertEqual(Array(s.events.suffix(4)), ["close", "reload-old", "routes-old", "save-old"])
    }
    func testUnrecoverableRollbackRequiresStoppingTheVPN() {
        let s = Steps(); s.failing = ["routes-new", "reload-old"]
        XCTAssertThrowsError(try s.transaction().perform()) { XCTAssertEqual(($0 as? TunnelSwitchFailure)?.restored, false) }
    }
    @MainActor
    func testNoCachePreparationWaitsForCompletedDisconnectAndDoesNotReconnect() async throws {
        var events: [String] = []
        try await DisconnectedPreparation.run(disconnect: { events.append("stop") }, waitUntilDisconnected: {
            XCTAssertEqual(events, ["stop"])
            try await Task.sleep(for: .milliseconds(10))
            events.append("disconnected")
        }, prepare: { events.append("prepare") })
        XCTAssertEqual(events, ["stop", "disconnected", "prepare"])
    }
    @MainActor
    func testFailedDisconnectNeverStartsRegistrationOrOptimization() async {
        var prepared = false
        do {
            try await DisconnectedPreparation.run(disconnect: {}, waitUntilDisconnected: { throw WARPError.message("still connected") }, prepare: { prepared = true })
            XCTFail("Expected failure")
        } catch {}
        XCTAssertFalse(prepared)
    }
    @MainActor
    func testIPCTimeoutAndDuplicateRepliesCompleteExactlyOnce() async throws {
        let expected = Data("reply".utf8)
        let response = try await ProviderMessageClient.send(Data(), timeout: 0.1) { _, callback in callback(expected); callback(nil) }
        XCTAssertEqual(response, expected)
        do { _ = try await ProviderMessageClient.send(Data(), timeout: 0.01) { _, _ in }; XCTFail("Expected timeout") } catch {}
        do { _ = try await ProviderMessageClient.send(Data(), timeout: 0.01) { _, callback in callback(nil) }; XCTFail("Expected missing reply") } catch {}
    }
    func testActualSDKReloadsAllThreeProtocolsWithoutOpeningAnotherTunBridge() throws {
        #if targetEnvironment(simulator)
        throw XCTSkip("SDK reload requires the physical-device process memory budget; verified on Richard.")
        #else
        // A socket pair is an isolated packet fixture; no NE network settings or system VPN are installed.
        var fds: [Int32] = [-1, -1]
        XCTAssertEqual(socketpair(AF_UNIX, SOCK_DGRAM, 0, &fds), 0)
        defer { close(fds[0]); close(fds[1]) }
        let platform = CorePlatform(isExtension: true)
        var opened = 0
        platform.openTunnel = { _ in opened += 1; return fds[0] }
        try platform.prepare()
        defer { platform.shutdown() }
        try CoreRuntime.setup(isExtension: false)
        var error: NSError?
        let service = try XCTUnwrap(ClashNewService(platform, &error), error?.localizedDescription ?? "")
        defer { try? service.close() }
        func content(_ kind: WARPProtocol) throws -> String {
            let node = WARPEndpoint.fixtures(for: kind)[0]
            return try WARPConfiguration.render(endpoints: [node], selected: node, account: account(kind), tunnel: true, settings: settings.forProtocol(kind))
        }
        try service.start(content(.wg))
        XCTAssertEqual(opened, 1)
        for kind in [WARPProtocol.awg, .masque, .wg] {
            ClashCloseAllConnections()
            let result = try XCTUnwrap(service.reloadClassified(content(kind)))
            XCTAssertTrue(result.errorClass.isEmpty || result.errorClass == "committed", result.message)
            XCTAssertEqual(opened, 1, "Reload must retain the original packet bridge")
        }
        #endif
    }
}
