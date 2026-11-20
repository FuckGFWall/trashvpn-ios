import XCTest

final class Stage3DeviceTests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    // Authorize UI automation before implementation work without opening the app or VPN.
    func test000AutomationUnlockWarmup() {}

    private func launch(_ kind: String = "wg", reset: Bool = true, fixture: [String: Any]? = nil, extraArguments: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--protocol=\(kind)", "--family=ipv4"] + (reset ? ["--default-settings"] : []) + extraArguments
        if let fixture { app.launchArguments.append("--settings-json=" + (try! JSONSerialization.data(withJSONObject: fixture)).base64EncodedString()) }
        app.launch()
        XCTAssertTrue(app.buttons["connectButton"].waitForExistence(timeout: 20))
        if app.buttons["connectButton"].value as? String == "已连接" {
            app.buttons["connectButton"].tap()
            expectation(for: NSPredicate(format: "value == %@", "未连接"), evaluatedWith: app.buttons["connectButton"])
            waitForExpectations(timeout: 20)
        }
        return app
    }
    private func waitReady(_ app: XCUIApplication, timeout: TimeInterval = 240) {
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            app.staticTexts["progressStage"].label.contains("连接已就绪") || app.alerts["连接提示"].exists
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: timeout), .completed)
        XCTAssertFalse(app.alerts["连接提示"].exists, app.alerts.debugDescription)
    }
    private func settingsBack(_ app: XCUIApplication) -> XCUIElement {
        app.navigationBars.matching(NSPredicate(format: "identifier IN %@", ["设置", "設置", "Settings", "تنظیمات"]))
            .firstMatch.buttons.firstMatch
    }

    // Settings now save automatically; legacy scenarios use this helper to return home.
    private func saveSettings(_ app: XCUIApplication) {
        self.settingsBack(app).coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        let saved = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            !self.settingsBack(app).exists || app.alerts["设置提示"].exists
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [saved], timeout: 10), .completed)
        XCTAssertFalse(app.alerts["设置提示"].exists, app.alerts["设置提示"].debugDescription)
    }
    private func showSettings(_ app: XCUIApplication) {
        let button = app.buttons["settingsButton"]
        button.tap()
        if !self.settingsBack(app).waitForExistence(timeout: 3) {
            // A floating system control may cover the center of the navigation item.
            button.coordinate(withNormalizedOffset: CGVector(dx: 0.05, dy: 0.95)).tap()
        }
        if !self.settingsBack(app).waitForExistence(timeout: 3), button.exists {
            button.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
                .press(forDuration: 1, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.94, dy: 0.9)))
            app.activate()
            button.tap()
        }
        XCTAssertTrue(self.settingsBack(app).waitForExistence(timeout: 5), app.debugDescription)
    }
    private func openMenu(_ identifier: String, option: String, app: XCUIApplication) {
        let menu = app.buttons[identifier], choice = app.buttons[option]
        reveal(menu, app: app)
        let rtl = app.navigationBars["تنظیمات"].exists
        let point = CGVector(dx: rtl ? 0.06 : 0.94, dy: 0.5)
        menu.coordinate(withNormalizedOffset: point).tap()
        if !choice.waitForExistence(timeout: 3) {
            menu.coordinate(withNormalizedOffset: point).tap()
        }
        XCTAssertTrue(choice.waitForExistence(timeout: 3))
    }
    private func visible(_ element: XCUIElement, app: XCUIApplication) -> Bool {
        guard element.exists else { return false }
        let frame = element.frame
        let bottom = app.keyboards.firstMatch.exists ? app.keyboards.firstMatch.frame.minY : app.frame.maxY - 35
        return frame.height > 0 && frame.midY > app.frame.minY + 110 && frame.midY < bottom - 10
    }
    private func reveal(_ element: XCUIElement, app: XCUIApplication) {
        if visible(element, app: app) { return }
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
        if element.elementType == .textField && element.identifier != "customDNSField" {
            element.coordinate(withNormalizedOffset: CGVector(dx: -0.55, dy: 0.5)).tap()
        } else {
            element.tap()
        }
        let old = element.value as? String ?? ""
        element.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: old.count + 2) + value)
        XCTAssertEqual(element.value as? String, value)
        if app.buttons["keyboardDone"].waitForExistence(timeout: 2) { app.buttons["keyboardDone"].tap() }
    }
    private func tapCacheNeverExpires(_ app: XCUIApplication) {
        let toggle = app.switches["cacheNeverExpiresSwitch"]
        reveal(toggle, app: app)
        toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
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
        expectation(for: NSPredicate(format: "value == %@", "已连接"), evaluatedWith: app.buttons["connectButton"])
        waitForExpectations(timeout: 45)
    }
    private func disconnect(_ app: XCUIApplication) {
        for _ in 0..<6 {
            if visible(app.buttons["connectButton"], app: app) { break }
            app.swipeDown()
        }
        XCTAssertTrue(visible(app.buttons["connectButton"], app: app))
        app.buttons["connectButton"].tap()
        expectation(for: NSPredicate(format: "value == %@", "未连接"), evaluatedWith: app.buttons["connectButton"])
        waitForExpectations(timeout: 20)
    }

    func test10CollapsedNodesAndAutomaticFirstChoice() throws {
        let app = launch()
        waitReady(app)
        XCTAssertFalse(app.buttons["protocolPicker"].exists)
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
        XCTAssertTrue(app.buttons["protocolPicker"].exists)
        app.buttons["themePicker"].tap(); app.buttons["浅色"].tap()
        shot(app, "Settings light theme")
        app.buttons["themePicker"].tap(); app.buttons["深色"].tap()
        shot(app, "Settings dark theme")
        fill(app.textFields["mtuField"], "1279", app: app)
        XCTAssertTrue(app.staticTexts["settingsInputError"].waitForExistence(timeout: 5))
        fill(app.textFields["mtuField"], "1400", app: app)
        fill(app.descendants(matching: .any)["customDNSField"].firstMatch, "https://1.1.1.1/dns-query", app: app)
        reveal(app.buttons["strengthPicker"], app: app)
        openMenu("strengthPicker", option: "低", app: app); app.buttons["低"].tap()
        fill(app.textFields["cacheDaysField"], "2", app: app)
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
        self.settingsBack(app).coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
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
        app.buttons["addressFamilyPicker"].tap(); app.buttons["IPv6"].tap()
        reveal(app.buttons["strengthPicker"], app: app)
        openMenu("strengthPicker", option: "低", app: app); app.buttons["低"].tap()
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
        reveal(app.buttons["strengthPicker"], app: app)
        openMenu("strengthPicker", option: "低", app: app); app.buttons["低"].tap()
        fill(app.textFields["timeoutField"], "7", app: app)
        saveSettings(app)
        waitReady(app)
        connect(app); verify(app)
        showSettings(app)
        XCTAssertFalse(app.buttons["protocolPicker"].isEnabled)
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
        app.buttons["protocolPicker"].tap(); app.buttons["WG"].tap()
        app.buttons["protocolPicker"].tap(); app.buttons["MASQUE"].tap()
        fill(app.descendants(matching: .any)["customDNSField"].firstMatch, "https://cloudflare-dns.com/dns-query", app: app)
        reveal(app.buttons["strengthPicker"], app: app)
        openMenu("strengthPicker", option: "低", app: app); app.buttons["低"].tap()
        fill(app.textFields["cacheDaysField"], "1", app: app)
        fill(app.textFields["timeoutField"], "10", app: app)
        saveSettings(app)
        waitReady(app)
        XCTAssertFalse(app.buttons["protocolPicker"].exists)
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

    private func readCheckpoint(_ app: XCUIApplication) throws -> ([String: Any], String) {
        showSettings(app)
        reveal(app.buttons["diagnosticsButton"], app: app)
        app.buttons["diagnosticsButton"].tap()
        let text = app.descendants(matching: .any)["diagnosticText"].firstMatch
        expectation(for: NSPredicate(format: "label CONTAINS %@", "Checkpoint: "), evaluatedWith: text)
        waitForExpectations(timeout: 10)
        let report = text.label
        let line = try XCTUnwrap(report.components(separatedBy: "\n").first(where: { $0.hasPrefix("Checkpoint: ") }))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(line.dropFirst("Checkpoint: ".count).utf8)) as? [String: Any])
        app.navigationBars["连接诊断"].buttons.element(boundBy: 0).tap()
        self.settingsBack(app).coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: self.settingsBack(app))
        waitForExpectations(timeout: 10)
        return (object, report)
    }

    private func tapScan(_ app: XCUIApplication) {
        let button = app.buttons["scanButton"]
        reveal(button, app: app)
        XCTAssertTrue(button.isEnabled)
        button.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
    }

    private func pauseScan(_ app: XCUIApplication) {
        expectation(for: NSPredicate(format: "label == %@", "暂停"), evaluatedWith: app.buttons["scanButton"])
        waitForExpectations(timeout: 20)
        tapScan(app)
        expectation(for: NSPredicate(format: "label == %@", "已暂停"), evaluatedWith: app.staticTexts["progressStage"])
        waitForExpectations(timeout: 15)
    }

    func test95HomeContinuesAndScreeningSurvivesProcessTermination() throws {
        let app = launch("wg", reset: false, fixture: ["tunnelProtocol": "wg", "theme": "system", "addressFamily": "ipv4", "mtu": 1280,
            "customDNS": "", "dnsLeakProtection": true, "doNotSetDNS": false, "strength": "high", "cacheHours": 6, "probeTimeout": 1])
        expectation(for: NSPredicate(format: "label MATCHES %@", "初筛端点 [2-9].*"), evaluatedWith: app.staticTexts["progressStage"])
        waitForExpectations(timeout: 45)
        pauseScan(app)
        let (before, _) = try readCheckpoint(app)
        XCTAssertEqual(app.buttons["scanButton"].label, "继续优选")
        tapScan(app)
        expectation(for: NSPredicate(format: "label == %@", "暂停"), evaluatedWith: app.buttons["scanButton"])
        waitForExpectations(timeout: 10)
        XCUIDevice.shared.press(.home)
        let background = expectation(description: "Continue actual screening while at Home")
        DispatchQueue.main.asyncAfter(deadline: .now() + 6) { background.fulfill() }
        wait(for: [background], timeout: 10)
        app.activate()
        pauseScan(app)
        let (afterHome, log) = try readCheckpoint(app)
        XCTAssertEqual(afterHome["id"] as? String, before["id"] as? String)
        XCTAssertGreaterThan((afterHome["screeningRounds"] as? Int) ?? 0, (before["screeningRounds"] as? Int) ?? 0)
        XCTAssertTrue(log.contains("background measurement saved"))
        shot(app, "Home background work and durable screening checkpoint")
        tapScan(app)
        app.terminate()
        app.launchArguments = []; app.launch()
        XCTAssertTrue(app.buttons["scanButton"].waitForExistence(timeout: 20))
        pauseScan(app)
        let (relaunched, _) = try readCheckpoint(app)
        XCTAssertEqual(relaunched["id"] as? String, before["id"] as? String)
        XCTAssertGreaterThanOrEqual((relaunched["screeningRounds"] as? Int) ?? 0, (afterHome["screeningRounds"] as? Int) ?? 0)
        XCTAssertEqual(relaunched["startedAt"] as? Double, before["startedAt"] as? Double)
        XCTAssertEqual(app.staticTexts["vpnStatus"].label, "未连接")
        shot(app, "Screening resumed after process termination without VPN")
    }

    func test96DownloadRoundsSurviveProcessTerminationAndFinish() throws {
        let app = launch("masque", reset: false, fixture: ["tunnelProtocol": "masque", "theme": "system", "addressFamily": "ipv4", "mtu": 1280,
            "customDNS": "", "dnsLeakProtection": true, "doNotSetDNS": false, "strength": "medium", "cacheHours": 6, "probeTimeout": 10])
        if app.buttons["scanButton"].label != "暂停" { tapScan(app) }
        var before: [String: Any] = [:]
        for _ in 0..<6 {
            expectation(for: NSPredicate(format: "label BEGINSWITH %@", "下载测速 2/"), evaluatedWith: app.staticTexts["progressStage"])
            waitForExpectations(timeout: 900)
            pauseScan(app)
            (before, _) = try readCheckpoint(app)
            if (before["downloadRounds"] as? Int ?? 0) > 0 { break }
            tapScan(app)
        }
        XCTAssertGreaterThan((before["downloadRounds"] as? Int) ?? 0, 0)
        XCTAssertLessThan((before["downloadRounds"] as? Int) ?? 0, 3)
        shot(app, "Partial download rounds committed before process termination")
        tapScan(app)
        app.terminate()
        app.launchArguments = []; app.launch()
        XCTAssertTrue(app.buttons["scanButton"].waitForExistence(timeout: 20))
        pauseScan(app)
        let (recovered, _) = try readCheckpoint(app)
        XCTAssertEqual(recovered["id"] as? String, before["id"] as? String)
        XCTAssertEqual(recovered["screeningRounds"] as? Int, before["screeningRounds"] as? Int)
        XCTAssertGreaterThanOrEqual((recovered["completedNodes"] as? Int) ?? 0, (before["completedNodes"] as? Int) ?? 0)
        XCTAssertGreaterThanOrEqual((recovered["totalDownloadRounds"] as? Int) ?? 0, (before["totalDownloadRounds"] as? Int) ?? 0)
        XCTAssertGreaterThanOrEqual((recovered["fraction"] as? Double) ?? 0, (before["fraction"] as? Double) ?? 0)
        shot(app, "Download checkpoint recovered after process termination")
        tapScan(app)
        waitReady(app, timeout: 900)
        connect(app); verify(app)
        shot(app, "Resumed optimization completed and WARP verified")
        disconnect(app)
    }

    func test97SystemBackgroundExpiryResumesSameScan() throws {
        let app = launch("wg", reset: false, fixture: ["tunnelProtocol": "wg", "theme": "system", "addressFamily": "ipv4", "mtu": 1280,
            "customDNS": "", "dnsLeakProtection": true, "doNotSetDNS": false, "strength": "high", "cacheHours": 6, "probeTimeout": 1],
            extraArguments: ["--test-background-expiry=3"])
        pauseScan(app)
        let (before, _) = try readCheckpoint(app)
        tapScan(app)
        XCUIDevice.shared.press(.home)
        let background = expectation(description: "Allow iOS background execution budget to expire")
        DispatchQueue.main.asyncAfter(deadline: .now() + 6) { background.fulfill() }
        wait(for: [background], timeout: 10)
        app.activate()
        pauseScan(app)
        let (after, report) = try readCheckpoint(app)
        XCTAssertEqual(after["id"] as? String, before["id"] as? String)
        XCTAssertEqual(after["startedAt"] as? Double, before["startedAt"] as? Double)
        XCTAssertGreaterThanOrEqual((after["screeningRounds"] as? Int) ?? 0, (before["screeningRounds"] as? Int) ?? 0)
        XCTAssertTrue(report.contains("background time expired; preparation paused with durable checkpoint"))
        XCTAssertEqual(app.staticTexts["vpnStatus"].label, "未连接")
        shot(app, "System background expiration resumed original checkpoint")
    }

    func test100PermanentCacheAndProtocolFilteredExport() throws {
        let app = launch("masque", reset: false, fixture: ["tunnelProtocol": "masque", "theme": "system", "addressFamily": "ipv4", "mtu": 1280,
            "customDNS": "", "dnsLeakProtection": true, "doNotSetDNS": false, "strength": "medium", "cacheHours": 6, "probeTimeout": 10])
        waitReady(app)
        showSettings(app)
        tapCacheNeverExpires(app)
        saveSettings(app); waitReady(app, timeout: 10)
        XCTAssertTrue(app.staticTexts["cacheStatus"].label.contains("永不过期"))
        shot(app, "Permanent cache displayed on home")
        showSettings(app)
        reveal(app.buttons["exportFormatMenu"], app: app)
        app.buttons["exportFormatMenu"].tap()
        XCTAssertFalse(app.buttons["V2Ray"].exists)
        XCTAssertFalse(app.buttons["sing-box"].exists)
        try XCTUnwrap(app.buttons.matching(NSPredicate(format: "label == %@", "Clash")).allElementsBoundByIndex.last).tap()
        XCTAssertTrue(app.buttons["copyNodesButton"].isEnabled)
        app.buttons["copyNodesButton"].tap()
        XCTAssertEqual(app.buttons["copyNodesButton"].label, "已复制")
        XCTAssertTrue(app.staticTexts["exportStatus"].label.hasPrefix("复制本地缓存中的 "))
        shot(app, "MASQUE Clash export copied from local cache")

        let picker = app.buttons["protocolPicker"]
        for _ in 0..<7 where !visible(picker, app: app) { app.swipeDown() }
        picker.tap(); app.buttons["WG"].tap()
        reveal(app.buttons["exportFormatMenu"], app: app)
        app.buttons["exportFormatMenu"].tap()
        XCTAssertTrue(app.buttons["V2Ray"].exists)
        XCTAssertTrue(app.buttons["sing-box"].exists)
        app.buttons["V2Ray"].tap()
        XCTAssertEqual(app.buttons["exportFormatMenu"].value as? String, "V2Ray")
        shot(app, "WireGuard exposes all three export formats")

        for _ in 0..<7 where !visible(picker, app: app) { app.swipeDown() }
        picker.tap(); app.buttons["AWG"].tap()
        reveal(app.buttons["exportFormatMenu"], app: app)
        XCTAssertEqual(app.buttons["exportFormatMenu"].value as? String, "Clash")
        app.buttons["exportFormatMenu"].tap()
        XCTAssertFalse(app.buttons["V2Ray"].exists)
        XCTAssertFalse(app.buttons["sing-box"].exists)
        try XCTUnwrap(app.buttons.matching(NSPredicate(format: "label == %@", "Clash")).allElementsBoundByIndex.last).tap()
        shot(app, "AWG filters unsupported export formats")

        for _ in 0..<7 where !visible(picker, app: app) { app.swipeDown() }
        picker.tap(); app.buttons["MASQUE"].tap()
        reveal(app.buttons["strengthPicker"], app: app)
        openMenu("strengthPicker", option: "高", app: app); app.buttons["高"].tap()
        fill(app.textFields["timeoutField"], "9", app: app)
        saveSettings(app); waitReady(app, timeout: 10)
        XCTAssertTrue(app.staticTexts["cacheStatus"].label.contains("永不过期"))
        app.terminate(); app.launchArguments = []; app.launch(); waitReady(app, timeout: 10)
        XCTAssertTrue(app.staticTexts["cacheStatus"].label.contains("永不过期"))
        connect(app); verify(app)
        shot(app, "Permanent cache reused after settings change relaunch and VPN connection")
        disconnect(app)
    }

    private func qualityCache(_ app: XCUIApplication) throws -> ([String: Any], String) {
        showSettings(app)
        reveal(app.buttons["diagnosticsButton"], app: app)
        app.buttons["diagnosticsButton"].tap()
        let text = app.descendants(matching: .any)["diagnosticText"].firstMatch
        expectation(for: NSPredicate(format: "label CONTAINS %@", "Quality cache: "), evaluatedWith: text)
        waitForExpectations(timeout: 10)
        let report = text.label
        let line = try XCTUnwrap(report.components(separatedBy: "\n").first { $0.hasPrefix("Quality cache: ") })
        let quality = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(line.dropFirst("Quality cache: ".count).utf8)) as? [String: Any])
        app.navigationBars["连接诊断"].buttons.element(boundBy: 0).tap()
        self.settingsBack(app).coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: self.settingsBack(app))
        waitForExpectations(timeout: 10)
        return (quality, report)
    }

    func test101AdaptiveSelectionDownloadToggleAndProgress() throws {
        // Missing the new keys deliberately exercises migration while retaining the existing permanent cache.
        let app = launch("masque", reset: false, fixture: ["tunnelProtocol": "masque", "addressFamily": "ipv4", "mtu": 1280,
            "strength": "low", "cacheHours": 0, "probeTimeout": 10])
        waitReady(app, timeout: 15)
        showSettings(app)
        let speed = app.textFields["minimumDownloadSpeedField"], toggle = app.switches["downloadTestSwitch"]
        reveal(toggle, app: app)
        XCTAssertEqual(toggle.value as? String, "1")
        XCTAssertEqual(speed.value as? String, "3")
        fill(speed, "0", app: app)
        XCTAssertTrue(app.staticTexts["settingsInputError"].waitForExistence(timeout: 5))
        fill(speed, "3.5", app: app)
        reveal(toggle, app: app)
        toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
        expectation(for: NSPredicate(format: "value == %@", "0"), evaluatedWith: toggle)
        waitForExpectations(timeout: 5)
        shot(app, "Disabled download input state")
        XCTAssertFalse(speed.isEnabled)
        shot(app, "Download toggle off and minimum speed setting")
        saveSettings(app); waitReady(app, timeout: 10)
        app.terminate(); app.launchArguments = []; app.launch(); waitReady(app, timeout: 15)
        showSettings(app); reveal(toggle, app: app)
        XCTAssertEqual(toggle.value as? String, "0")
        XCTAssertEqual(speed.value as? String, "3.5")
        self.settingsBack(app).coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        let start = Date()
        tapScan(app)
        expectation(for: NSPredicate(format: "label CONTAINS %@", "8/14 连通筛选 ·"), evaluatedWith: app.staticTexts["progressStage"])
        waitForExpectations(timeout: 25)
        shot(app, "Running animated progress with registration at one third")
        expectation(for: NSPredicate(format: "label CONTAINS %@", "10/14"), evaluatedWith: app.staticTexts["progressStage"])
        waitForExpectations(timeout: 360)
        shot(app, "Overall step and per-node stability progress")
        waitReady(app, timeout: 240)
        let offElapsed = Int(Date().timeIntervalSince(start))
        shot(app, "Completed green progress without download testing")
        let (offCache, offReport) = try qualityCache(app)
        XCTAssertEqual(offCache["schema"] as? Int, 4)
        XCTAssertEqual(offCache["downloadEnabled"] as? Bool, false)
        XCTAssertTrue(try XCTUnwrap(offCache["downloadRounds"] as? [Int]).allSatisfy { $0 == 0 })
        XCTAssertTrue(try XCTUnwrap(offCache["latencyRounds"] as? [Int]).allSatisfy { (3...5).contains($0) })
        XCTAssertTrue(offReport.contains("download=false"))
        XCTAssertFalse(offReport.contains("__down?"))
        XCTAssertEqual(app.staticTexts["vpnStatus"].label, "未连接")

        showSettings(app); reveal(toggle, app: app)
        toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
        expectation(for: NSPredicate(format: "value == %@", "1"), evaluatedWith: toggle)
        waitForExpectations(timeout: 5)
        XCTAssertTrue(speed.isEnabled)
        shot(app, "Download test enabled with custom minimum speed")
        saveSettings(app); waitReady(app, timeout: 10)
        let downloadStart = Date()
        tapScan(app)
        expectation(for: NSPredicate(format: "label CONTAINS %@", "10/14 下载测速 ·"), evaluatedWith: app.staticTexts["progressStage"])
        waitForExpectations(timeout: 240)
        shot(app, "One download per node with nested progress counters")
        waitReady(app, timeout: 240)
        let onElapsed = Int(Date().timeIntervalSince(downloadStart))
        shot(app, "Completed green progress after adaptive speed selection")
        let (onCache, onReport) = try qualityCache(app)
        XCTAssertEqual(onCache["schema"] as? Int, 4)
        XCTAssertEqual(onCache["downloadEnabled"] as? Bool, true)
        XCTAssertEqual(onCache["minimumMbps"] as? Double, 3.5)
        XCTAssertTrue(try XCTUnwrap(onCache["downloadRounds"] as? [Int]).allSatisfy { $0 == 1 })
        XCTAssertTrue(try XCTUnwrap(onCache["latencyRounds"] as? [Int]).allSatisfy { (3...5).contains($0) })
        let timing = XCTAttachment(string: "MASQUE low: no-download=\(offElapsed)s, download=\(onElapsed)s\n" + onReport)
        timing.name = "Adaptive selection measurements"; timing.lifetime = .keepAlways; add(timing)
        XCTAssertEqual(app.staticTexts["vpnStatus"].label, "未连接")
        connect(app); verify(app)
        shot(app, "Adaptive selected node verified through real WARP tunnel")
        disconnect(app)
    }

    func test102AdaptiveDownloadWithReachableSpeedFloor() throws {
        let app = launch("masque", reset: false, fixture: ["tunnelProtocol": "masque", "addressFamily": "ipv4", "mtu": 1280,
            "strength": "low", "cacheHours": 0, "probeTimeout": 10, "minimumDownloadMbps": 1, "downloadTestEnabled": true])
        waitReady(app, timeout: 15)
        let start = Date()
        tapScan(app)
        let measuring = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            app.staticTexts["progressStage"].label.contains("10/14 下载测速 ·") || app.alerts["连接提示"].exists
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [measuring], timeout: 300), .completed)
        XCTAssertFalse(app.alerts["连接提示"].exists)
        shot(app, "Adaptive single download and nested node counters")
        waitReady(app, timeout: 240)
        shot(app, "Green completed progress with speed-tested nodes")
        let (cache, report) = try qualityCache(app)
        XCTAssertEqual(cache["schema"] as? Int, 4)
        XCTAssertEqual(cache["minimumMbps"] as? Double, 1)
        XCTAssertEqual(cache["downloadEnabled"] as? Bool, true)
        XCTAssertTrue(try XCTUnwrap(cache["downloadRounds"] as? [Int]).allSatisfy { $0 == 1 })
        XCTAssertTrue(try XCTUnwrap(cache["latencyRounds"] as? [Int]).allSatisfy { (3...5).contains($0) })
        let timing = XCTAttachment(string: "MASQUE low, 1 Mbps minimum: \(Int(Date().timeIntervalSince(start)))s including UI navigation\n" + report)
        timing.name = "Adaptive successful download measurements"; timing.lifetime = .keepAlways; add(timing)
        XCTAssertEqual(app.staticTexts["vpnStatus"].label, "未连接")
        connect(app); verify(app)
        shot(app, "Speed-tested adaptive node verified through WARP")
        disconnect(app)
    }

    private func liveReport(_ app: XCUIApplication, expectedKind: String? = nil, minimumRevision: Int = 0) throws -> ([String: Any], String) {
        showSettings(app); reveal(app.buttons["diagnosticsButton"], app: app); app.buttons["diagnosticsButton"].tap()
        let text = app.descendants(matching: .any)["diagnosticText"].firstMatch
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            guard let line = text.label.components(separatedBy: "\n").first(where: { $0.hasPrefix("Live snapshot: ") }),
                  let value = try? JSONSerialization.jsonObject(with: Data(line.dropFirst("Live snapshot: ".count).utf8)) as? [String: Any],
                  let endpoint = value["endpoint"] as? [String: Any] else { return false }
            return (expectedKind == nil || endpoint["kind"] as? String == expectedKind)
                && (value["revision"] as? Int ?? 0) >= minimumRevision
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 20), .completed)
        let report = text.label
        let line = try XCTUnwrap(report.components(separatedBy: "\n").first { $0.hasPrefix("Live snapshot: ") })
        let state = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(line.dropFirst("Live snapshot: ".count).utf8)) as? [String: Any])
        app.navigationBars["连接诊断"].buttons.element(boundBy: 0).tap()
        self.settingsBack(app).coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: self.settingsBack(app))
        waitForExpectations(timeout: 10)
        return (state, report)
    }
    private func switchProtocol(_ kind: String, app: XCUIApplication) {
        showSettings(app)
        let picker = app.buttons["protocolPicker"]
        XCTAssertTrue(picker.waitForExistence(timeout: 5)); XCTAssertTrue(picker.isEnabled)
        picker.tap(); app.buttons[kind].tap()
        self.settingsBack(app).coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
    }
    private func assertSameTunnel(_ before: [String: Any], _ after: [String: Any]) {
        XCTAssertEqual(before["sessionID"] as? String, after["sessionID"] as? String)
        XCTAssertEqual(before["startedAt"] as? Double, after["startedAt"] as? Double)
        XCTAssertEqual(after["tunOpenCount"] as? Int, 1)
    }
    func test103CachedNodesAndProtocolsHotSwitchWithoutRestartingVPN() throws {
        let app = launch("masque", reset: false, fixture: ["tunnelProtocol": "masque", "addressFamily": "ipv4", "mtu": 1280,
            "strength": "low", "cacheHours": 0, "probeTimeout": 10, "minimumDownloadMbps": 1, "downloadTestEnabled": true])
        waitReady(app); connect(app); verify(app)
        let (initial, report) = try liveReport(app, expectedKind: "masque")
        XCTAssertEqual(initial["tunOpenCount"] as? Int, 1)
        let cacheLine = try XCTUnwrap(report.components(separatedBy: "\n").first { $0.hasPrefix("Local caches: ") })
        let cached = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(cacheLine.dropFirst("Local caches: ".count).utf8)) as? [String: Int])
        reveal(app.descendants(matching: .any)["nodeDisclosure"].firstMatch, app: app)
        app.descendants(matching: .any)["nodeDisclosure"].firstMatch.tap()
        XCTAssertTrue(app.buttons["endpoint1"].waitForExistence(timeout: 5))
        reveal(app.buttons["endpoint1"], app: app)
        XCTAssertTrue(app.buttons["endpoint1"].isEnabled)
        app.buttons["endpoint1"].coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        expectation(for: NSPredicate(format: "value == %@", "已选择"), evaluatedWith: app.buttons["endpoint1"])
        waitForExpectations(timeout: 20)
        XCTAssertEqual(app.staticTexts["vpnStatus"].label, "已连接")
        let (manual, _) = try liveReport(app, expectedKind: "masque", minimumRevision: 1)
        assertSameTunnel(initial, manual)
        XCTAssertNotEqual((initial["endpoint"] as? NSDictionary), (manual["endpoint"] as? NSDictionary))
        verify(app)
        shot(app, "Cached MASQUE node switched while VPN session stays connected")
        reveal(app.buttons["automaticNode"], app: app)
        app.buttons["automaticNode"].coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        let (automatic, _) = try liveReport(app, expectedKind: "masque", minimumRevision: 2)
        assertSameTunnel(initial, automatic); XCTAssertEqual(automatic["automatic"] as? Bool, true)

        var last = automatic
        for kind in ["wg", "awg"] where (cached[kind] ?? 0) > 0 {
            switchProtocol(kind.uppercased(), app: app)
            let (next, _) = try liveReport(app, expectedKind: kind, minimumRevision: (last["revision"] as? Int ?? 0) + 1)
            assertSameTunnel(initial, next)
            XCTAssertEqual(app.staticTexts["vpnStatus"].label, "已连接")
            shot(app, "Cached \(kind.uppercased()) protocol hot switched without VPN restart")
            last = next
        }
        switchProtocol("MASQUE", app: app)
        let (returned, _) = try liveReport(app, expectedKind: "masque", minimumRevision: (last["revision"] as? Int ?? 0) + 1)
        assertSameTunnel(initial, returned)
        app.terminate(); app.launchArguments = []; app.launch()
        XCTAssertTrue(app.buttons["connectButton"].waitForExistence(timeout: 20))
        XCTAssertEqual(app.staticTexts["vpnStatus"].label, "已连接")
        let (restored, finalReport) = try liveReport(app, expectedKind: "masque", minimumRevision: returned["revision"] as? Int ?? 0)
        assertSameTunnel(returned, restored)
        XCTAssertEqual(restored["endpoint"] as? NSDictionary, returned["endpoint"] as? NSDictionary)
        verify(app)
        let attachment = XCTAttachment(string: finalReport); attachment.name = "Hot switch live tunnel and cached protocol coverage"; attachment.lifetime = .keepAlways; add(attachment)
        shot(app, "Hot switched runtime survives app relaunch and verifies WARP")
        disconnect(app)
    }

    func test104UncachedProtocolDisconnectsPreparesAndWaitsForManualConnection() throws {
        let app = launch("wg", reset: false, fixture: ["tunnelProtocol": "wg", "addressFamily": "ipv4", "mtu": 1280,
            "strength": "low", "cacheHours": 0, "probeTimeout": 10, "minimumDownloadMbps": 1, "downloadTestEnabled": true])
        waitReady(app, timeout: 600); connect(app)
        let (before, _) = try liveReport(app, expectedKind: "wg")
        showSettings(app); tapCacheNeverExpires(app)
        saveSettings(app)
        switchProtocol("MASQUE", app: app)
        expectation(for: NSPredicate(format: "label == %@", "未连接"), evaluatedWith: app.staticTexts["vpnStatus"])
        waitForExpectations(timeout: 30)
        shot(app, "Expired target protocol disconnected before preparation")
        waitReady(app, timeout: 600)
        XCTAssertEqual(app.staticTexts["vpnStatus"].label, "未连接")
        XCTAssertTrue(app.buttons["connectButton"].isEnabled)
        let remainedOff = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in app.staticTexts["vpnStatus"].label != "未连接" }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [remainedOff], timeout: 3), .timedOut)
        shot(app, "Prepared target protocol waits for user power switch")
        connect(app); verify(app)
        let (after, finalReport) = try liveReport(app, expectedKind: "masque")
        XCTAssertNotEqual(before["sessionID"] as? String, after["sessionID"] as? String)
        XCTAssertEqual(after["revision"] as? Int, 0)
        let attachment = XCTAttachment(string: finalReport); attachment.name = "No cache preparation followed by manual connection"; attachment.lifetime = .keepAlways; add(attachment)
        disconnect(app)
        showSettings(app); tapCacheNeverExpires(app)
        saveSettings(app); waitReady(app, timeout: 15)
    }

    func test109AWGColdVersusHotSameCachedEndpoint() throws {
        let app = launch("awg", reset: false, fixture: ["tunnelProtocol": "awg", "addressFamily": "ipv4", "mtu": 1280,
            "strength": "low", "cacheHours": 0, "probeTimeout": 10, "minimumDownloadMbps": 1, "downloadTestEnabled": true])
        waitReady(app); connect(app)
        func check() {
            reveal(app.buttons["verifyButton"], app: app); app.buttons["verifyButton"].tap()
            let terminal = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
                let result = app.staticTexts["verificationResult"]
                return result.exists && (result.label.contains("WARP 已验证") || result.label == "验证失败")
            }, object: nil)
            XCTAssertEqual(XCTWaiter.wait(for: [terminal], timeout: 40), .completed)
            XCTAssertTrue(app.staticTexts["verificationResult"].label.contains("WARP 已验证"), app.alerts.debugDescription)
        }
        check(); shot(app, "Same cached AWG endpoint cold connection baseline")
        let (initial, _) = try liveReport(app, expectedKind: "awg")
        switchProtocol("MASQUE", app: app)
        let (masque, _) = try liveReport(app, expectedKind: "masque", minimumRevision: 1)
        assertSameTunnel(initial, masque); check()
        switchProtocol("AWG", app: app)
        let (awg, _) = try liveReport(app, expectedKind: "awg", minimumRevision: 2)
        assertSameTunnel(initial, awg); check()
        shot(app, "Same AWG endpoint cold and hot both verified")
        switchProtocol("MASQUE", app: app)
        let (_, report) = try liveReport(app, expectedKind: "masque", minimumRevision: 3)
        let attachment = XCTAttachment(string: report); attachment.name = "AWG same endpoint cold hot comparison"; attachment.lifetime = .keepAlways; add(attachment)
        disconnect(app)
    }

    func test130HomeConnectionLocationAndStableReadyProgress() throws {
        let app = launch("masque", reset: false)
        addTeardownBlock {
            app.activate()
            if self.settingsBack(app).exists { self.settingsBack(app).tap() }
            let power = app.buttons["connectButton"]
            if power.exists, let state = power.value as? String, state != "未连接", state != "正在断开" {
                power.tap()
                let stopped = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", "未连接"), object: power)
                XCTAssertEqual(XCTWaiter.wait(for: [stopped], timeout: 20), .completed)
            }
        }
        waitReady(app, timeout: 60)
        // Richard's AssistiveTouch button is parked over the gear. Move that overlay to
        // the empty lower edge for this run; do not change the owner's accessibility settings.
        app.buttons["settingsButton"].coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            .press(forDuration: 1, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.94, dy: 0.9)))
        app.activate()
        XCTAssertTrue(app.buttons["automaticNode"].exists)
        XCTAssertFalse(app.staticTexts["vpnStatus"].exists)
        XCTAssertFalse(app.staticTexts["protocolBadge"].exists)
        XCTAssertFalse(app.staticTexts["messageText"].exists)
        XCTAssertFalse(app.staticTexts["让连接，自由一点。"].exists)
        shot(app, "Home gray power button and compact header")
        let progress = app.descendants(matching: .any)["preparationProgress"].firstMatch
        XCTAssertEqual(progress.value as? String, "100%")
        showSettings(app)
        self.settingsBack(app).tap()
        for _ in 0..<8 { XCTAssertEqual(progress.value as? String, "100%") }
        XCUIDevice.shared.press(.home)
        app.activate()
        XCTAssertTrue(app.buttons["connectButton"].waitForExistence(timeout: 10))
        for _ in 0..<8 { XCTAssertEqual(progress.value as? String, "100%") }
        connect(app)
        let location = app.descendants(matching: .any)["connectionLocation"].firstMatch
        let found = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            location.label.range(of: #"^国家: .+\s+数据中心: [A-Z]{3}$"#, options: .regularExpression) != nil
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [found], timeout: 45), .completed, location.label)
        shot(app, "Connected orange power button with country flag and colo")
        showSettings(app)
        self.settingsBack(app).tap()
        for _ in 0..<8 { XCTAssertEqual(progress.value as? String, "100%") }
        disconnect(app)
        for _ in 0..<8 { XCTAssertEqual(progress.value as? String, "100%") }
        XCTAssertFalse(location.exists)
        shot(app, "Disconnected VPN with green ready progress retained")
        showSettings(app)
        let export = app.buttons["exportFormatMenu"]
        reveal(export, app: app)
        XCTAssertEqual(export.value as? String, "Clash")
        shot(app, "Native export format picker matching other settings")
        export.tap()
        XCTAssertTrue(app.buttons["Clash"].waitForExistence(timeout: 3))
        XCTAssertFalse(app.buttons["V2Ray"].exists)
        app.buttons["Clash"].tap()
        self.settingsBack(app).tap()
        XCTAssertEqual(app.buttons["connectButton"].value as? String, "未连接")
    }

    func test119CachedWireGuardReachesWARPEgress() throws {
        let app = launch("wg", reset: false)
        let power = app.buttons["connectButton"]
        addTeardownBlock {
            app.activate()
            if power.value as? String == "已连接" { self.disconnect(app) }
        }
        waitReady(app, timeout: 120)
        for _ in 0..<2 {
            connect(app)
            let location = app.descendants(matching: .any)["connectionLocation"].firstMatch
            let reached = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
                location.exists && location.label.range(of: #"^国家: .+\s+数据中心: [A-Z]{3}$"#, options: .regularExpression) != nil
            }, object: nil)
            XCTAssertEqual(XCTWaiter.wait(for: [reached], timeout: 35), .completed, location.label)

            // The XCTest runner is a separate process. Confirm its own HTTPS request is also tunneled.
            let options = URLSessionConfiguration.ephemeral
            options.timeoutIntervalForResource = 18
            let session = URLSession(configuration: options)
            defer { session.invalidateAndCancel() }
            let verified = expectation(description: "WARP exit from the test runner")
            let url = URL(string: "https://1.1.1.1/cdn-cgi/trace?trashvpn=\(UUID().uuidString)")!
            session.dataTask(with: url) { data, response, error in
                defer { verified.fulfill() }
                XCTAssertNil(error)
                XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
                let trace = String(decoding: data ?? Data(), as: UTF8.self)
                XCTAssertTrue(trace.split(whereSeparator: \.isNewline).contains { $0 == "warp=on" || $0 == "warp=plus" })
            }.resume()
            waitForExpectations(timeout: 20)
            disconnect(app)
        }
    }

    func test120ConnectedLatencyDownloadAndRestartOptimization() throws {
        let app = launch("wg", reset: false)
        let power = app.buttons["connectButton"], scan = app.buttons["scanButton"]
        addTeardownBlock {
            app.activate()
            if app.alerts["连接提示"].exists { app.alerts["连接提示"].buttons["好"].tap() }
            if power.exists, let state = power.value as? String, state != "未连接", state != "正在断开" {
                for _ in 0..<4 where !power.isHittable { app.swipeDown() }
                if power.isEnabled { power.tap() }
            }
            if power.exists {
                let stopped = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", "未连接"), object: power)
                XCTAssertEqual(XCTWaiter.wait(for: [stopped], timeout: 25), .completed)
            }
        }
        waitReady(app, timeout: 120)
        XCTAssertTrue(app.buttons["automaticNode"].exists)
        XCTAssertTrue(app.buttons["endpoint0"].exists)
        XCTAssertFalse(app.buttons["verifyButton"].exists)
        connect(app)

        for (identifier, title, metric) in [
            ("latencyTestButton", "延迟", "endpointLatency0"),
            ("speedTestButton", "测速", "endpointSpeed0")
        ] {
            let button = app.buttons[identifier]
            reveal(button, app: app)
            XCTAssertTrue(button.isEnabled)
            XCTAssertEqual(power.value as? String, "已连接")
            button.tap()
            let started = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", "停止"), object: button)
            XCTAssertEqual(XCTWaiter.wait(for: [started], timeout: 12), .completed)
            let done = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", title), object: button)
            XCTAssertEqual(XCTWaiter.wait(for: [done], timeout: 180), .completed)
            XCTAssertEqual(power.value as? String, "已连接")
            let measured = app.descendants(matching: .any)[metric].firstMatch.value as? String
            XCTAssertNotNil(measured)
            XCTAssertNotEqual(measured, "测试中")
            XCTAssertNotEqual(measured, "未测试")
        }

        reveal(scan, app: app)
        XCTAssertTrue(scan.isEnabled)
        XCTAssertEqual(scan.label, "重新优选")
        scan.tap()
        let optimizing = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            power.value as? String == "未连接" && scan.label == "暂停"
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [optimizing], timeout: 30), .completed)
        XCTAssertFalse(power.isEnabled)
        scan.tap()
        XCTAssertEqual(power.value as? String, "未连接")
    }

    func test140FullPageSettingsMenusAndAutosave() throws {
        let app = launch("masque", reset: false, fixture: ["tunnelProtocol": "masque", "addressFamily": "ipv4",
            "theme": "system", "mtu": 0, "customDNS": "", "strength": "low", "cacheHours": 0,
            "probeTimeout": 5, "minimumDownloadMbps": 3, "downloadTestEnabled": true])
        addTeardownBlock {
            app.activate()
            if self.settingsBack(app).exists { self.settingsBack(app).tap() }
            let power = app.buttons["connectButton"]
            if power.exists, let state = power.value as? String, state != "未连接", state != "正在断开" {
                power.tap()
            }
            if power.exists {
                let stopped = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", "未连接"), object: power)
                XCTAssertEqual(XCTWaiter.wait(for: [stopped], timeout: 20), .completed)
            }
        }
        waitReady(app, timeout: 30)
        XCTAssertTrue(app.staticTexts["选择节点"].exists)
        let scan = app.buttons["scanButton"], latency = app.buttons["latencyTestButton"]
        XCTAssertEqual(scan.frame.height, latency.frame.height, accuracy: 1)
        shot(app, "Home selection title and matching action buttons")
        showSettings(app)
        XCTAssertTrue(app.navigationBars["设置"].exists)
        XCTAssertFalse(app.buttons["settingsDone"].exists)
        XCTAssertFalse(app.buttons["connectButton"].exists)
        XCTAssertLessThan(app.navigationBars["设置"].frame.minY, 100)
        XCTAssertTrue(app.descendants(matching: .any)["customDNSField"].firstMatch.exists)
        XCTAssertFalse(app.staticTexts["1.1.1.1"].exists)
        XCTAssertFalse(app.staticTexts["https://dns.example.com/dns-query"].exists)
        XCTAssertFalse(app.segmentedControls["protocolPicker"].exists)
        XCTAssertFalse(app.segmentedControls["addressFamilyPicker"].exists)
        openMenu("protocolPicker", option: "AWG", app: app)
        for title in ["WG", "AWG", "MASQUE"] { XCTAssertTrue(app.buttons[title].exists) }
        app.buttons["AWG"].tap()
        openMenu("protocolPicker", option: "MASQUE", app: app); app.buttons["MASQUE"].tap()
        openMenu("addressFamilyPicker", option: "IPv6", app: app)
        XCTAssertTrue(app.buttons["IPv4"].exists); XCTAssertTrue(app.buttons["IPv6"].exists)
        app.buttons["IPv6"].tap()
        openMenu("addressFamilyPicker", option: "IPv4", app: app); app.buttons["IPv4"].tap()
        openMenu("themePicker", option: "浅色", app: app); app.buttons["浅色"].tap()
        shot(app, "Full page settings with menus and one line DNS placeholder")
        fill(app.textFields["mtuField"], "1279", app: app)
        XCTAssertTrue(app.staticTexts["settingsInputError"].waitForExistence(timeout: 5))
        fill(app.textFields["mtuField"], "1400", app: app)
        XCTAssertFalse(app.staticTexts["settingsInputError"].exists)
        fill(app.descendants(matching: .any)["customDNSField"].firstMatch, "https://1.1.1.1/dns-query", app: app)
        fill(app.textFields["timeoutField"], "7", app: app)
        fill(app.textFields["minimumDownloadSpeedField"], "4.5", app: app)
        let toggle = app.switches["downloadTestSwitch"], minimum = app.textFields["minimumDownloadSpeedField"]
        reveal(toggle, app: app)
        XCTAssertLessThan(toggle.frame.midY, minimum.frame.midY)
        toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
        XCTAssertFalse(minimum.isEnabled)
        let export = app.staticTexts["exportStatus"]
        reveal(export, app: app)
        XCTAssertNotNil(export.label.range(of: #"^复制本地缓存中的 [0-9]+ 个节点。$"#, options: .regularExpression))
        shot(app, "Download toggle above minimum speed and concise export count")
        // Terminate on the settings page: no back or save action may be required for persistence.
        app.terminate(); app.launchArguments = []; app.launch()
        XCTAssertTrue(app.buttons["connectButton"].waitForExistence(timeout: 20))
        showSettings(app)
        XCTAssertTrue(app.buttons["protocolPicker"].label.contains("MASQUE"))
        XCTAssertTrue(app.buttons["addressFamilyPicker"].label.contains("IPv4"))
        XCTAssertEqual(app.textFields["mtuField"].value as? String, "1400")
        XCTAssertEqual(app.descendants(matching: .any)["customDNSField"].firstMatch.value as? String, "https://1.1.1.1/dns-query")
        reveal(toggle, app: app)
        XCTAssertEqual(toggle.value as? String, "0")
        XCTAssertEqual(minimum.value as? String, "4.5")
        XCTAssertEqual(app.textFields["timeoutField"].value as? String, "7")
        for _ in 0..<4 { app.swipeDown() }
        openMenu("themePicker", option: "深色", app: app); app.buttons["深色"].tap()
        shot(app, "Full page dark settings with return button and no save button")
        openMenu("themePicker", option: "跟随系统", app: app); app.buttons["跟随系统"].tap()
        self.settingsBack(app).tap()
        XCTAssertTrue(app.buttons["connectButton"].waitForExistence(timeout: 5))
        XCTAssertFalse(self.settingsBack(app).exists)
        XCTAssertEqual(app.buttons["connectButton"].value as? String, "未连接")
        shot(app, "Returned home with VPN explicitly disconnected")
    }

    func test150FourLanguagesCompactDNSStrengthMenuAndAboutLinks() throws {
        let app = launch("masque", reset: false, fixture: ["tunnelProtocol": "masque", "addressFamily": "ipv4",
            "language": "zh-Hans", "customDNS": "", "strength": "low", "cacheHours": 0, "downloadTestEnabled": false])
        let disconnected = ["未连接", "未連接", "Disconnected", "قطع شده"]
        addTeardownBlock {
            app.activate()
            if self.settingsBack(app).exists { self.settingsBack(app).tap() }
            let power = app.buttons["connectButton"]
            if power.exists, !disconnected.contains(power.value as? String ?? "") { power.tap() }
            if power.exists {
                let stopped = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value IN %@", disconnected), object: power)
                XCTAssertEqual(XCTWaiter.wait(for: [stopped], timeout: 20), .completed)
            }
        }
        waitReady(app, timeout: 30)
        showSettings(app)
        let dns = app.descendants(matching: .any)["customDNSField"].firstMatch
        XCTAssertTrue(dns.exists)
        XCTAssertEqual(dns.placeholderValue, "留空使用默认 DNS 1.1.1.1")
        XCTAssertLessThan(dns.frame.height, 60)
        openMenu("strengthPicker", option: "高", app: app)
        XCTAssertTrue(app.buttons["低"].exists); XCTAssertTrue(app.buttons["中"].exists)
        app.buttons["高"].tap()
        XCTAssertFalse(app.segmentedControls["strengthPicker"].exists)
        shot(app, "Compact DNS area and dropdown optimization level")
        fill(dns, "1.1.1.1\n8.8.8.8", app: app)
        let languages = [
            ("English", "Settings", "Select node", "Language"),
            ("繁體中文", "設置", "選擇節點", "語言"),
            ("فارسی", "تنظیمات", "انتخاب گره", "زبان"),
            ("简体中文", "设置", "选择节点", "语言")]
        for (nativeName, title, homeTitle, languageTitle) in languages {
            openMenu("languagePicker", option: nativeName, app: app)
            app.buttons[nativeName].tap()
            XCTAssertTrue(app.navigationBars[title].waitForExistence(timeout: 5))
            XCTAssertTrue(app.buttons["languagePicker"].label.contains(languageTitle))
            shot(app, "Settings language " + nativeName)
            if nativeName == "فارسی" {
                XCTAssertGreaterThan(self.settingsBack(app).frame.midX, app.frame.midX)
            }
            self.settingsBack(app).tap()
            XCTAssertTrue(app.staticTexts[homeTitle].waitForExistence(timeout: 5))
            shot(app, "Home language " + nativeName)
            showSettings(app)
        }
        for identifier in ["website", "github", "telegram", "youtube", "x", "donate"] {
            let link = app.descendants(matching: .any)["projectLink-" + identifier].firstMatch
            reveal(link, app: app)
            XCTAssertTrue(link.isHittable)
            if identifier == "youtube" || identifier == "donate" { shot(app, "About and donation links " + identifier) }
        }
        // Ending the process on Settings must preserve both the language and multiline DNS.
        app.terminate(); app.launchArguments = []; app.launch()
        XCTAssertTrue(app.buttons["connectButton"].waitForExistence(timeout: 20))
        showSettings(app)
        XCTAssertTrue(app.buttons["languagePicker"].label.contains("简体中文"))
        XCTAssertEqual(dns.value as? String, "1.1.1.1\n8.8.8.8")
        openMenu("languagePicker", option: "English", app: app); app.buttons["English"].tap()
        app.terminate(); app.launchArguments = []; app.launch()
        XCTAssertTrue(app.buttons["connectButton"].waitForExistence(timeout: 20))
        XCTAssertTrue(app.staticTexts["Select node"].exists)
        showSettings(app)
        XCTAssertTrue(app.navigationBars["Settings"].exists)
        openMenu("languagePicker", option: "简体中文", app: app); app.buttons["简体中文"].tap()
        self.settingsBack(app).tap()
        XCTAssertEqual(app.buttons["connectButton"].value as? String, "未连接")
        shot(app, "Finished multilingual verification with VPN disconnected")
    }

    func test152AboutWebsiteOpensBrowserAndReturns() throws {
        let app = launch("masque", reset: false, fixture: ["tunnelProtocol": "masque", "addressFamily": "ipv4",
            "language": "zh-Hans", "cacheHours": 0, "downloadTestEnabled": false])
        showSettings(app)
        let website = app.descendants(matching: .any)["projectLink-website"].firstMatch
        reveal(website, app: app)
        website.tap()
        let browserOpened = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in app.state != .runningForeground }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [browserOpened], timeout: 10), .completed)
        app.activate()
        XCTAssertTrue(self.settingsBack(app).waitForExistence(timeout: 10))
        self.settingsBack(app).tap()
        XCTAssertEqual(app.buttons["connectButton"].value as? String, "未连接")
        shot(app, "Browser link opened and returned with VPN disconnected")
    }

    func test153PersianPickerAndFinalAboutAppearance() throws {
        let app = launch("masque", reset: false, fixture: ["tunnelProtocol": "masque", "addressFamily": "ipv4",
            "language": "zh-Hans", "cacheHours": 0, "customDNS": "", "downloadTestEnabled": false])
        showSettings(app)
        openMenu("languagePicker", option: "فارسی", app: app); app.buttons["فارسی"].tap()
        let name = app.staticTexts["فارسی"].firstMatch
        XCTAssertTrue(name.waitForExistence(timeout: 5))
        XCTAssertLessThan(name.frame.height, 40)
        shot(app, "Persian language name stays on one line")
        let donate = app.descendants(matching: .any)["projectLink-donate"].firstMatch
        reveal(donate, app: app)
        shot(app, "Persian About links and donation card")
        openMenu("languagePicker", option: "English", app: app); app.buttons["English"].tap()
        shot(app, "English settings with compact DNS placeholder")
        reveal(donate, app: app)
        shot(app, "English About links and donation card")
        openMenu("languagePicker", option: "简体中文", app: app); app.buttons["简体中文"].tap()
        shot(app, "Chinese settings with compact default DNS")
        reveal(donate, app: app)
        shot(app, "Final About and donation styling")
        self.settingsBack(app).tap()
        XCTAssertEqual(app.buttons["connectButton"].value as? String, "未连接")
    }

    func test154DefaultDNSPromptsInPersianAndEnglish() throws {
        let app = launch("masque", reset: false, fixture: ["tunnelProtocol": "masque", "addressFamily": "ipv4",
            "language": "zh-Hans", "cacheHours": 0, "customDNS": "", "downloadTestEnabled": false])
        showSettings(app)
        let dns = app.descendants(matching: .any)["customDNSField"].firstMatch
        for (language, prompt) in [("فارسی", "خالی: DNS پیش‌فرض 1.1.1.1"), ("English", "Default DNS if empty: 1.1.1.1"), ("简体中文", "留空使用默认 DNS 1.1.1.1")] {
            openMenu("languagePicker", option: language, app: app); app.buttons[language].tap()
            XCTAssertEqual(dns.placeholderValue, prompt)
            shot(app, "Final default DNS prompt " + language)
        }
        self.settingsBack(app).tap()
        XCTAssertEqual(app.buttons["connectButton"].value as? String, "未连接")
    }

    func test160FourLanguageChoicesStrengthSliderAndCompactFullWidthDonation() throws {
        let app = launch("masque", reset: false, fixture: ["tunnelProtocol": "masque", "addressFamily": "ipv4",
            "language": "zh-Hans", "cacheHours": 0, "customDNS": "", "strength": "low", "downloadTestEnabled": false])
        showSettings(app)
        openMenu("languagePicker", option: "English", app: app)
        XCTAssertFalse(app.buttons["跟随系统"].exists)
        for language in ["简体中文", "English", "繁體中文", "فارسی"] { XCTAssertTrue(app.buttons[language].exists) }
        app.buttons["简体中文"].tap()
        let slider = app.sliders["strengthSlider"]
        reveal(slider, app: app)
        func drag(_ start: CGFloat, _ end: CGFloat, to label: String) {
            slider.coordinate(withNormalizedOffset: CGVector(dx: start, dy: 0.5)).press(forDuration: 0.1,
                thenDragTo: slider.coordinate(withNormalizedOffset: CGVector(dx: end, dy: 0.5)))
            let changed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", label), object: app.staticTexts["strengthValue"])
            XCTAssertEqual(XCTWaiter.wait(for: [changed], timeout: 5), .completed)
        }
        drag(0.03, 0.97, to: "高")
        shot(app, "High optimization strength on draggable slider")
        drag(0.97, 0.5, to: "中")
        shot(app, "Medium optimization strength on draggable slider")
        drag(0.5, 0.03, to: "低")
        drag(0.03, 0.97, to: "高")
        app.terminate(); app.launchArguments = []; app.launch()
        XCTAssertTrue(app.buttons["connectButton"].waitForExistence(timeout: 20))
        showSettings(app); reveal(slider, app: app)
        XCTAssertEqual(app.staticTexts["strengthValue"].label, "高")
        let donate = app.descendants(matching: .any)["projectLink-donate"].firstMatch
        reveal(donate, app: app)
        let version = app.descendants(matching: .any)["versionRow"].firstMatch
        XCTAssertLessThan(version.frame.midY, app.buttons["diagnosticsButton"].frame.midY)
        XCTAssertLessThanOrEqual(donate.frame.height, 50)
        let website = app.descendants(matching: .any)["projectLink-website"].firstMatch
        XCTAssertLessThanOrEqual(website.frame.height, 50)
        shot(app, "Compact About rows version above diagnostics and smaller donation")
        for point in [CGVector(dx: 0.5, dy: 0.5), CGVector(dx: 0.78, dy: 0.5), CGVector(dx: 0.03, dy: 0.5)] {
            donate.coordinate(withNormalizedOffset: point).tap()
            let opened = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in app.state != .runningForeground }, object: nil)
            XCTAssertEqual(XCTWaiter.wait(for: [opened], timeout: 10), .completed)
            app.activate()
            XCTAssertTrue(self.settingsBack(app).waitForExistence(timeout: 10))
        }
        self.settingsBack(app).tap()
        XCTAssertEqual(app.buttons["connectButton"].value as? String, "未连接")
    }

    func test170SettingsCompatibilityWithoutNetwork() throws {
        let app = XCUIApplication()
        let fixture: [String: Any] = [
            "language": "zh-Hans", "tunnelProtocol": "masque", "mtu": 1400,
            "cacheHours": 0, "customDNS": "", "doNotSetDNS": false
        ]
        let dns = app.descendants(matching: .any)["customDNSField"].firstMatch
        let customDNS = "1.1.1.1\n8.8.8.8"
        app.launchArguments = ["--test-offline-ui", "--settings-json=" + (try JSONSerialization.data(withJSONObject: fixture)).base64EncodedString()]
        app.launch()
        XCTAssertTrue(app.buttons["connectButton"].waitForExistence(timeout: 20))
        XCTAssertEqual(app.buttons["connectButton"].value as? String, "未连接")
        XCTAssertFalse(app.buttons["connectButton"].isEnabled)
        showSettings(app)
        fill(app.textFields["timeoutField"], "7", app: app)
        fill(app.textFields["mtuField"], "1420", app: app)
        fill(dns, customDNS, app: app)
        for _ in 0..<5 { app.swipeDown() }
        openMenu("languagePicker", option: "English", app: app)
        app.buttons["English"].tap()
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 5))
        shot(app, "Settings with working focus autosave and language change")
        self.settingsBack(app).tap()
        app.terminate(); app.launchArguments = ["--test-offline-ui"]; app.launch()
        XCTAssertTrue(app.buttons["connectButton"].waitForExistence(timeout: 20))
        showSettings(app)
        XCTAssertTrue(app.navigationBars["Settings"].exists)
        reveal(app.textFields["mtuField"], app: app)
        XCTAssertEqual(app.textFields["mtuField"].value as? String, "1420")
        reveal(dns, app: app)
        XCTAssertEqual(dns.value as? String, customDNS)
        reveal(app.textFields["timeoutField"], app: app)
        XCTAssertEqual(app.textFields["timeoutField"].value as? String, "7")
        self.settingsBack(app).tap()
        XCTAssertEqual(app.buttons["connectButton"].value as? String, "Disconnected")
    }

    func test161PowerRingTransitionsAndLargerCountryFlag() throws {
        let app = launch("masque", reset: false, fixture: ["tunnelProtocol": "masque", "addressFamily": "ipv4",
            "language": "zh-Hans", "cacheHours": 0, "downloadTestEnabled": false])
        addTeardownBlock {
            app.activate()
            if self.settingsBack(app).exists { self.settingsBack(app).tap() }
            let power = app.buttons["connectButton"]
            if power.exists, let state = power.value as? String, state != "未连接", state != "正在断开" { power.tap() }
            let stopped = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", "未连接"), object: power)
            XCTAssertEqual(XCTWaiter.wait(for: [stopped], timeout: 20), .completed)
        }
        waitReady(app, timeout: 30)
        shot(app, "Gray ring before VPN connection")
        connect(app)
        let location = app.descendants(matching: .any)["connectionLocation"].firstMatch
        let found = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            location.exists && location.label.contains("数据中心:")
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [found], timeout: 45), .completed)
        shot(app, "Orange ring and larger flag with original caption text")
        disconnect(app)
        shot(app, "Ring returned to gray after disconnecting VPN")
    }

    func test170SettingsEdgeBackAndCacheDays() {
        let app = launch("masque", reset: false, fixture: ["language": "zh-Hans", "tunnelProtocol": "masque", "mtu": 0])
        let power = app.buttons["connectButton"]
        addTeardownBlock {
            app.activate()
            if self.settingsBack(app).exists { self.settingsBack(app).tap() }
            if power.exists, let state = power.value as? String, state != "未连接", state != "正在断开" { power.tap() }
            let disconnected = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", "未连接"), object: power)
            XCTAssertEqual(XCTWaiter.wait(for: [disconnected], timeout: 20), .completed)
        }
        showSettings(app)
        XCTAssertTrue(app.staticTexts["设置为 0 则使用自动 MTU。"].exists)
        let days = app.textFields["cacheDaysField"]
        let toggle = app.switches["cacheNeverExpiresSwitch"]
        reveal(days, app: app)
        XCTAssertEqual(days.value as? String, "7")
        XCTAssertEqual(toggle.value as? String, "0")
        XCTAssertLessThan(toggle.frame.midY, days.frame.midY)
        shot(app, "Cache expiry defaults to seven days")
        fill(days, "0", app: app)
        XCTAssertTrue(app.staticTexts["settingsInputError"].waitForExistence(timeout: 5))
        fill(days, "12", app: app)
        tapCacheNeverExpires(app)
        XCTAssertEqual(toggle.value as? String, "1")
        XCTAssertFalse(days.isEnabled)
        shot(app, "Permanent cache disables but remembers the day count")

        func swipeBack(fromRight: Bool) {
            let start = app.coordinate(withNormalizedOffset: CGVector(dx: fromRight ? 0.987 : 0.012, dy: 0.48))
            let end = app.coordinate(withNormalizedOffset: CGVector(dx: fromRight ? 0.20 : 0.80, dy: 0.48))
            start.press(forDuration: 0.05, thenDragTo: end)
        }
        swipeBack(fromRight: true)
        XCTAssertTrue(self.settingsBack(app).exists)
        XCTAssertFalse(app.buttons["settingsButton"].exists)
        swipeBack(fromRight: false)
        XCTAssertTrue(app.buttons["settingsButton"].waitForExistence(timeout: 5))
        app.terminate(); app.launchArguments = []; app.launch()
        showSettings(app)
        reveal(toggle, app: app)
        XCTAssertEqual(toggle.value as? String, "1")
        XCTAssertEqual(days.value as? String, "12")
        tapCacheNeverExpires(app)
        XCTAssertEqual(toggle.value as? String, "0")
        XCTAssertTrue(days.isEnabled)
        XCTAssertEqual(days.value as? String, "12")
        self.settingsBack(app).tap()
        XCTAssertTrue(app.buttons["settingsButton"].waitForExistence(timeout: 5))
        XCTAssertEqual(power.value as? String, "未连接")
    }

    func test171NativeSettingsReturnMenusAndDiagnosticsSharing() throws {
        let app = try launchOfflineSettingsUI()
        let home = app.buttons["settingsButton"]
        XCTAssertTrue(home.waitForExistence(timeout: 10))
        XCTAssertEqual(app.staticTexts["progressStage"].frame.midY, app.buttons["scanButton"].frame.midY, accuracy: 2)
        XCTAssertEqual(app.staticTexts["nodeSectionTitle"].frame.midY, app.buttons["latencyTestButton"].frame.midY, accuracy: 2)
        XCTAssertEqual(app.buttons["latencyTestButton"].frame.midY, app.buttons["speedTestButton"].frame.midY, accuracy: 2)
        showSettings(app)

        let leftEdge = app.coordinate(withNormalizedOffset: CGVector(dx: 0.005, dy: 0.47))
        let rightEdge = app.coordinate(withNormalizedOffset: CGVector(dx: 0.995, dy: 0.47))
        rightEdge.press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.20, dy: 0.47)))
        XCTAssertTrue(settingsBack(app).exists)
        leftEdge.press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.24, dy: 0.47)),
                       withVelocity: .slow, thenHoldForDuration: 0.35)
        XCTAssertTrue(settingsBack(app).exists)
        leftEdge.press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.86, dy: 0.47)))
        XCTAssertTrue(home.waitForExistence(timeout: 5))
        showSettings(app)

        openMenu("protocolPicker", option: "MASQUE", app: app)
        XCTAssertTrue(app.buttons["WG"].exists)
        app.buttons["WG"].tap()

        let autoConnect = app.switches["autoConnectAfterOptimizationSwitch"]
        reveal(autoConnect, app: app)
        XCTAssertEqual(autoConnect.value as? String, "0")
        autoConnect.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.5)).tap()
        XCTAssertEqual(autoConnect.value as? String, "1")
        let cache = app.switches["cacheNeverExpiresSwitch"]
        let family = app.buttons["addressFamilyPicker"]
        reveal(cache, app: app)
        XCTAssertLessThan(cache.frame.midY, family.frame.midY)
        openMenu("addressFamilyPicker", option: "IPv6", app: app)
        app.buttons["IPv6"].tap()
        openMenu("exportFormatMenu", option: "sing-box", app: app)
        app.buttons["sing-box"].tap()
        XCTAssertEqual(app.buttons["exportFormatMenu"].value as? String, "sing-box")

        let diagnostics = app.buttons["diagnosticsButton"]
        reveal(diagnostics, app: app)
        diagnostics.tap()
        XCTAssertTrue(app.navigationBars["连接诊断"].waitForExistence(timeout: 3))
        let share = app.buttons["diagnosticShareMenu"]
        share.tap()
        XCTAssertTrue(app.buttons["导出为文件"].waitForExistence(timeout: 3))
        app.buttons["复制到剪贴板"].tap()
        share.tap()
        app.buttons["导出为文件"].tap()
        let fileDestination = app.buttons.matching(NSPredicate(format: "label IN %@", ["Move", "移动", "Save", "存储"]))
        XCTAssertTrue(fileDestination.firstMatch.waitForExistence(timeout: 5))

        app.terminate()
        app.launchArguments = ["--test-offline-ui"]
        app.launch()
        showSettings(app)
        reveal(autoConnect, app: app)
        XCTAssertEqual(autoConnect.value as? String, "1")
    }

    private func launchOfflineSettingsUI() throws -> XCUIApplication {
        let app = XCUIApplication()
        let fixture = ["language": "zh-Hans", "tunnelProtocol": "wg", "addressFamily": "ipv4"]
        app.launchArguments = ["--test-offline-ui", "--settings-json=" + (try JSONSerialization.data(withJSONObject: fixture)).base64EncodedString()]
        app.launch()
        return app
    }

    func test172PersianSettingsReturnUsesNativeLeadingEdge() throws {
        let app = try launchOfflineSettingsUI()
        let home = app.buttons["settingsButton"]
        XCTAssertTrue(home.waitForExistence(timeout: 10))
        showSettings(app)
        openMenu("languagePicker", option: "فارسی", app: app)
        app.buttons["فارسی"].tap()
        XCTAssertTrue(app.navigationBars["تنظیمات"].waitForExistence(timeout: 5))
        let leftEdge = app.coordinate(withNormalizedOffset: CGVector(dx: 0.005, dy: 0.47))
        let rightEdge = app.coordinate(withNormalizedOffset: CGVector(dx: 0.995, dy: 0.47))
        leftEdge.press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.86, dy: 0.47)))
        XCTAssertTrue(settingsBack(app).exists)
        rightEdge.press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.20, dy: 0.47)))
        XCTAssertTrue(home.waitForExistence(timeout: 5))
    }

    func test999DisconnectTrashVPNAfterDeviceVerification() throws {
        #if targetEnvironment(simulator)
        throw XCTSkip("Device VPN cleanup is only needed on an iPhone.")
        #else
        let app = XCUIApplication()
        app.launch()
        let power = app.buttons["connectButton"]
        XCTAssertTrue(power.waitForExistence(timeout: 20))
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true"), object: app.buttons["settingsButton"])
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 20), .completed)
        let disconnected = ["未连接", "未連接", "Disconnected", "قطع شده"]
        let disconnecting = ["正在断开", "正在斷開", "Disconnecting", "در حال قطع اتصال"]
        let state = power.value as? String ?? ""
        if !(disconnected + disconnecting).contains(state) {
            XCTAssertTrue(["断开连接", "斷開連接", "Disconnect", "قطع اتصال"].contains(power.label))
            power.tap()
        }
        let stopped = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value IN %@", disconnected), object: power)
        XCTAssertEqual(XCTWaiter.wait(for: [stopped], timeout: 20), .completed)
        #endif
    }

}
