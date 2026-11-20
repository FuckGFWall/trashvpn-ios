import Clash
import Foundation
import XCTest
@testable import TrashVPN

final class AdaptiveSelectionTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_790_000_000)
    private var settings: UserSettings { var value = UserSettings(); value.strength = .low; return value }
    private func identity() -> WARPAccount {
        var account = WARPAccount.make(kind: .wg)
        account.id = "adaptive-test"; account.token = "mock"; account.ipv4 = "172.16.0.2"
        account.peerPublicKey = WARPConfiguration.peerKey; account.state = .registered
        return account
    }
    private func result(_ settings: UserSettings, samples: [Int32]? = nil, speeds: [Double]? = nil, node: Int = 0) -> ProbeResult {
        let samples = samples ?? Array(repeating: 100, count: settings.strength.minimumRounds)
        return ProbeResult(endpoint: WARPEndpoint.fixtures(for: .wg)[node], samples: samples, testedAt: now,
            downloadMbps: speeds ?? (settings.downloadTestEnabled ? [12] : []),
            googleSuccesses: samples.enumerated().filter { $0.offset % 2 == 1 && $0.element > 0 }.count,
            qualityVersion: 3, qualityProfile: settings.qualityProfile)
    }
    func testOldSettingsMigrateWithDownloadEnabledAndThreeMbpsWithoutLosingPreferences() throws {
        var old = settings; old.mtu = 1400; old.cacheNeverExpires = true; old.customDNS = "8.8.8.8"; old.theme = .dark
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(old)) as? [String: Any])
        object.removeValue(forKey: "minimumDownloadMbps"); object.removeValue(forKey: "downloadTestEnabled")
        let migrated = try JSONDecoder().decode(UserSettings.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertEqual(migrated, old)
        XCTAssertTrue(migrated.downloadTestEnabled)
        XCTAssertEqual(migrated.minimumDownloadMbps, 3)
    }
    func testSpeedSettingsValidatePersistAndInvalidateOnlyRelevantMeasurements() throws {
        for bad in [0, -1, 0.09, 1000.1, .infinity, .nan] {
            var value = settings; value.minimumDownloadMbps = bad; XCTAssertThrowsError(try value.validated())
        }
        var value = settings; value.minimumDownloadMbps = 7.5; value.downloadTestEnabled = false
        XCTAssertEqual(try JSONDecoder().decode(UserSettings.self, from: JSONEncoder().encode(value)), value)
        XCTAssertNotEqual(value.measurementFingerprint, settings.measurementFingerprint)
        var changed = value; changed.minimumDownloadMbps = 20
        XCTAssertEqual(changed.measurementFingerprint, value.measurementFingerprint)
        changed.downloadTestEnabled = true; value.downloadTestEnabled = true
        XCTAssertNotEqual(changed.measurementFingerprint, value.measurementFingerprint)
    }
    func testLowSpeedFloorUsesASmallerPayloadWithinRequestTimeout() {
        for strength in UserSettings.Strength.allCases {
            var value = settings; value.strength = strength
            XCTAssertEqual(value.measuredDownloadBytes, strength.measuredDownloadBytes)
            value.minimumDownloadMbps = 0.1
            XCTAssertLessThanOrEqual(Double(value.measuredDownloadBytes) * 8 / 100_000, 8)
            XCTAssertLessThanOrEqual(Double(value.downloadWarmupBytes) * 8 / 100_000, 2)
            XCTAssertGreaterThanOrEqual(value.measuredDownloadBytes, 64 * 1024)
        }
    }
    func testEveryStrengthStopsOnFirstStableWindowAndOneDownload() {
        for strength in UserSettings.Strength.allCases {
            var value = settings; value.strength = strength
            let measured = result(value)
            XCTAssertTrue(measured.qualifies(value.qualityProfile))
            XCTAssertFalse(measured.needsMoreLatency(value.qualityProfile))
            XCTAssertTrue(measured.measurementFinished)
            XCTAssertLessThan(strength.minimumRounds, strength.rounds)
            XCTAssertEqual(measured.downloadMbps?.count, 1)
            let incomplete = result(value, samples: Array(repeating: 100, count: strength.minimumRounds - 1), speeds: [])
            XCTAssertTrue(incomplete.needsMoreLatency(value.qualityProfile))
            XCTAssertFalse(incomplete.qualifies(value.qualityProfile))
        }
    }
    func testOnlyAbnormalNodesNeedExtraSamplesAndUnrecoverableOnesStopEarly() {
        let value = settings
        let failed = result(value, samples: [100, -1, 100], speeds: [])
        XCTAssertFalse(failed.passesStability(value.qualityProfile))
        XCTAssertTrue(failed.needsMoreLatency(value.qualityProfile))
        let recovered = result(value, samples: [100, -1, 100, 110, 100])
        XCTAssertTrue(recovered.qualifies(value.qualityProfile))
        XCTAssertFalse(recovered.needsMoreLatency(value.qualityProfile))
        let unrecoverable = result(value, samples: [-1, -1, -1], speeds: [])
        XCTAssertFalse(unrecoverable.needsMoreLatency(value.qualityProfile))
        XCTAssertTrue(unrecoverable.measurementFinished)
        let jittery = result(value, samples: [100, 120, 900, 120, 110], speeds: [])
        XCTAssertFalse(jittery.passesStability(value.qualityProfile))
    }
    func testCustomSpeedFloorIsAppliedOnceAndCannotPassUsingAnotherPolicy() {
        var value = settings; value.minimumDownloadMbps = 8
        XCTAssertFalse(result(value, speeds: [7.99]).qualifies(value.qualityProfile))
        XCTAssertTrue(result(value, speeds: [8]).qualifies(value.qualityProfile))
        XCTAssertTrue(result(value, speeds: [1]).measurementFinished)
        XCTAssertFalse(result(value, speeds: [.infinity]).qualifies(value.qualityProfile))
        XCTAssertFalse(result(value, speeds: [12, 13]).qualifies(value.qualityProfile))
        XCTAssertFalse(result(value).qualifies(settings.qualityProfile))
    }
    func testExtraRetriesDoNotRankAboveFasterAlreadyQualifiedNodes() {
        let quick = result(settings, samples: [80, 80, 80], node: 0)
        let retried = result(settings, samples: [100, -1, 110, 120, 110], node: 1)
        XCTAssertTrue(retried.qualifies(settings.qualityProfile))
        XCTAssertTrue(ProbeResult.isBetter(quick, retried))
        XCTAssertFalse(ProbeResult.isBetter(retried, quick))
        XCTAssertEqual(ProbeResult.fastest([retried, quick]), quick.endpoint)
    }
    func testDisabledDownloadPassesOnlyWithStableLatencyAndNoDownloadSamples() {
        var value = settings; value.downloadTestEnabled = false
        XCTAssertTrue(result(value).qualifies(value.qualityProfile))
        XCTAssertTrue(result(value).measurementFinished)
        XCTAssertTrue(result(value).label.contains("未测下载"))
        XCTAssertFalse(result(value, samples: [100, -1, 100]).qualifies(value.qualityProfile))
        XCTAssertFalse(result(value, speeds: [12]).qualifies(value.qualityProfile))
    }
    func testNewCacheExportsAndPermanentCacheKeepsItsOriginalDownloadPolicy() throws {
        var value = settings; value.downloadTestEnabled = false
        let account = identity(), measured = result(value)
        let cache = try NodeCache(account: account, results: [measured], now: now, settings: value)
        XCTAssertEqual(cache.schema, 4)
        let restored = try JSONDecoder().decode(NodeCache.self, from: JSONEncoder().encode(cache))
        XCTAssertTrue(restored.canExport(for: account, family: .ipv4))
        XCTAssertTrue(restored.isValid(for: account, now: now, settings: value))
        var changed = value; changed.downloadTestEnabled = true
        XCTAssertFalse(restored.isValid(for: account, now: now, settings: changed))
        changed.cacheNeverExpires = true
        XCTAssertTrue(restored.isValid(for: account, now: now.addingTimeInterval(100 * 86400), settings: changed))
        XCTAssertEqual(restored.results, [measured])
    }
    func testLegacyV2PermanentCacheSurvivesAlgorithmUpgradeAndExports() throws {
        let account = identity(), value = settings
        let old = ProbeResult(endpoint: WARPEndpoint.fixtures[0], samples: [100, 110, 100, 110, 100], testedAt: now,
            downloadMbps: [12, 11], googleSuccesses: 2, qualityVersion: 2)
        let cache = try NodeCache(account: account, results: [old], now: now, settings: value)
        var stricter = value; stricter.minimumDownloadMbps = 50
        XCTAssertFalse(old.qualifies(settings: stricter))
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(cache)) as? [String: Any])
        object["measurementFingerprint"] = "old-quality-v2-fingerprint"
        let restored = try JSONDecoder().decode(NodeCache.self, from: JSONSerialization.data(withJSONObject: object))
        var forever = value; forever.cacheNeverExpires = true; forever.minimumDownloadMbps = 50
        XCTAssertTrue(restored.canExport(for: account, family: .ipv4))
        XCTAssertTrue(restored.isValid(for: account, now: now.addingTimeInterval(365 * 86400), settings: forever))
        XCTAssertFalse(restored.isValid(for: account, now: now, settings: value))
    }
    func testSingleDownloadAndFirstSuccessScreeningResumeWithoutInvalidatingCheckpoint() async throws {
        let account = identity(), value = settings, measured = result(settings)
        var state = OptimizationCheckpoint(account: account, settings: value, candidates: [measured.endpoint], now: now)
        state.screening[measured.endpoint.id] = ProbeResult(endpoint: measured.endpoint, samples: [100], testedAt: now)
        state.finalists = [measured.endpoint]; state.partial = measured
        let restored = try JSONDecoder().decode(OptimizationCheckpoint.self, from: JSONEncoder().encode(state))
        XCTAssertTrue(restored.isValid(account: account, settings: value, now: now))
        XCTAssertTrue(try XCTUnwrap(restored.partial).measurementFinished)
        // The real probe returns a terminal partial without issuing any HTTP request.
        let output = try await NodeQualityProbe().run(endpoints: [measured.endpoint], account: account, settings: value,
            partial: restored.partial, progress: { _ in })
        XCTAssertEqual(output, [measured])
        var changed = value; changed.minimumDownloadMbps = 15
        XCTAssertFalse(restored.isValid(account: account, settings: changed, now: now))
    }
    func testEnoughQualifiedNodesAvoidsTestingRemainingCandidates() async throws {
        let value = settings, good = [result(settings, node: 0), result(settings, node: 1)]
        let output = try await NodeQualityProbe().run(endpoints: WARPEndpoint.fixtures(for: .wg), account: identity(), settings: value,
            completed: good, progress: { _ in XCTFail("No further requests or progress should be emitted") })
        XCTAssertEqual(output, good)
    }
    func testScreeningResumeKeepsPriorAttemptsWhenFirstPassBudgetIsSmaller() async throws {
        let node = WARPEndpoint.fixtures[0]
        let saved = ProbeResult(endpoint: node, samples: [-1, 100], testedAt: now)
        var state = OptimizationCheckpoint(account: identity(), settings: settings, candidates: [node])
        state.screening[node.id] = saved
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let journal = OptimizationJournal(state, store: OptimizationCheckpointStore(root: directory))
        let output = try await EndpointProbe.screen(journal: journal, settings: settings, progress: { _ in }) { _, _ in
            XCTFail("Committed attempts must not be repeated")
            return -1
        }
        XCTAssertEqual(output.map(\.samples), [[-1, 100]])
    }
    func testScreeningDoesNotRequestTheCoresExtraURLTestRound() throws {
        try CoreRuntime.setup(isExtension: false)
        let node = WARPEndpoint.fixtures[0]
        let content = try WARPConfiguration.render(endpoints: [node], selected: node, account: identity(), tunnel: false,
            settings: settings, controller: ProbeController.allocate())
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(content.utf8)) as? [String: Any])
        XCTAssertEqual(object["unified-delay"] as? Bool, false)
        XCTAssertEqual((object["tun"] as? [String: Any])?["enable"] as? Bool, false)
        var error: NSError?
        XCTAssertTrue(ClashCheckConfig(content, &error), error?.localizedDescription ?? "")
    }
    func testProgressShowsOverallAndNodeCountersAndRegistrationAtOneThird() throws {
        let progress = PreparationProgress(stage: .downloading, fraction: 0.8, title: "下载测速", detail: "测量中",
            substep: 1, substepTotal: 8, substepLabel: "测速节点")
        XCTAssertEqual(progress.displayTitle, "11/14 下载测速 · 1/8 测速节点")
        XCTAssertEqual(try JSONDecoder().decode(PreparationProgress.self, from: JSONEncoder().encode(progress)), progress)
        XCTAssertEqual(PreparationProgress.registrationMilestone, 1.0 / 3.0)
        XCTAssertEqual(progress.stopped(failed: false, detail: "保存进度").fraction, 0.8)
        XCTAssertEqual(progress.stopped(failed: false, detail: "").displayTitle, "已暂停")
        let old = Data(#"{"stage":"screening","fraction":0.4,"title":"初筛","detail":"节点"}"#.utf8)
        XCTAssertEqual(try JSONDecoder().decode(PreparationProgress.self, from: old).displayTitle, "8/14 初筛")
    }
}
