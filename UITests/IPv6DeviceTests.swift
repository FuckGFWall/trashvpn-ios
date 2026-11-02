import XCTest

final class IPv6DeviceTests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }
    func test10WGIPv6() throws { try prepareConnectAndVerify("wg") }
    func test20AWGIPv6() throws { try prepareConnectAndVerify("awg") }
    func test30MASQUEIPv6() throws { try prepareConnectAndVerify("masque") }

    func test29MASQUEFreshIPv6Samples() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--protocol=masque", "--family=ipv6"]
        app.launch()
        XCTAssertTrue(app.buttons["connectButton"].waitForExistence(timeout: 20))
        if app.staticTexts["vpnStatus"].label == "已连接" {
            app.buttons["connectButton"].tap()
            expectation(for: NSPredicate(format: "label == %@", "未连接"), evaluatedWith: app.staticTexts["vpnStatus"])
            waitForExpectations(timeout: 20)
        }
        expectation(for: NSPredicate(format: "label CONTAINS %@", "无需重复注册或优选（IPv6）"), evaluatedWith: app.staticTexts["messageText"])
        waitForExpectations(timeout: 20)
        app.buttons["scanButton"].tap()
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            app.staticTexts["messageText"].label.contains("优选完成") || app.alerts["连接提示"].exists
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 330), .completed)
        XCTAssertFalse(app.alerts["连接提示"].exists)
        XCTAssertEqual(app.staticTexts["vpnStatus"].label, "未连接")
        XCTAssertTrue(app.staticTexts["endpointResult0"].label.contains("3/3"), app.staticTexts["endpointResult0"].label)
        attach(app, name: "MASQUE independent IPv6 samples without VPN")
    }

    private func prepareConnectAndVerify(_ kind: String) throws {
        let app = XCUIApplication()
        app.launchArguments = ["--protocol=\(kind)", "--family=ipv6"]
        app.launch()
        XCTAssertTrue(app.buttons["connectButton"].waitForExistence(timeout: 20))
        if app.staticTexts["vpnStatus"].label == "已连接" {
            app.buttons["connectButton"].tap()
            expectation(for: NSPredicate(format: "label == %@", "未连接"), evaluatedWith: app.staticTexts["vpnStatus"])
            waitForExpectations(timeout: 20)
        }
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            app.staticTexts["cacheStatus"].label.hasPrefix("缓存有效至") || app.alerts["连接提示"].exists
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 330), .completed)
        if app.alerts["连接提示"].exists {
            attach(app, name: "\(kind) IPv6 preparation failure")
            XCTFail(app.alerts["连接提示"].staticTexts.allElementsBoundByIndex.map(\.label).joined(separator: " "))
            return
        }
        XCTAssertTrue(app.staticTexts["cacheStatus"].label.contains("IPv6"))
        XCTAssertEqual(app.staticTexts["vpnStatus"].label, "未连接")
        XCTAssertTrue(app.buttons["endpoint0"].label.contains("[2606:"), app.buttons["endpoint0"].label)
        attach(app, name: "\(kind) IPv6 preparation without VPN")
        app.terminate(); app.launch()
        expectation(for: NSPredicate(format: "label CONTAINS %@", "无需重复注册或优选（IPv6）"), evaluatedWith: app.staticTexts["messageText"])
        waitForExpectations(timeout: 20)
        app.buttons["connectButton"].tap()
        expectation(for: NSPredicate(format: "label == %@", "已连接"), evaluatedWith: app.staticTexts["vpnStatus"])
        waitForExpectations(timeout: 45)
        app.swipeUp()
        try verify(app)
        XCUIDevice.shared.press(.home)
        let background = expectation(description: "IPv6 VPN remains in background")
        DispatchQueue.main.asyncAfter(deadline: .now() + 20) { background.fulfill() }
        wait(for: [background], timeout: 25)
        app.activate()
        XCTAssertEqual(app.staticTexts["vpnStatus"].label, "已连接")
        try verify(app)
        app.swipeUp()
        attach(app, name: "\(kind) IPv6 exit and IPv4 HTTPS after background")
        app.swipeDown()
        app.buttons["connectButton"].tap()
        expectation(for: NSPredicate(format: "label == %@", "未连接"), evaluatedWith: app.staticTexts["vpnStatus"])
        waitForExpectations(timeout: 20)
    }

    private func verify(_ app: XCUIApplication) throws {
        let button = app.buttons["verifyButton"]
        XCTAssertTrue(button.waitForExistence(timeout: 5)); button.tap()
        expectation(for: NSPredicate(format: "label CONTAINS %@ AND label CONTAINS %@", "IPv6 出口", "IPv4 HTTPS 可达"), evaluatedWith: app.staticTexts["verificationResult"])
        waitForExpectations(timeout: 55)
    }
    private func attach(_ app: XCUIApplication, name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }

    func test40SettingsSwitchAndIPv4CacheRemainIndependent() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--protocol=masque", "--family=ipv6"]
        app.launch()
        XCTAssertTrue(app.buttons["settingsButton"].waitForExistence(timeout: 20))
        app.buttons["settingsButton"].tap()
        let picker = app.segmentedControls["addressFamilyPicker"]
        XCTAssertTrue(picker.waitForExistence(timeout: 5))
        picker.buttons["IPv4"].tap()
        app.buttons["settingsDone"].tap()
        expectation(for: NSPredicate(format: "label BEGINSWITH %@ AND label CONTAINS %@", "缓存有效至", "IPv4"), evaluatedWith: app.staticTexts["cacheStatus"])
        waitForExpectations(timeout: 360)
        app.buttons["settingsButton"].tap(); picker.buttons["IPv6"].tap(); app.buttons["settingsDone"].tap()
        expectation(for: NSPredicate(format: "label CONTAINS %@", "无需重复注册或优选（IPv6）"), evaluatedWith: app.staticTexts["messageText"])
        waitForExpectations(timeout: 20)
        XCTAssertEqual(app.staticTexts["vpnStatus"].label, "未连接")
        app.terminate()
        app.launchArguments = ["--protocol=masque"]
        app.launch()
        expectation(for: NSPredicate(format: "label CONTAINS %@", "无需重复注册或优选（IPv6）"), evaluatedWith: app.staticTexts["messageText"])
        waitForExpectations(timeout: 20)
    }
}
