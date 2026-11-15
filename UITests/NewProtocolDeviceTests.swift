import XCTest

final class NewProtocolDeviceTests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    func test10AWGForegroundScan() throws { try scan(kind: "awg") }
    func test11AWGTunnelAndBackground() throws { try connectAndVerify(kind: "awg") }
    func test20MASQUEForegroundScan() throws { try scan(kind: "masque") }
    func test21MASQUETunnelAndBackground() throws { try connectAndVerify(kind: "masque") }

    private func launch(kind: String) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--protocol=\(kind)"]
        app.launch()
        XCTAssertTrue(app.buttons["connectButton"].waitForExistence(timeout: 15))
        if app.staticTexts["vpnStatus"].label == "已连接" {
            app.buttons["connectButton"].tap()
            expectation(for: NSPredicate(format: "label == %@", "未连接"), evaluatedWith: app.staticTexts["vpnStatus"])
            waitForExpectations(timeout: 15)
        }
        return app
    }

    private func scan(kind: String) throws {
        let app = launch(kind: kind)
        app.buttons["scanButton"].tap()
        expectation(for: NSPredicate(format: "label == %@", "筛选与优选"), evaluatedWith: app.buttons["scanButton"])
        waitForExpectations(timeout: 100)
        XCTAssertEqual(app.staticTexts["vpnStatus"].label, "未连接")
        XCTAssertTrue(app.staticTexts["messageText"].label.contains("优选完成"), app.staticTexts["messageText"].label)
        XCTAssertTrue((0..<4).contains { app.staticTexts["endpointResult\($0)"].label.contains("ms") })
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "\(kind.uppercased()) scan without VPN"; shot.lifetime = .keepAlways; add(shot)
    }

    private func connectAndVerify(kind: String) throws {
        let app = launch(kind: kind)
        addUIInterruptionMonitor(withDescription: "VPN permission") { alert in
            for title in ["Allow", "允许"] where alert.buttons[title].exists { alert.buttons[title].tap(); return true }
            return false
        }
        app.buttons["connectButton"].tap()
        app.staticTexts["TrashVPN"].tap()
        expectation(for: NSPredicate(format: "label == %@", "已连接"), evaluatedWith: app.staticTexts["vpnStatus"])
        waitForExpectations(timeout: 45)
        app.swipeUp()
        try verify(app)
        XCUIDevice.shared.press(.home)
        let delay = expectation(description: "\(kind) background tunnel")
        DispatchQueue.main.asyncAfter(deadline: .now() + 20) { delay.fulfill() }
        wait(for: [delay], timeout: 25)
        app.activate()
        XCTAssertEqual(app.staticTexts["vpnStatus"].label, "已连接")
        try verify(app)
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "\(kind.uppercased()) WARP verified after background"; shot.lifetime = .keepAlways; add(shot)
    }

    private func verify(_ app: XCUIApplication) throws {
        app.buttons["verifyButton"].tap()
        expectation(for: NSPredicate(format: "label CONTAINS %@", "WARP 已验证"), evaluatedWith: app.staticTexts["verificationResult"])
        waitForExpectations(timeout: 30)
    }
}
