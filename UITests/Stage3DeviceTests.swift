import XCTest

final class Stage3DeviceTests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    private func launch(_ kind: String = "wg", reset: Bool = true, fixture: [String: Any]? = nil) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--protocol=\(kind)", "--family=ipv4"] + (reset ? ["--default-settings"] : [])
        if let fixture { app.launchArguments.append("--settings-json=" + (try! JSONSerialization.data(withJSONObject: fixture)).base64EncodedString()) }
        app.launch()
        XCTAssertTrue(app.buttons["connectButton"].waitForExistence(timeout: 20))
        if app.staticTexts["vpnStatus"].label == "已连接" {
            app.buttons["connectButton"].tap()
            expectation(for: NSPredicate(format: "label == %@", "未连接"), evaluatedWith: app.staticTexts["vpnStatus"])
            waitForExpectations(timeout: 20)
        }
        return app
    }
    private func waitReady(_ app: XCUIApplication, timeout: TimeInterval = 240) {
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            app.staticTexts["progressStage"].label == "连接已就绪" || app.alerts["连接提示"].exists
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: timeout), .completed)
        XCTAssertFalse(app.alerts["连接提示"].exists, app.alerts.debugDescription)
    }
    private func saveSettings(_ app: XCUIApplication) {
        app.buttons["settingsDone"].tap()
        expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: app.buttons["settingsDone"])
        waitForExpectations(timeout: 10)
        XCTAssertFalse(app.alerts["设置提示"].exists)
    }
    private func showSettings(_ app: XCUIApplication) { app.buttons["settingsButton"].tap() }
    private func visible(_ element: XCUIElement, app: XCUIApplication) -> Bool {
        guard element.exists else { return false }
        let frame = element.frame
        let bottom = app.keyboards.firstMatch.exists ? app.keyboards.firstMatch.frame.minY : app.frame.maxY - 35
        return frame.height > 0 && frame.midY > app.frame.minY + 110 && frame.midY < bottom - 10
    }
    private func reveal(_ element: XCUIElement, app: XCUIApplication) {
        let settled = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in self.visible(element, app: app) }, object: nil)
        if XCTWaiter.wait(for: [settled], timeout: 1) == .completed { return }
        for _ in 0..<6 {
            if visible(element, app: app) { return }
            app.swipeUp()
        }
        for _ in 0..<7 {
            if visible(element, app: app) { return }
            app.swipeDown()
        }
        XCTAssertTrue(visible(element, app: app), element.debugDescription)
    }
    private func fill(_ element: XCUIElement, _ value: String, app: XCUIApplication) {
        reveal(element, app: app)
        element.tap()
        let old = element.value as? String ?? ""
        if element.elementType == .textField { element.coordinate(withNormalizedOffset: CGVector(dx: 0.96, dy: 0.5)).tap() }
        element.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: old.count + 2) + value)
        XCTAssertEqual(element.value as? String, value)
        if app.buttons["keyboardDone"].waitForExistence(timeout: 2) { app.buttons["keyboardDone"].tap() }
    }
    private func shot(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot()); attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }
    private func verify(_ app: XCUIApplication) {
        reveal(app.buttons["verifyButton"], app: app)
        app.buttons["verifyButton"].tap()
        expectation(for: NSPredicate(format: "label CONTAINS %@", "WARP 已验证"), evaluatedWith: app.staticTexts["verificationResult"])
        waitForExpectations(timeout: 55)
    }
    private func connect(_ app: XCUIApplication) {
        app.buttons["connectButton"].tap()
        expectation(for: NSPredicate(format: "label == %@", "已连接"), evaluatedWith: app.staticTexts["vpnStatus"])
        waitForExpectations(timeout: 45)
    }
    private func disconnect(_ app: XCUIApplication) {
        for _ in 0..<6 {
            if visible(app.buttons["connectButton"], app: app) { break }
            app.swipeDown()
        }
        XCTAssertTrue(visible(app.buttons["connectButton"], app: app))
        app.buttons["connectButton"].tap()
        expectation(for: NSPredicate(format: "label == %@", "未连接"), evaluatedWith: app.staticTexts["vpnStatus"])
        waitForExpectations(timeout: 20)
    }

    func test10CollapsedNodesAndAutomaticFirstChoice() throws {
        let app = launch()
        waitReady(app)
        XCTAssertFalse(app.segmentedControls["protocolPicker"].exists)
        XCTAssertFalse(app.buttons["automaticNode"].exists)
        XCTAssertTrue(app.otherElements["preparationProgress"].exists || app.descendants(matching: .any)["preparationProgress"].exists)
        shot(app, "Home unified progress and collapsed nodes")
        app.descendants(matching: .any)["nodeDisclosure"].firstMatch.tap()
        XCTAssertTrue(app.buttons["automaticNode"].waitForExistence(timeout: 5))
        XCTAssertLessThan(app.buttons["automaticNode"].frame.minY, app.buttons["endpoint0"].frame.minY)
        app.buttons["endpoint0"].tap()
        XCTAssertEqual(app.buttons["endpoint0"].value as? String, "已选择")
        app.buttons["automaticNode"].tap()
        XCTAssertEqual(app.buttons["automaticNode"].value as? String, "已选择")
        shot(app, "Automatic selection fixed as first node")
        app.terminate(); app.launch()
        waitReady(app)
        XCTAssertFalse(app.buttons["automaticNode"].exists)
    }

    func test20SettingsThemeValidationAndCustomNetwork() throws {
        let app = launch("awg")
        waitReady(app)
        showSettings(app)
        XCTAssertTrue(app.segmentedControls["protocolPicker"].exists)
        app.buttons["themePicker"].tap(); app.buttons["浅色"].tap()
        shot(app, "Settings light theme")
        app.buttons["themePicker"].tap(); app.buttons["深色"].tap()
        shot(app, "Settings dark theme")
        fill(app.textFields["mtuField"], "1279", app: app)
        app.buttons["settingsDone"].tap()
        XCTAssertTrue(app.alerts["设置提示"].waitForExistence(timeout: 5))
        app.alerts["设置提示"].buttons["好"].tap()
        fill(app.textFields["mtuField"], "1400", app: app)
        fill(app.textViews["customDNSField"], "https://1.1.1.1/dns-query", app: app)
        reveal(app.segmentedControls["strengthPicker"], app: app)
        app.segmentedControls["strengthPicker"].buttons["低"].tap()
        app.buttons["cacheHoursPicker"].tap(); app.buttons["48 小时"].tap()
        fill(app.textFields["timeoutField"], "7", app: app)
        shot(app, "Settings DNS strength 48-hour cache and timeout")
        saveSettings(app)
        waitReady(app)
        shot(app, "Custom configuration preparation completed")
        app.terminate()
        app.launchArguments = ["--protocol=awg", "--family=ipv4"]
        app.launch(); waitReady(app)
        showSettings(app)
        XCTAssertEqual(app.textFields["mtuField"].value as? String, "1400")
        reveal(app.textFields["timeoutField"], app: app)
        XCTAssertEqual(app.textFields["timeoutField"].value as? String, "7")
        app.buttons["settingsClose"].tap()
    }

    func test30CustomDNSAndMTUTunnelAndBackground() throws {
        let app = launch("awg", reset: false, fixture: ["tunnelProtocol": "awg", "theme": "dark", "addressFamily": "ipv4", "mtu": 1400,
            "customDNS": "https://1.1.1.1/dns-query", "dnsLeakProtection": true, "doNotSetDNS": false, "strength": "low", "cacheHours": 48, "probeTimeout": 7])
        waitReady(app)
        connect(app); verify(app)
        XCUIDevice.shared.press(.home)
        let background = expectation(description: "Configured tunnel background")
        DispatchQueue.main.asyncAfter(deadline: .now() + 15) { background.fulfill() }
        wait(for: [background], timeout: 20)
        app.activate(); verify(app)
        shot(app, "Configured MTU and protected custom DNS WARP after background")
        disconnect(app)
    }

    func test40GranularProgressAndPauseWithoutVPN() throws {
        let app = launch("wg")
        waitReady(app)
        showSettings(app)
        app.segmentedControls["addressFamilyPicker"].buttons["IPv6"].tap()
        reveal(app.segmentedControls["strengthPicker"], app: app)
        app.segmentedControls["strengthPicker"].buttons["低"].tap()
        fill(app.textFields["timeoutField"], "1", app: app)
        saveSettings(app)
        expectation(for: NSPredicate(format: "label MATCHES %@", "初筛端点 [2-9].*"), evaluatedWith: app.staticTexts["progressStage"])
        waitForExpectations(timeout: 20)
        shot(app, "Granular endpoint screening without enabling VPN")
        app.buttons["scanButton"].tap()
        expectation(for: NSPredicate(format: "label == %@", "已暂停"), evaluatedWith: app.staticTexts["progressStage"])
        waitForExpectations(timeout: 10)
        XCTAssertEqual(app.staticTexts["vpnStatus"].label, "未连接")
        shot(app, "Preparation paused with registration milestone retained")
    }

    func test50NoDNSIssuedAndNextConnectionSettings() throws {
        let app = launch("awg", reset: false, fixture: ["tunnelProtocol": "awg", "theme": "system", "addressFamily": "ipv4", "mtu": 0,
            "customDNS": "", "dnsLeakProtection": true, "doNotSetDNS": false, "strength": "low", "cacheHours": 6, "probeTimeout": 7])
        waitReady(app)
        showSettings(app)
        reveal(app.switches["noDNSSwitch"], app: app)
        app.switches["noDNSSwitch"].coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.5)).tap()
        expectation(for: NSPredicate(format: "value == %@", "0"), evaluatedWith: app.switches["dnsLeakSwitch"])
        waitForExpectations(timeout: 5)
        reveal(app.segmentedControls["strengthPicker"], app: app)
        app.segmentedControls["strengthPicker"].buttons["低"].tap()
        fill(app.textFields["timeoutField"], "7", app: app)
        saveSettings(app)
        waitReady(app)
        connect(app); verify(app)
        showSettings(app)
        XCTAssertFalse(app.segmentedControls["protocolPicker"].isEnabled)
        fill(app.textFields["mtuField"], "1360", app: app)
        saveSettings(app)
        verify(app)
        shot(app, "System DNS retained and active tunnel settings preserved")
        disconnect(app)
        waitReady(app)
        connect(app); verify(app)
        showSettings(app)
        reveal(app.buttons["diagnosticsButton"], app: app)
        app.buttons["diagnosticsButton"].tap()
        expectation(for: NSPredicate(format: "label CONTAINS %@", "Provider MTU: 1360"), evaluatedWith: app.descendants(matching: .any)["diagnosticText"].firstMatch)
        waitForExpectations(timeout: 10)
        shot(app, "New connection applied MTU 1360 and no issued DNS")
    }

    func test60MASQUEHostnameDNSAndProtocolOnlyInSettings() throws {
        let app = launch("masque")
        waitReady(app)
        showSettings(app)
        app.segmentedControls["protocolPicker"].buttons["WG"].tap()
        app.segmentedControls["protocolPicker"].buttons["MASQUE"].tap()
        fill(app.textViews["customDNSField"], "https://cloudflare-dns.com/dns-query", app: app)
        reveal(app.segmentedControls["strengthPicker"], app: app)
        app.segmentedControls["strengthPicker"].buttons["低"].tap()
        app.buttons["cacheHoursPicker"].tap(); app.buttons["12 小时"].tap()
        fill(app.textFields["timeoutField"], "10", app: app)
        saveSettings(app)
        waitReady(app)
        XCTAssertFalse(app.segmentedControls["protocolPicker"].exists)
        connect(app); verify(app)
        shot(app, "MASQUE with hostname DoH and protected bootstrap DNS")
        disconnect(app)
    }
    func test80StrongerSelectionWithRealDownload() throws {
        try checkStrongerSelection(strength: "low", mtu: 1280, timeout: 10)
    }

    func test85MASQUEMediumSelectionWithRealDownload() throws {
        try checkStrongerSelection(kind: "masque", strength: "medium", mtu: 1280, timeout: 10)
    }

    func test90HighSelectionWithCustomMTU() throws {
        try checkStrongerSelection(strength: "high", mtu: 1360, timeout: 7)
    }

    private func checkStrongerSelection(kind: String = "awg", strength: String, mtu: Int, timeout: Int) throws {
        let app = launch(kind, reset: false, fixture: ["tunnelProtocol": kind, "theme": "system", "addressFamily": "ipv4", "mtu": mtu,
            "customDNS": "", "dnsLeakProtection": true, "doNotSetDNS": false, "strength": strength, "cacheHours": 6, "probeTimeout": timeout])
        waitReady(app, timeout: 900)
        app.descendants(matching: .any)["nodeDisclosure"].firstMatch.tap()
        XCTAssertTrue(app.staticTexts["endpointResult0"].label.contains("Mbps"))
        shot(app, "Qualified nodes after stability YouTube and download tests")
        connect(app); verify(app)
        shot(app, "Stronger automatic selection WARP verified")
        disconnect(app)
    }

}
