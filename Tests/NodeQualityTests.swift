import Clash
import Foundation
import XCTest
@testable import TrashVPN

final class NodeQualityTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_790_000_000)
    private func result(samples: [Int32] = [100, 110, 100, 110, 105], speeds: [Double] = [12, 11], google: Int = 2, node: Int = 0) -> ProbeResult {
        ProbeResult(endpoint: WARPEndpoint.fixtures(for: .wg)[node], samples: samples, testedAt: now,
            downloadMbps: speeds, googleSuccesses: google, qualityVersion: 2)
    }
    private func account() -> WARPAccount {
        var value = WARPAccount.make(kind: .wg)
        value.id = "quality-test"; value.token = "test"; value.peerPublicKey = WARPConfiguration.peerKey
        value.ipv4 = "172.16.0.2"; value.state = .registered
        return value
    }
    func testFastButMostlyFailingNodeCannotEnterCache() throws {
        let fast = result(samples: [10, -1, -1, -1, -1], google: 0)
        let stable = result(node: 1)
        var settings = UserSettings(); settings.strength = .low
        let cache = try NodeCache(account: account(), results: [fast, stable], now: now, settings: settings)
        XCTAssertEqual(cache.results.map(\.endpoint), [stable.endpoint])
        XCTAssertEqual(ProbeResult.fastest(cache.results), stable.endpoint)
    }
    func testSpeedFloorAndSlowestRoundAreEnforced() {
        XCTAssertFalse(result(speeds: [20, 1]).qualifies(.low))
        XCTAssertFalse(result(speeds: [3.1, 30]).qualifies(.low))
        XCTAssertTrue(result(speeds: [12, 11]).qualifies(.low))
        XCTAssertEqual(result(speeds: [12, 11]).speedMbps, 11)
        XCTAssertFalse(result(speeds: [.infinity, 20]).qualifies(.low))
    }
    func testYouTubeAndStabilityCannotBeReplacedByFastDownload() {
        XCTAssertFalse(result(google: 0).qualifies(.low))
        XCTAssertFalse(result(samples: [100, 110, 900, 115, 110]).qualifies(.low))
        XCTAssertTrue(result(samples: [100, 300, 110, 310, 105]).qualifies(.low))
    }
    func testEveryStrengthRequiresCompleteLatencyAndDownloadMeasurements() {
        for strength in UserSettings.Strength.allCases {
            let value = ProbeResult(endpoint: WARPEndpoint.fixtures[0], samples: Array(repeating: 100, count: strength.rounds), testedAt: now,
                downloadMbps: Array(repeating: 10, count: strength.downloadRounds), googleSuccesses: strength.rounds / 2, qualityVersion: 2)
            XCTAssertTrue(value.qualifies(strength))
            var missing = value; missing.downloadMbps = []
            XCTAssertFalse(missing.qualifies(strength))
        }
    }
    func testOldDelayOnlyCacheIsInvalidForNewPreparation() throws {
        let identity = account()
        let old = try NodeCache(account: identity, results: [ProbeResult(endpoint: WARPEndpoint.fixtures[0], samples: [10, 10, 10], testedAt: now)], now: now)
        XCTAssertFalse(old.isValid(for: identity, now: now, settings: UserSettings()))
    }
    func testDownloadProxyIsLoopbackAuthenticatedAndDoesNotEnableTun() throws {
        try CoreRuntime.setup(isExtension: false)
        let proxy = try ProbeProxy.allocate(); let node = WARPEndpoint.fixtures[0]
        let content = try WARPConfiguration.render(endpoints: [node], selected: node, account: account(), tunnel: false, probeProxy: proxy)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(content.utf8)) as? [String: Any])
        XCTAssertEqual(object["mixed-port"] as? Int, Int(proxy.port))
        XCTAssertEqual(object["bind-address"] as? String, "127.0.0.1")
        XCTAssertEqual(object["authentication"] as? [String], ["\(proxy.username):\(proxy.password)"])
        XCTAssertEqual(object["skip-auth-prefixes"] as? [String], [])
        XCTAssertEqual((object["tun"] as? [String: Any])?["enable"] as? Bool, false)
        var error: NSError?
        XCTAssertTrue(ClashCheckConfig(content, &error), error?.localizedDescription ?? "")
    }
}
