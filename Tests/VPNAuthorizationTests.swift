import Foundation
import XCTest
@testable import TrashVPN

@MainActor
final class VPNAuthorizationTests: XCTestCase {
    func testStartsOnlyAfterSystemConsentAndReloadComplete() async throws {
        var calls: [String] = []
        try await VPNAuthorizationFlow.start(save: { calls.append("system consent") },
            reload: { calls.append("reload") }, start: { calls.append("start") })
        XCTAssertEqual(calls, ["system consent", "reload", "start"])
    }
    func testDeniedOrCancelledSystemConsentNeverStartsVPN() async {
        var calls: [String] = []
        do {
            try await VPNAuthorizationFlow.start(save: { calls.append("system consent"); throw CancellationError() },
                reload: { calls.append("reload") }, start: { calls.append("start") })
            XCTFail("Must return the system's refusal")
        } catch {}
        XCTAssertEqual(calls, ["system consent"])
    }
    func testFailedPreferenceReloadNeverStartsVPN() async {
        var calls: [String] = []
        do {
            try await VPNAuthorizationFlow.start(save: { calls.append("saved") },
                reload: { calls.append("reload"); throw CocoaError(.fileReadNoPermission) }, start: { calls.append("start") })
            XCTFail("Must return reload failure")
        } catch {}
        XCTAssertEqual(calls, ["saved", "reload"])
    }
}
