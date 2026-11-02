import XCTest

final class WARPDeviceTests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }
    func test01ForegroundProbeWithoutVPN() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--protocol=wg"]
        app.launch()
        XCTAssertTrue(app.buttons["scanButton"].waitForExistence(timeout: 15))
        if app.staticTexts["vpnStatus"].label == "已连接" {
            app.buttons["connectButton"].tap()
            expectation(for: NSPredicate(format: "label == %@", "未连接"), evaluatedWith: app.staticTexts["vpnStatus"])
            waitForExpectations(timeout: 15)
        }
        app.buttons["scanButton"].tap()
        let finished = NSPredicate(format: "label == %@", "筛选与优选")
        expectation(for: finished, evaluatedWith: app.buttons["scanButton"])
        waitForExpectations(timeout: 90)
        XCTAssertEqual(app.staticTexts["vpnStatus"].label, "未连接")
        XCTAssertTrue(app.staticTexts["messageText"].label.contains("优选完成") || app.staticTexts["messageText"].label.contains("均未通过"), app.staticTexts["messageText"].label)
        for index in 0..<3 { XCTAssertNotEqual(app.staticTexts["endpointResult\(index)"].label, "待测试") }
        XCTAssertTrue((0..<3).contains { app.staticTexts["endpointResult\($0)"].label.contains("ms") })
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "Foreground probe completed without VPN"; shot.lifetime = .keepAlways; add(shot)
    }

    func test01ProbeSuspendsInBackground() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--protocol=wg"]
        app.launch()
        XCTAssertTrue(app.buttons["scanButton"].waitForExistence(timeout: 15))
        app.buttons["scanButton"].tap()
        expectation(for: NSPredicate(format: "label CONTAINS %@", "停止"), evaluatedWith: app.buttons["scanButton"])
        waitForExpectations(timeout: 5)
        XCUIDevice.shared.press(.home)
        let delay = expectation(description: "Bounded foreground probe cleanup")
        DispatchQueue.main.asyncAfter(deadline: .now() + 12) { delay.fulfill() }
        wait(for: [delay], timeout: 17)
        app.activate()
        expectation(for: NSPredicate(format: "label == %@", "筛选与优选"), evaluatedWith: app.buttons["scanButton"])
        waitForExpectations(timeout: 15)
        XCTAssertEqual(app.staticTexts["vpnStatus"].label, "未连接")
        XCTAssertTrue(app.staticTexts["messageText"].label.contains("已暂停"))
    }

    func test02ConnectVerifyAndBackground() throws {
        let app = XCUIApplication()
        // Pin the end-to-end acceptance test to the endpoint already verified on Richard.
        // Endpoint ranking is independently exercised by test01ForegroundProbeWithoutVPN.
        app.launchArguments = ["--endpoint=8.39.125.159:2408"]
        app.launch()
        XCTAssertTrue(app.buttons["connectButton"].waitForExistence(timeout: 15))
        if app.staticTexts["vpnStatus"].label == "已连接" {
            app.buttons["connectButton"].tap()
            expectation(for: NSPredicate(format: "label == %@", "未连接"), evaluatedWith: app.staticTexts["vpnStatus"])
            waitForExpectations(timeout: 15)
        }
        addUIInterruptionMonitor(withDescription: "VPN permission") { alert in
            for title in ["Allow", "允许"] where alert.buttons[title].exists { alert.buttons[title].tap(); return true }
            return false
        }
        app.buttons["connectButton"].tap()
        app.staticTexts["TrashVPN"].tap()
        let connected = NSPredicate(format: "label == %@", "已连接")
        expectation(for: connected, evaluatedWith: app.staticTexts["vpnStatus"])
        waitForExpectations(timeout: 60)
        app.swipeUp()
        app.buttons["verifyButton"].tap()
        let verified = NSPredicate(format: "label CONTAINS %@", "WARP 已验证")
        expectation(for: verified, evaluatedWith: app.staticTexts["verificationResult"])
        waitForExpectations(timeout: 30)
        XCUIDevice.shared.press(.home)
        // Keep the app suspended long enough to exercise the independent extension.
        let delay = expectation(description: "Background tunnel remains running")
        DispatchQueue.main.asyncAfter(deadline: .now() + 20) { delay.fulfill() }
        wait(for: [delay], timeout: 25)
        app.activate()
        XCTAssertEqual(app.staticTexts["vpnStatus"].label, "已连接")
        // Discard the previous success before checking the second request.
        app.buttons["verifyButton"].tap()
        expectation(for: verified, evaluatedWith: app.staticTexts["verificationResult"])
        waitForExpectations(timeout: 30)
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "WARP verified after background"; shot.lifetime = .keepAlways; add(shot)
    }
}
