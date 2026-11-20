import Foundation
import XCTest
@testable import TrashVPN

final class OptimizationResumeTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_790_000_000)
    private var settings: UserSettings { var value = UserSettings(); value.strength = .low; return value }
    private func account(_ kind: WARPProtocol = .wg) -> WARPAccount {
        var value = WARPAccount.make(kind: kind)
        value.id = "resume-test"; value.token = "mock"; value.ipv4 = "172.16.0.2"
        value.peerPublicKey = WARPConfiguration.peerKey; value.state = .registered
        return value
    }
    private func initial(_ account: WARPAccount, settings: UserSettings, at date: Date? = nil) -> OptimizationCheckpoint {
        let endpoints = settings.addressFamily == .ipv4 ? Array(WARPEndpoint.fixtures(for: account.kind).prefix(2))
            : [WARPEndpoint(host: "2606:4700:d0::1", port: 2408, kind: account.kind)]
        return OptimizationCheckpoint(account: account, settings: settings, candidates: endpoints, now: date ?? start)
    }
    private func directory() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString) }

    func testAlternatePortsFitEveryWGBudgetAndMatchTheAddressFamily() {
        let campus = "8.35.211.127:864"
        XCTAssertEqual(Set(EndpointCatalog.alternatePorts).count, 50)
        for kind in [WARPProtocol.wg, .awg] {
            for family in IPAddressFamily.allCases {
                for strength in UserSettings.Strength.allCases {
                    let primary = EndpointCatalog.candidates(account: account(kind), previous: nil, family: family, limit: strength.candidates)
                    let fallback = EndpointCatalog.supplementalCandidates(for: primary)
                    XCTAssertEqual(fallback.count, primary.count)
                    XCTAssertLessThanOrEqual(fallback.count, strength.candidates)
                    XCTAssertEqual(Set(fallback.map(\.id)).count, fallback.count)
                    XCTAssertTrue(fallback.allSatisfy { $0.kind == kind && $0.family == family })
                    XCTAssertTrue(Set(EndpointCatalog.alternatePorts).isSubset(of: Set(fallback.map(\.port))))
                    if family == .ipv4 {
                        XCTAssertTrue(primary.prefix(12).contains { $0.address == campus })
                        XCTAssertEqual(fallback.first?.address, campus)
                    }
                }
            }
        }
    }

    func testRelaunchAfterFirstAlternateHitUsesThatPortAndSkipsCompletedWork() async throws {
        let identity = account()
        let nodes = EndpointCatalog.candidates(account: identity, previous: nil, limit: settings.strength.candidates)
        let root = directory(); defer { try? FileManager.default.removeItem(at: root) }
        let store = OptimizationCheckpointStore(root: root)
        let initial = OptimizationCheckpoint(account: identity, settings: settings, candidates: nodes, now: start)
        let journal = OptimizationJournal(initial, store: store)
        var firstPass = [WARPEndpoint]()
        var supplement = [WARPEndpoint]()
        do {
            _ = try await EndpointProbe.screen(journal: journal, settings: settings, progress: { _ in }) { endpoint, url in
                if url == WARPConfiguration.testURL { firstPass.append(endpoint); return -1 }
                XCTAssertEqual(url, WARPConfiguration.literalTraceURL)
                if !supplement.isEmpty { throw CancellationError() }
                supplement.append(endpoint)
                XCTAssertEqual(endpoint.address, "8.35.211.127:864")
                return 70
            }
            XCTFail("The simulated interruption should stop the scan")
        } catch is CancellationError {}
        XCTAssertEqual(firstPass, nodes)
        let saved = try XCTUnwrap(store.load(.wg, family: .ipv4))
        XCTAssertEqual(saved.supplementalScreening, true)
        XCTAssertTrue(saved.isValid(account: identity, settings: settings, now: start))
        var resumed = [WARPEndpoint]()
        let result = try await EndpointProbe.screen(journal: OptimizationJournal(saved, store: store), settings: settings, progress: { _ in }) { endpoint, url in
            XCTAssertEqual(url, WARPConfiguration.literalTraceURL)
            XCTAssertEqual(endpoint.port, 864)
            XCTAssertNotEqual(endpoint, supplement.first)
            resumed.append(endpoint)
            return 82
        }
        XCTAssertEqual(result.map(\.endpoint), supplement + resumed)
        XCTAssertEqual(Set(result.map { $0.endpoint.host }).count, settings.strength.qualityCandidates)
    }

    func testMasqueSupplementRetriesOnlyItsOwnCandidatesAndEarlyStopsOnPrimarySuccess() async throws {
        let identity = account(.masque)
        var config = settings; config.tunnelProtocol = .masque
        let nodes = EndpointCatalog.candidates(account: identity, previous: nil)
        for primarySucceeds in [false, true] {
            let root = directory(); defer { try? FileManager.default.removeItem(at: root) }
            let journal = OptimizationJournal(OptimizationCheckpoint(account: identity, settings: config, candidates: nodes),
                store: OptimizationCheckpointStore(root: root))
            var primary = [WARPEndpoint](), retry = [WARPEndpoint]()
            let results = try await EndpointProbe.screen(journal: journal, settings: config, progress: { _ in }) { endpoint, url in
                if url == WARPConfiguration.testURL { primary.append(endpoint); return primarySucceeds ? 85 : -1 }
                XCTAssertEqual(url, WARPConfiguration.literalTraceURL)
                retry.append(endpoint)
                return -1
            }
            XCTAssertEqual(primary, primarySucceeds ? Array(nodes.prefix(config.strength.qualityCandidates)) : nodes)
            XCTAssertEqual(retry, primarySucceeds ? [] : nodes)
            XCTAssertEqual(results.count, primarySucceeds ? config.strength.qualityCandidates : 0)
        }
    }

    func testScreeningAlternateUsesTheLiteralAddressAndAcceptsCloudflareHEADRedirect() throws {
        let controller = try ProbeController.allocate()
        let url = controller.url(endpoint: WARPEndpoint.fixtures[0], timeout: 5, target: WARPConfiguration.literalTraceURL)
        let items = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        XCTAssertEqual(items.first { $0.name == "url" }?.value, "https://1.1.1.1/cdn-cgi/trace")
        XCTAssertEqual(items.first { $0.name == "expected" }?.value, "200/302")
        XCTAssertEqual(EndpointProbe.failureReason(status: 504, response: nil), "timeout")
        XCTAssertEqual(EndpointProbe.failureReason(status: 503, response: ["message": "lookup: no such host"]), "dns")
        XCTAssertEqual(EndpointProbe.failureReason(status: 503, response: ["httpStatus": 403]), "http-403")
    }

    func testRelaunchRestoresCandidateOrderAndIndividualScreeningRounds() throws {
        let root = directory(); defer { try? FileManager.default.removeItem(at: root) }
        let identity = account(); var state = initial(identity, settings: settings)
        let first = state.candidates[0]
        state.screening[first.id] = ProbeResult(endpoint: first, samples: [130], testedAt: start)
        try OptimizationCheckpointStore(root: root).save(state)
        let reopened = try XCTUnwrap(OptimizationCheckpointStore(root: root).load(.wg, family: .ipv4))
        XCTAssertEqual(reopened, state)
        XCTAssertTrue(reopened.isValid(account: identity, settings: settings, now: start.addingTimeInterval(60)))
        XCTAssertEqual(reopened.screening[first.id]?.samples, [130])
        XCTAssertEqual(reopened.candidates, state.candidates)
    }

    func testDownloadCheckpointSurvivesKillWithoutRepeatingCompletedRounds() async throws {
        let root = directory(); defer { try? FileManager.default.removeItem(at: root) }
        let files = OptimizationCheckpointStore(root: root); let identity = account()
        var state = initial(identity, settings: settings)
        let first = state.candidates[0]
        state.screening[first.id] = ProbeResult(endpoint: first, samples: [100, 110], testedAt: start)
        state.finalists = [first]
        let journal = OptimizationJournal(state, store: files)
        await journal.publish(.progress(.init(stage: .downloading, fraction: 0.9, title: "下载测速 2/2", detail: "节点 1/1")), to: { _ in })
        let partial = ProbeResult(endpoint: first, samples: [100, 110, 100, 110, 100], testedAt: start,
            downloadMbps: [12], googleSuccesses: 2, qualityVersion: 2)
        try await journal.sample(partial)
        let recovered = try XCTUnwrap(OptimizationCheckpointStore(root: root).load(.wg, family: .ipv4))
        XCTAssertTrue(recovered.isValid(account: identity, settings: settings, now: start.addingTimeInterval(300)))
        XCTAssertEqual(recovered.partial, partial)
        XCTAssertEqual(recovered.progress.fraction, 0.9)
        XCTAssertTrue(recovered.completed.isEmpty)
        var finished = partial; finished.downloadMbps = [12, 11]
        let newProcess = OptimizationJournal(recovered, store: files)
        try await newProcess.finish(finished)
        let completed = try XCTUnwrap(files.load(.wg, family: .ipv4))
        XCTAssertNil(completed.partial)
        XCTAssertEqual(completed.completed, [finished])
        XCTAssertEqual(completed.id, state.id)
        XCTAssertTrue(completed.isValid(account: identity, settings: settings, now: start.addingTimeInterval(301)))
    }

    func testCheckpointExpiryAlwaysUsesOriginalStartForEveryCacheDuration() throws {
        let root = directory(); defer { try? FileManager.default.removeItem(at: root) }
        let files = OptimizationCheckpointStore(root: root); let identity = account()
        for days in [1, 2, 7, 30] {
            var config = settings; config.cacheDays = days
            let state = initial(identity, settings: config)
            try files.save(state)
            let restored = try XCTUnwrap(files.load(.wg, family: .ipv4))
            try files.save(restored)
            XCTAssertEqual(try files.load(.wg, family: .ipv4)?.startedAt, start)
            XCTAssertTrue(restored.isValid(account: identity, settings: config, now: start.addingTimeInterval(config.cacheLifetime - 1)))
            XCTAssertFalse(restored.isValid(account: identity, settings: config, now: start.addingTimeInterval(config.cacheLifetime)))
            XCTAssertFalse(restored.isValid(account: identity, settings: config, now: start.addingTimeInterval(-1)))
        }
    }

    func testIdentityAndMeasurementChangesRejectOldProgressButThemeDoesNot() {
        let identity = account(); let state = initial(identity, settings: settings)
        XCTAssertFalse(state.isValid(account: account(), settings: settings, now: start))
        for field in 0..<6 {
            var changed = settings
            switch field {
            case 0: changed.mtu = 1400
            case 1: changed.addressFamily = .ipv6
            case 2: changed.strength = .high
            case 3: changed.probeTimeout = 8
            case 4: changed.customDNS = "8.8.8.8"
            default: changed.tunnelProtocol = .awg
            }
            XCTAssertFalse(state.isValid(account: identity, settings: changed, now: start))
        }
        var theme = settings; theme.theme = .dark
        XCTAssertTrue(state.isValid(account: identity, settings: theme, now: start))
    }

    func testMalformedOrCrossEndpointMeasurementsCannotBeResumed() throws {
        let identity = account(); var state = initial(identity, settings: settings)
        state.screening[state.candidates[0].id] = ProbeResult(endpoint: state.candidates[0], samples: [1, 2, 3], testedAt: start)
        XCTAssertFalse(state.isValid(account: identity, settings: settings, now: start))
        state.screening = [:]; state.finalists = [state.candidates[0]]
        XCTAssertFalse(state.isValid(account: identity, settings: settings, now: start))
        let root = directory(); defer { try? FileManager.default.removeItem(at: root) }
        let files = OptimizationCheckpointStore(root: root)
        try files.save(initial(identity, settings: settings))
        try Data("incomplete write".utf8).write(to: root.appendingPathComponent("wg-ipv4.json"))
        XCTAssertNil(try files.load(.wg, family: .ipv4))
    }

    func testProtocolAndAddressFamilyProgressAreIndependent() throws {
        let root = directory(); defer { try? FileManager.default.removeItem(at: root) }
        let files = OptimizationCheckpointStore(root: root); let identity = account()
        let v4 = initial(identity, settings: settings)
        var config6 = settings; config6.addressFamily = .ipv6
        let v6 = initial(identity, settings: config6)
        let awg = account(.awg); var awgSettings = settings; awgSettings.tunnelProtocol = .awg
        let other = initial(awg, settings: awgSettings)
        try files.save(v4); try files.save(v6); try files.save(other)
        XCTAssertEqual(try files.load(.wg, family: .ipv4)?.id, v4.id)
        XCTAssertEqual(try files.load(.wg, family: .ipv6)?.id, v6.id)
        XCTAssertEqual(try files.load(.awg, family: .ipv4)?.id, other.id)
        try files.remove(.wg, family: .ipv4)
        XCTAssertNil(try files.load(.wg, family: .ipv4))
        XCTAssertEqual(try files.load(.wg, family: .ipv6)?.id, v6.id)
    }

    func testRestoringConnectionsCannotMoveProgressBarBackwards() async throws {
        let root = directory(); defer { try? FileManager.default.removeItem(at: root) }
        var state = initial(account(), settings: settings)
        state.progress = .init(stage: .downloading, fraction: 0.92, title: "下载测速", detail: "已完成一轮")
        let files = OptimizationCheckpointStore(root: root)
        let journal = OptimizationJournal(state, store: files)
        await journal.publish(.progress(.init(stage: .retesting, fraction: 0.72, title: "恢复节点测速连接", detail: "重新预热",
            substep: 2, substepTotal: 4, substepLabel: "测速节点")), to: { _ in })
        let snapshot = await journal.snapshot()
        XCTAssertEqual(snapshot.progress.fraction, 0.92)
        XCTAssertEqual(snapshot.progress.title, "恢复节点测速连接")
        XCTAssertEqual(snapshot.progress.displayTitle, "10/14 恢复节点测速连接 · 2/4 测速节点")
        XCTAssertEqual(try files.load(.wg, family: .ipv4)?.progress, snapshot.progress)
    }

    func testPendingManualRefreshTakesPriorityOverOlderFreshCache() async throws {
        let root = directory(); defer { try? FileManager.default.removeItem(at: root) }
        let files = OptimizationCheckpointStore(root: root)
        let accounts = MemoryAccounts(); let caches = MemoryCaches(); let registration = MockRegistration(); let optimizer = MockOptimizer()
        let first = try await NodePreparation(accounts: accounts, caches: caches, registration: registration,
            optimizer: optimizer, now: { self.start }).prepare(kind: .wg) { _ in }
        let identity = try XCTUnwrap(accounts.load(.wg))
        let config = UserSettings()
        try files.save(initial(identity, settings: config, at: start.addingTimeInterval(1)))
        let second = try await NodePreparation(accounts: accounts, caches: caches, registration: registration, optimizer: optimizer,
            checkpoints: files, now: { self.start.addingTimeInterval(10) }).prepare(kind: .wg) { _ in }
        XCTAssertFalse(second.reusedCache)
        XCTAssertNotEqual(first.cache.createdAt, second.cache.createdAt)
        let calls = await optimizer.calls; XCTAssertEqual(calls, 2)
        XCTAssertNil(try files.load(.wg, family: .ipv4))
    }

    func testKillAfterFinalCacheSaveCannotExtendItsExpiryOnRelaunch() async throws {
        let root = directory(); defer { try? FileManager.default.removeItem(at: root) }
        let files = OptimizationCheckpointStore(root: root)
        let accounts = MemoryAccounts(); let caches = MemoryCaches(); let registration = MockRegistration(); let optimizer = MockOptimizer()
        let first = try await NodePreparation(accounts: accounts, caches: caches, registration: registration,
            optimizer: optimizer, now: { self.start }).prepare(kind: .wg) { _ in }
        let identity = try XCTUnwrap(accounts.load(.wg))
        try files.save(initial(identity, settings: UserSettings(), at: start.addingTimeInterval(-60)))
        let reopened = try await NodePreparation(accounts: accounts, caches: caches, registration: registration, optimizer: optimizer,
            checkpoints: files, now: { self.start.addingTimeInterval(300) }).prepare(kind: .wg) { _ in }
        XCTAssertTrue(reopened.reusedCache)
        XCTAssertEqual(reopened.cache.expiresAt, first.cache.expiresAt)
        let calls = await optimizer.calls; XCTAssertEqual(calls, 1)
        XCTAssertNil(try files.load(.wg, family: .ipv4))
    }
}
