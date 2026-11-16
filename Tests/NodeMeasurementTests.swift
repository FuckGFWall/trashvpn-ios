import Foundation
import NetworkExtension
import XCTest
@testable import TrashVPN

final class NodeMeasurementTests: XCTestCase {
    private func account() -> WARPAccount {
        var value = WARPAccount.make(kind: .wg)
        value.id = "measurement-test"; value.token = "mock"; value.peerPublicKey = WARPConfiguration.peerKey
        value.ipv4 = "172.16.0.2"; value.state = .registered; return value
    }
    private func cache(_ identity: WARPAccount, now: Date) throws -> NodeCache {
        let value = ProbeResult(endpoint: WARPEndpoint.fixtures[0], samples: [100, 110, 100], testedAt: now)
        return try NodeCache(account: identity, results: [value], now: now)
    }
    func testManualResultsSurviveRelaunchWithoutChangingQualityCacheOrItsAge() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let identity = account(), now = Date(), cached = try cache(identity, now: now), store = NodeMeasurementStore(root: root)
        try NodeCacheStore(root: root).save(cached)
        let cacheFile = root.appendingPathComponent("wg.json")
        let encoded = try Data(contentsOf: cacheFile)
        let values = [cached.results[0].endpoint.id: NodeMeasurement(latencyMS: -1, downloadMbps: 7.5)]
        try store.save(values, for: cached)
        XCTAssertEqual(store.load(for: cached), values)
        XCTAssertEqual(try Data(contentsOf: cacheFile), encoded)
        XCTAssertEqual(cached.createdAt, now)
        XCTAssertTrue(store.load(for: try cache(identity, now: now.addingTimeInterval(1))).isEmpty)
        var rotated = identity; rotated.id = "new-registration"
        XCTAssertTrue(store.load(for: try cache(rotated, now: now)).isEmpty)
    }
    func testTraceRequiresActualWARPInsteadOfPlainInternetSuccess() {
        XCTAssertTrue(LiveNodeProbe.confirmsWARP(Data("ip=1.2.3.4\nwarp=on\n".utf8)))
        XCTAssertTrue(LiveNodeProbe.confirmsWARP(Data("warp=plus\n".utf8)))
        XCTAssertFalse(LiveNodeProbe.confirmsWARP(Data("warp=off\n".utf8)))
        XCTAssertFalse(LiveNodeProbe.confirmsWARP(Data("notwarp=on\n".utf8)))
    }
    func testAutomaticChoiceUsesNewLatencyAndExcludesFailedNodes() throws {
        let identity = account(), now = Date()
        let nodes = Array(WARPEndpoint.fixtures.prefix(2))
        let cached = try NodeCache(account: identity, results: nodes.enumerated().map { index, endpoint in
            ProbeResult(endpoint: endpoint, samples: Array(repeating: Int32(50 + index * 50), count: 3), testedAt: now)
        }, now: now)
        let values = [nodes[0].id: NodeMeasurement(latencyMS: -1), nodes[1].id: NodeMeasurement(latencyMS: 200)]
        XCTAssertEqual(CachedNodeChoice.resolve(cached, stored: "auto", measurements: values)?.endpoint, nodes[1])
        XCTAssertEqual(CachedNodeChoice.resolve(cached, stored: nodes[0].id, measurements: values)?.endpoint, nodes[0])
    }
    func testPlanChangesWithRegistrationAndDownloadSettingAndReadyHasNoCounter() {
        let full = PreparationProgress.plan(existing: nil, download: true)
        let noDownload = PreparationProgress.plan(existing: nil, download: false)
        XCTAssertEqual(full.count - noDownload.count, 1)
        XCTAssertFalse(noDownload.contains(.downloading))
        let registered = PreparationProgress.plan(existing: account(), download: false)
        XCTAssertFalse(registered.contains(.credentials)); XCTAssertFalse(registered.contains(.registering))
        XCTAssertLessThan(registered.count, noDownload.count)
        var value = PreparationProgress(stage: .retesting, fraction: 0.6, title: "稳定性检查", detail: "", substep: 1, substepTotal: 4, substepLabel: "测速节点")
        value.steps = registered
        XCTAssertEqual(value.displayTitle, "6/9 稳定性检查 · 1/4 测速节点")
        let ready = PreparationProgress(stage: .ready, fraction: 1, title: "连接已就绪", detail: "")
        XCTAssertEqual(ready.displayTitle, "连接已就绪")
        var pending = account(); pending.state = .created
        XCTAssertFalse(PreparationProgress.plan(existing: pending, download: true).contains(.registering))
    }
    func testPlanSurvivesCheckpointPublishingAndReopen() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = OptimizationCheckpointStore(root: root)
        let identity = account(), settings = UserSettings()
        var state = OptimizationCheckpoint(account: identity, settings: settings, candidates: [WARPEndpoint.fixtures[0]])
        state.progress.steps = PreparationProgress.plan(existing: nil, download: false)
        let journal = OptimizationJournal(state, store: store)
        await journal.publish(.progress(.init(stage: .retesting, fraction: 0.7, title: "稳定性检查", detail: "")), to: { _ in })
        let restored = try XCTUnwrap(store.load(.wg, family: .ipv4))
        XCTAssertEqual(restored.progress.steps, state.progress.steps)
        XCTAssertEqual(restored.progress.totalSteps, state.progress.steps?.count)
    }
    @MainActor
    func testConnectWaitAllowsInitialDisconnectedStatusBeforeSystemStartsConnecting() async throws {
        let states: [NEVPNStatus] = [.disconnected, .connecting, .connected]
        var index = 0
        try await VPNConnectionAwaiter.wait(timeout: .seconds(2), status: {
            defer { index = min(index + 1, states.count - 1) }; return states[index]
        }, refresh: {})
        XCTAssertEqual(index, 2)
    }

}
