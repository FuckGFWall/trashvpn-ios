import Foundation
import XCTest
@testable import TrashVPN

final class MemoryAccounts: AccountStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [WARPProtocol: WARPAccount] = [:]
    func load(_ kind: WARPProtocol) throws -> WARPAccount? { lock.lock(); defer { lock.unlock() }; return values[kind] }
    func save(_ account: WARPAccount) throws { lock.lock(); defer { lock.unlock() }; values[account.kind] = account }
    func remove(_ kind: WARPProtocol) { lock.lock(); defer { lock.unlock() }; values[kind] = nil }
}

final class MemoryCaches: NodeCacheStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [WARPProtocol: NodeCache] = [:]
    func load(_ kind: WARPProtocol) throws -> NodeCache? { lock.lock(); defer { lock.unlock() }; return values[kind] }
    func save(_ cache: NodeCache) throws { lock.lock(); defer { lock.unlock() }; values[cache.kind] = cache }
}

actor MockRegistration: WARPRegistering {
    private(set) var registrations = 0
    func ensureRegistered(kind: WARPProtocol, existing: WARPAccount?,
        checkpoint: @escaping @Sendable (WARPAccount) throws -> Void,
        progress: @escaping @Sendable (PreparationProgress) async -> Void) async throws -> WARPAccount {
        if let existing, existing.isRegistered { return existing }
        registrations += 1
        var account = WARPAccount.make(kind: kind)
        account.id = UUID().uuidString; account.token = "mock-token"; account.state = .registered
        account.ipv4 = "172.16.0.2"; account.peerPublicKey = WARPConfiguration.peerKey
        try checkpoint(account)
        return account
    }
}

actor MockOptimizer: NodeOptimizing {
    private(set) var calls = 0
    func optimize(account: WARPAccount, previous: NodeCache?,
        progress: @escaping @Sendable (PreparationUpdate) async -> Void) async throws -> [ProbeResult] {
        calls += 1
        return [ProbeResult(endpoint: WARPEndpoint.fixtures(for: account.kind)[0], samples: Array(repeating: 100, count: UserSettings.Strength.medium.rounds), testedAt: Date(), downloadMbps: Array(repeating: 20, count: UserSettings.Strength.medium.downloadRounds), googleSuccesses: UserSettings.Strength.medium.rounds / 2, qualityVersion: 2)]
    }
}

struct FailingOptimizer: NodeOptimizing {
    let cancelled: Bool
    func optimize(account: WARPAccount, previous: NodeCache?,
        progress: @escaping @Sendable (PreparationUpdate) async -> Void) async throws -> [ProbeResult] {
        if cancelled { throw CancellationError() }
        throw WARPError.message("模拟网络不可达")
    }
}

