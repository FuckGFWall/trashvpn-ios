import Foundation
import XCTest
@testable import TrashVPN

final class ConnectionLocationTests: XCTestCase {
    func testWARPTraceProvidesCountryFlagAndActualAirportCode() throws {
        let value = try XCTUnwrap(ConnectionLocation(trace: Data("ip=203.0.113.1\nloc=JP\ncolo=NRT\nwarp=on\n".utf8)))
        XCTAssertEqual(value.country, "JP"); XCTAssertEqual(value.colo, "NRT")
        XCTAssertEqual(value.label, "国家: 🇯🇵　数据中心: NRT")
    }
    func testPlusAndWindowsLineEndingsAreAccepted() throws {
        let value = try XCTUnwrap(ConnectionLocation(trace: Data("loc=US\r\ncolo=lax\r\nwarp=plus\r\n".utf8)))
        XCTAssertEqual(value.label, "国家: 🇺🇸　数据中心: LAX")
    }
    func testDirectConnectionAndMissingMetadataAreNeverPresentedAsTunnelLocation() {
        for trace in ["loc=JP\ncolo=NRT\nwarp=off", "loc=JP\ncolo=NRT", "warp=on\nloc=JP", "warp=on\ncolo=NRT"] {
            XCTAssertNil(ConnectionLocation(trace: Data(trace.utf8)))
        }
    }
    func testMalformedCountryAndAirportCodeAreRejected() {
        for (country, colo) in [("ZZ", "NRT"), ("JPN", "NRT"), ("JP", "NR"), ("JP", "NRT1"), ("JP", "N R"), ("JP", "东京站")] {
            XCTAssertNil(ConnectionLocation(trace: Data("loc=\(country)\ncolo=\(colo)\nwarp=on".utf8)))
        }
    }
    func testDuplicateWarpFieldCannotHideDirectConnection() {
        XCTAssertNil(ConnectionLocation(trace: Data("loc=JP\ncolo=NRT\nwarp=on\nwarp=off\n".utf8)))
    }
    func testExitCountryIsIndependentOfDataCenterCountry() throws {
        let value = try XCTUnwrap(ConnectionLocation(trace: Data("loc=CN\ncolo=LAX\nwarp=on\n".utf8)))
        XCTAssertEqual(value.label, "国家: 🇨🇳　数据中心: LAX")
        let singapore = try XCTUnwrap(ConnectionLocation(trace: Data("loc=CN\ncolo=SIN\nwarp=plus\n".utf8)))
        XCTAssertEqual(singapore.label, "国家: 🇨🇳　数据中心: SIN")
    }
    func testUnknownAirportStillPreservesReportedExitCountry() throws {
        let value = try XCTUnwrap(ConnectionLocation(trace: Data("loc=CN\ncolo=ZZZ\nwarp=plus\n".utf8)))
        XCTAssertEqual(value.country, "CN")
        XCTAssertEqual(value.label, "国家: 🇨🇳　数据中心: ZZZ")
    }
}
