import Foundation
import XCTest
@testable import TrashVPN

final class PermanentCacheTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_790_000_000)
    private var forever: UserSettings { var settings = UserSettings(); settings.cacheHours = 0; return settings }

    func testNeverExpirationIsPersistedWithoutNonfiniteJSONNumbers() async throws {
        let accounts = MemoryAccounts(); let caches = MemoryCaches()
        let result = try await NodePreparation(accounts: accounts, caches: caches, registration: MockRegistration(),
            optimizer: MockOptimizer(), settings: forever, now: { self.start }).prepare(kind: .wg) { _ in }
        let data = try JSONEncoder().encode(result.cache)
        let restored = try JSONDecoder().decode(NodeCache.self, from: data)
        XCTAssertEqual(restored.expiresAt, .distantFuture)
        XCTAssertEqual(restored.expiry(settings: forever), .distantFuture)
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("Infinity"))
        XCTAssertTrue(restored.isValid(for: try XCTUnwrap(accounts.load(.wg)), now: start.addingTimeInterval(20 * 365 * 86400), settings: forever))
        XCTAssertNoThrow(try forever.validated())
        XCTAssertEqual(forever.cacheDurationLabel, "永不过期")
    }

    func testNeverExpirationReusesOldCacheEvenWhenMeasurementSettingsChange() async throws {
        let accounts = MemoryAccounts(); let caches = MemoryCaches(); let optimizer = MockOptimizer(); let registration = MockRegistration()
        let original = try await NodePreparation(accounts: accounts, caches: caches, registration: registration,
            optimizer: optimizer, now: { self.start }).prepare(kind: .wg) { _ in }
        var config = forever; config.mtu = 1400; config.strength = .high; config.probeTimeout = 8; config.customDNS = "8.8.8.8"
        let reused = try await NodePreparation(accounts: accounts, caches: caches, registration: registration,
            optimizer: optimizer, settings: config, now: { self.start.addingTimeInterval(365 * 86400) }).prepare(kind: .wg) { _ in }
        XCTAssertTrue(reused.reusedCache)
        XCTAssertEqual(reused.cache, original.cache)
        let calls = await optimizer.calls; XCTAssertEqual(calls, 1)
        let registrations = await registration.registrations; XCTAssertEqual(registrations, 1)
    }

    func testOnlyExplicitRefreshReplacesPermanentResultsAndTimestamp() async throws {
        let accounts = MemoryAccounts(); let caches = MemoryCaches(); let optimizer = MockOptimizer(); let registration = MockRegistration()
        let original = try await NodePreparation(accounts: accounts, caches: caches, registration: registration,
            optimizer: optimizer, settings: forever, now: { self.start }).prepare(kind: .wg) { _ in }
        let refreshed = try await NodePreparation(accounts: accounts, caches: caches, registration: registration,
            optimizer: optimizer, settings: forever, now: { self.start.addingTimeInterval(100) }).prepare(kind: .wg, force: true) { _ in }
        XCTAssertFalse(refreshed.reusedCache)
        XCTAssertNotEqual(refreshed.cache.createdAt, original.cache.createdAt)
        let calls = await optimizer.calls; XCTAssertEqual(calls, 2)
    }

    func testReturningFromPermanentToTimedExpiryUsesOriginalAge() async throws {
        let accounts = MemoryAccounts(); let caches = MemoryCaches()
        let saved = try await NodePreparation(accounts: accounts, caches: caches, registration: MockRegistration(),
            optimizer: MockOptimizer(), settings: forever, now: { self.start }).prepare(kind: .wg) { _ in }.cache
        let identity = try XCTUnwrap(accounts.load(.wg)); let timed = UserSettings()
        XCTAssertTrue(saved.isValid(for: identity, now: start.addingTimeInterval(21599), settings: timed))
        XCTAssertFalse(saved.isValid(for: identity, now: start.addingTimeInterval(21600), settings: timed))
        var changed = identity; changed.id = "another-device"
        XCTAssertFalse(saved.isValid(for: changed, now: start, settings: forever))
        XCTAssertFalse(saved.isValid(for: identity, now: start, family: .ipv6, settings: forever))
    }

    func testAutomaticPendingScanCannotOverridePermanentCacheButManualOneResumes() async throws {
        for manual in [false, true] {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: root) }
            let files = OptimizationCheckpointStore(root: root)
            let accounts = MemoryAccounts(); let caches = MemoryCaches(); let optimizer = MockOptimizer(); let registration = MockRegistration()
            _ = try await NodePreparation(accounts: accounts, caches: caches, registration: registration,
                optimizer: optimizer, settings: forever, now: { self.start }).prepare(kind: .wg) { _ in }
            let account = try XCTUnwrap(accounts.load(.wg))
            let pending = OptimizationCheckpoint(account: account, settings: forever, candidates: [WARPEndpoint.fixtures[0]],
                now: start.addingTimeInterval(1), userInitiated: manual)
            try files.save(pending)
            let result = try await NodePreparation(accounts: accounts, caches: caches, registration: registration,
                optimizer: optimizer, settings: forever, checkpoints: files, now: { self.start.addingTimeInterval(10) }).prepare(kind: .wg) { _ in }
            XCTAssertEqual(result.reusedCache, !manual)
            let calls = await optimizer.calls; XCTAssertEqual(calls, manual ? 2 : 1)
            XCTAssertNil(try files.load(.wg, family: .ipv4))
        }
    }

    func testPermanentCheckpointsSurviveLongPauseAndOldFilesRemainReadable() throws {
        var account = WARPAccount.make(kind: .wg)
        account.id = "checkpoint"; account.token = "mock"; account.peerPublicKey = WARPConfiguration.peerKey
        account.ipv4 = "172.16.0.2"; account.state = .registered
        let checkpoint = OptimizationCheckpoint(account: account, settings: forever, candidates: [WARPEndpoint.fixtures[0]], now: start)
        XCTAssertTrue(checkpoint.isValid(account: account, settings: forever, now: start.addingTimeInterval(5 * 365 * 86400)))
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(checkpoint)) as? [String: Any])
        object.removeValue(forKey: "userInitiated")
        let old = try JSONDecoder().decode(OptimizationCheckpoint.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertNil(old.userInitiated)
        XCTAssertTrue(old.isValid(account: account, settings: forever, now: start))
    }

    func testRunningTunnelAdoptsLatestCachePolicyWithoutChangingItsNetworkSnapshot() {
        var running = UserSettings(); running.mtu = 1280; running.customDNS = "1.1.1.1"
        var latest = forever; latest.mtu = 1400; latest.customDNS = "8.8.8.8"; latest.strength = .high
        let policy = running.withCachePolicy(from: latest)
        XCTAssertTrue(policy.cacheNeverExpires)
        XCTAssertEqual(policy.mtu, running.mtu)
        XCTAssertEqual(policy.customDNS, running.customDNS)
        XCTAssertEqual(policy.strength, running.strength)
        XCTAssertEqual(running.withCachePolicy(from: nil), running)
    }
}