final class NodePreparationTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_790_000_000)
    private let accounts = MemoryAccounts()
    private let caches = MemoryCaches()
    private let registration = MockRegistration()
    private let optimizer = MockOptimizer()

    private func service(at date: Date, optimizer override: (any NodeOptimizing)? = nil) -> NodePreparation {
        NodePreparation(accounts: accounts, caches: caches, registration: registration,
            optimizer: override ?? optimizer, now: { date })
    }

    func testFreshCacheDoesNotRegisterRescanOrExtendExpiry() async throws {
        let first = try await service(at: start).prepare(kind: .wg) { _ in }
        let reopened = try await service(at: start.addingTimeInterval(7200)).prepare(kind: .wg) { _ in }
        XCTAssertTrue(reopened.reusedCache)
        XCTAssertEqual(first.cache, reopened.cache)
        XCTAssertEqual(first.cache.expiresAt, start.addingTimeInterval(21600))
        let registrations = await registration.registrations; let scans = await optimizer.calls
        XCTAssertEqual(registrations, 1); XCTAssertEqual(scans, 1)
    }

    func testExactSixHourBoundaryRescansWithoutReregistering() async throws {
        _ = try await service(at: start).prepare(kind: .awg) { _ in }
        let fresh = try await service(at: start.addingTimeInterval(21599)).prepare(kind: .awg) { _ in }
        XCTAssertTrue(fresh.reusedCache)
        let expired = try await service(at: start.addingTimeInterval(21600)).prepare(kind: .awg) { _ in }
        XCTAssertFalse(expired.reusedCache)
        XCTAssertEqual(expired.cache.expiresAt, start.addingTimeInterval(43200))
        let registrations = await registration.registrations; let scans = await optimizer.calls
        XCTAssertEqual(registrations, 1); XCTAssertEqual(scans, 2)
    }

    func testProtocolCachesAndIdentitiesAreIndependent() async throws {
        var fingerprints = Set<String>()
        for kind in WARPProtocol.allCases {
            let ready = try await service(at: start).prepare(kind: kind) { _ in }
            XCTAssertEqual(ready.cache.kind, kind)
            XCTAssertTrue(ready.cache.results.allSatisfy { $0.endpoint.kind == kind })
            fingerprints.insert(ready.cache.accountFingerprint)
        }
        XCTAssertEqual(fingerprints.count, 3)
        let registrations = await registration.registrations
        XCTAssertEqual(registrations, 3)
    }

    func testMissingIdentityInvalidatesOtherwiseFreshCache() async throws {
        let first = try await service(at: start).prepare(kind: .masque) { _ in }
        accounts.remove(.masque)
        let second = try await service(at: start.addingTimeInterval(1)).prepare(kind: .masque) { _ in }
        XCTAssertFalse(second.reusedCache)
        XCTAssertNotEqual(first.cache.accountFingerprint, second.cache.accountFingerprint)
        let registrations = await registration.registrations
        XCTAssertEqual(registrations, 2)
    }

    func testFailedRefreshKeepsPreviousCacheDeadlineAndIdentity() async throws {
        let first = try await service(at: start).prepare(kind: .wg) { _ in }
        let identity = try accounts.load(.wg)
        do {
            _ = try await service(at: start.addingTimeInterval(21600), optimizer: FailingOptimizer(cancelled: false)).prepare(kind: .wg) { _ in }
            XCTFail("refresh should fail")
        } catch {}
        XCTAssertEqual(try caches.load(.wg), first.cache)
        XCTAssertEqual(try accounts.load(.wg), identity)
    }

    func testCancelledPreparationKeepsRegistrationButNeverPromotesCache() async throws {
        do {
            _ = try await service(at: start, optimizer: FailingOptimizer(cancelled: true)).prepare(kind: .awg) { _ in }
            XCTFail("preparation should cancel")
        } catch is CancellationError {} catch { XCTFail("unexpected error") }
        XCTAssertTrue(try XCTUnwrap(accounts.load(.awg)).isRegistered)
        XCTAssertNil(try caches.load(.awg))
    }

    func testPartialSamplesAndClockRollbackCannotBecomeValidCache() async throws {
        _ = try await service(at: start).prepare(kind: .wg) { _ in }
        let account = try XCTUnwrap(accounts.load(.wg))
        let partial = ProbeResult(endpoint: WARPEndpoint.fixtures[0], samples: [100], testedAt: start)
        XCTAssertThrowsError(try NodeCache(account: account, results: [partial], now: start))
        let cache = try XCTUnwrap(caches.load(.wg))
        XCTAssertFalse(cache.isValid(for: account, now: start.addingTimeInterval(-1)))
        XCTAssertFalse(cache.isValid(for: account, now: start.addingTimeInterval(21600)))
    }

    func testAtomicFileCacheSurvivesRelaunchAndCorruptionIsReplaceable() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let files = NodeCacheStore(root: directory)
        let cache = try await service(at: start).prepare(kind: .wg) { _ in }.cache
        try files.save(cache)
        XCTAssertEqual(try NodeCacheStore(root: directory).load(.wg), cache)
        try Data("broken cache".utf8).write(to: directory.appendingPathComponent("wg.json"))
        XCTAssertNil(try files.load(.wg))
        try files.save(cache)
        XCTAssertEqual(try files.load(.wg), cache)
    }
}
