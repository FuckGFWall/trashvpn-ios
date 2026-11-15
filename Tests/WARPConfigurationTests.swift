import XCTest
import Clash
@testable import TrashVPN

final class WARPConfigurationTests: XCTestCase {
    private func account(_ kind: WARPProtocol) -> WARPAccount {
        var value = WARPAccount.make(kind: kind)
        value.id = "test-id"; value.token = "test-token"; value.state = .registered
        value.peerPublicKey = kind == .masque ? WARPConfiguration.masquePeerPEM : WARPConfiguration.peerKey
        value.ipv4 = "172.16.0.2"; value.ipv6 = kind == .masque ? WARPConfiguration.masqueIPv6 : ""
        return value
    }
    func testProbeCannotInstallTunnelOrListeners() throws {
        let rendered = try WARPConfiguration.render(endpoints: WARPEndpoint.fixtures(for: .wg),
            selected: WARPEndpoint.fixtures[1], account: account(.wg), tunnel: false)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(rendered.utf8)) as? [String: Any])
        XCTAssertEqual((object["tun"] as? [String: Any])?["enable"] as? Bool, false)
        for name in ["port", "socks-port", "mixed-port"] { XCTAssertEqual(object[name] as? Int, 0) }
        XCTAssertEqual(object["external-controller"] as? String, "127.0.0.1:0")
        XCTAssertFalse((object["secret"] as? String ?? "").isEmpty)
        XCTAssertEqual(object["rules"] as? [String], ["MATCH,WG 8.6.112.85:2408"])
        let proxies = try XCTUnwrap(object["proxies"] as? [[String: Any]])
        XCTAssertEqual(proxies.count, 3)
        XCTAssertTrue(proxies.allSatisfy { $0["persistent-keepalive"] as? Int == 25 })
        XCTAssertTrue(proxies.allSatisfy { $0["remote-dns-resolve"] as? Bool == false })
        XCTAssertTrue(proxies.allSatisfy { $0["allowed-ips"] as? [String] == ["0.0.0.0/0"] })
        var error: NSError?
        XCTAssertNotNil(ClashYamlToJSON(rendered, &error))
        XCTAssertNil(error)
    }

    func testAWGParametersArePreserved() throws {
        let endpoints = WARPEndpoint.fixtures(for: .awg)
        let text = try WARPConfiguration.render(endpoints: endpoints, selected: endpoints[0], account: account(.awg), tunnel: false)
        let config = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
        let proxies = try XCTUnwrap(config["proxies"] as? [[String: Any]])
        XCTAssertEqual(proxies.count, 4)
        let options = try XCTUnwrap(proxies[0]["amnezia-wg-option"] as? [String: Any])
        XCTAssertEqual(options["jc"] as? Int, 6)
        XCTAssertEqual(options["jmin"] as? Int, 10)
        XCTAssertEqual(options["jmax"] as? Int, 50)
        XCTAssertEqual(options["s1"] as? Int, 0)
        XCTAssertEqual(options["s2"] as? Int, 0)
        for index in 1...4 { XCTAssertEqual(options["h\(index)"] as? Int, index) }
        XCTAssertEqual(options["i1"] as? String, WARPConfiguration.awgOptions["i1"] as? String)
        XCTAssertFalse(text.contains("dialer-proxy"))
    }

    func testMASQUEUsesQUICAndNormalizedPinnedPublicKey() throws {
        let endpoints = WARPEndpoint.fixtures(for: .masque)
        let text = try WARPConfiguration.render(endpoints: endpoints, selected: endpoints[0], account: account(.masque), tunnel: true)
        let config = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
        let proxies = try XCTUnwrap(config["proxies"] as? [[String: Any]])
        let proxy = proxies[0]
        XCTAssertEqual(proxies.count, 4)
        XCTAssertEqual(proxy["type"] as? String, "masque")
        XCTAssertEqual(proxy["network"] as? String, "quic")
        XCTAssertEqual(proxy["sni"] as? String, "consumer-masque.cloudflareclient.com")
        XCTAssertEqual(proxy["ipv6"] as? String, WARPConfiguration.masqueIPv6 + "/128")
        XCTAssertEqual(proxy["skip-cert-verify"] as? Bool, false)
        let key = try XCTUnwrap(proxy["public-key"] as? String)
        XCTAssertEqual(Data(base64Encoded: key)?.count, 91)
        XCTAssertFalse(key.contains("BEGIN"))
        XCTAssertFalse(key.contains("\n"))
        XCTAssertNil(proxy["amnezia-wg-option"])
        XCTAssertFalse(text.contains("dialer-proxy"))
    }

    func testActualSDKAcceptsAllThreeCredentialFormats() throws {
        try CoreRuntime.setup(isExtension: false)
        for kind in WARPProtocol.allCases {
            let endpoints = WARPEndpoint.fixtures(for: kind)
            let content = try WARPConfiguration.render(endpoints: endpoints, selected: endpoints[0],
                account: account(kind), tunnel: false)
            var error: NSError?
            XCTAssertTrue(ClashCheckConfig(content, &error), "\(kind.label): \(error?.localizedDescription ?? "unknown")")
        }
    }

    func testProtocolIdentityAndLegacyNodeMigration() throws {
        let wg = WARPEndpoint(host: "8.6.112.26", port: 2408)
        let awg = WARPEndpoint(host: "8.6.112.26", port: 2408, kind: .awg)
        XCTAssertNotEqual(wg.id, awg.id)
        let legacy = try JSONDecoder().decode(WARPEndpoint.self, from: Data(#"{"host":"8.39.125.159","port":2408}"#.utf8))
        XCTAssertEqual(legacy.kind, .wg)
        XCTAssertEqual(WARPEndpoint.lookup("8.39.125.159:2408"), legacy)
        XCTAssertEqual(Set(WARPProtocol.allCases), [.wg, .awg, .masque])
        XCTAssertThrowsError(try WARPConfiguration.render(endpoints: [wg, awg], selected: awg, account: account(.awg), tunnel: false))
    }

    func testForegroundPlatformRefusesTun() {
        let platform = CorePlatform(isExtension: false)
        var descriptor: Int32 = -1
        XCTAssertThrowsError(try platform.openTun(nil, ret0_: &descriptor))
        XCTAssertEqual(descriptor, -1)
        XCTAssertFalse(platform.underNetworkExtension())
    }

    func testFailedSamplesNeverCountAsFastest() {
        let result = ProbeResult(endpoint: WARPEndpoint.fixtures[0], samples: [-1, 80, 20], testedAt: Date())
        XCTAssertEqual(result.successes.count, 2)
        XCTAssertEqual(result.median, 80)
        XCTAssertNil(ProbeResult(endpoint: WARPEndpoint.fixtures[0], samples: [-1, -1, -1], testedAt: Date()).median)
    }
}
