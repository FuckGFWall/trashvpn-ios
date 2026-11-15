import XCTest

final class Stage2DeviceTests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }
    func test10WGAutomaticRegistrationAndCache() throws { try prepareAndConnect("wg") }
    func test20AWGAutomaticRegistrationAndCache() throws { try prepareAndConnect("awg") }
    func test30MASQUEAutomaticRegistrationAndCache() throws { try prepareAndConnect("masque") }

    private func prepareAndConnect(_ kind: String) throws {
        let app = XCUIApplication()
        app.launchArguments = ["--protocol=\(kind)", "--family=ipv4"]
        app.launch()
        XCTAssertTrue(app.buttons["connectButton"].waitForExistence(timeout: 20))
        if app.staticTexts["vpnStatus"].label == "已连接" {
            app.buttons["connectButton"].tap()
            expectation(for: NSPredicate(format: "label == %@", "未连接"), evaluatedWith: app.staticTexts["vpnStatus"])
            waitForExpectations(timeout: 20)
        }
        // No register/scan tap: launch must drive the complete preparation automatically.
        expectation(for: NSPredicate(format: "label BEGINSWITH %@", "缓存有效至"), evaluatedWith: app.staticTexts["cacheStatus"])
        waitForExpectations(timeout: 360)
        XCTAssertEqual(app.staticTexts["vpnStatus"].label, "未连接")
        let scan = XCTAttachment(screenshot: app.screenshot())
        scan.name = "\(kind.uppercased()) automatic preparation without VPN"; scan.lifetime = .keepAlways; add(scan)

        app.terminate()
        app.launch()
        expectation(for: NSPredicate(format: "label CONTAINS %@", "无需重复注册或优选"), evaluatedWith: app.staticTexts["messageText"])
        waitForExpectations(timeout: 20)
        XCTAssertEqual(app.staticTexts["vpnStatus"].label, "未连接")
        app.buttons["connectButton"].tap()
        expectation(for: NSPredicate(format: "label == %@", "已连接"), evaluatedWith: app.staticTexts["vpnStatus"])
        waitForExpectations(timeout: 45)
        app.swipeUp()
        app.buttons["verifyButton"].tap()
        expectation(for: NSPredicate(format: "label CONTAINS %@", "WARP 已验证"), evaluatedWith: app.staticTexts["verificationResult"])
        waitForExpectations(timeout: 35)
        expectation(for: NSPredicate(format: "label == %@", "验证 WARP 出口"), evaluatedWith: app.buttons["verifyButton"])
        waitForExpectations(timeout: 15)
        let connected = XCTAttachment(screenshot: app.screenshot())
        connected.name = "\(kind.uppercased()) newly registered identity WARP verified"; connected.lifetime = .keepAlways; add(connected)
    }

    func test40ProtocolSwitchReusesItsOwnCache() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--protocol=masque", "--family=ipv4"]
        app.launch()
        XCTAssertTrue(app.buttons["connectButton"].waitForExistence(timeout: 20))
        if app.staticTexts["vpnStatus"].label == "已连接" {
            app.buttons["connectButton"].tap()
            expectation(for: NSPredicate(format: "label == %@", "未连接"), evaluatedWith: app.staticTexts["vpnStatus"])
            waitForExpectations(timeout: 20)
        }
        for kind in ["WG", "AWG", "MASQUE"] {
            let picker = app.segmentedControls["protocolPicker"]
            picker.buttons[kind].tap()
            expectation(for: NSPredicate(format: "label CONTAINS %@", "已使用 \(kind) 节点缓存"), evaluatedWith: app.staticTexts["messageText"])
            waitForExpectations(timeout: 20)
            XCTAssertTrue(app.staticTexts["cacheStatus"].label.hasPrefix("缓存有效至"))
            XCTAssertEqual(app.staticTexts["vpnStatus"].label, "未连接")
        }
    }
}
