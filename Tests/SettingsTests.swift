import Clash
import Foundation
import NetworkExtension
import XCTest
@testable import TrashVPN

final class SettingsTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_790_000_000)
    private var identities: [WARPProtocol: WARPAccount] = [:]
    private func account(_ kind: WARPProtocol = .wg) -> WARPAccount {
        if let stored = identities[kind] { return stored }
        var value = WARPAccount.make(kind: kind)
        value.id = "settings-test"; value.token = "test-token"; value.state = .registered
        value.peerPublicKey = kind == .masque ? WARPConfiguration.masquePeerPEM : WARPConfiguration.peerKey
        value.ipv4 = "172.16.0.2"; value.ipv6 = WARPConfiguration.masqueIPv6
        identities[kind] = value
        return value
    }
    private func cache(settings: UserSettings) throws -> NodeCache {
        let result = ProbeResult(endpoint: WARPEndpoint.fixtures[0], samples: Array(repeating: 100, count: settings.strength.rounds), testedAt: now, downloadMbps: Array(repeating: 20, count: settings.strength.downloadRounds), googleSuccesses: settings.strength.rounds / 2, qualityVersion: 2)
        return try NodeCache(account: account(), results: [result], now: now, settings: settings)
    }
    private func config(_ settings: UserSettings, kind: WARPProtocol = .wg) throws -> [String: Any] {
        let node = settings.addressFamily == .ipv4 ? WARPEndpoint.fixtures(for: kind)[0] : WARPEndpoint(host: "2606:4700:103::1", port: 443, kind: kind)
        let text = try WARPConfiguration.render(endpoints: [node], selected: node, account: account(kind), tunnel: true, family: settings.addressFamily, settings: settings)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
    }

    func testSettingsValidationAndFortyEightHourOption() throws {
        XCTAssertEqual(UserSettings.cacheDurations, [6, 12, 24, 48])
        var value = UserSettings()
        for mtu in [0, 1280, 1400, 1500] { value.mtu = mtu; XCTAssertNoThrow(try value.validated()) }
        for mtu in [-1, 1279, 1501] { value.mtu = mtu; XCTAssertThrowsError(try value.validated()) }
        value.mtu = 0
        for timeout in [1, 7, 30] { value.probeTimeout = timeout; XCTAssertNoThrow(try value.validated()) }
        value.probeTimeout = 31; XCTAssertThrowsError(try value.validated())
        value.probeTimeout = 5; value.cacheHours = 46; XCTAssertThrowsError(try value.validated())
        value.cacheHours = 48; XCTAssertNoThrow(try value.validated())
        value.doNotSetDNS = true; XCTAssertThrowsError(try value.validated())
    }

    func testDNSSyntaxAndRoutingInjectionRejection() throws {
        var value = UserSettings()
        value.customDNS = "1.1.1.1\n[2606:4700:4700::1111]:53\ntls://dns.google\nhttps://cloudflare-dns.com/dns-query\n1.1.1.1"
        XCTAssertEqual(try value.dnsServers().count, 4)
        for text in ["999.999.999.999", "https://dns.google/#DIRECT", "https://user:pass@dns.google/dns-query", "https://dns.google/dns-query?route=DIRECT", "1.1.1.1:65536", "http://dns.google", "https://bad-.example/dns-query", "foo://1.1.1.1"] {
            value.customDNS = text; XCTAssertThrowsError(try value.validated(), text)
        }
    }

    func testSettingsFilePersistenceAndIPv6Migration() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try JSONEncoder().encode(NetworkPreferences(addressFamily: .ipv6)).write(to: root.appendingPathComponent("network-preferences.json"))
        XCTAssertEqual(try UserSettings.load(root: root).addressFamily, .ipv6)
        var value = UserSettings(); value.theme = .dark; value.cacheHours = 48; value.mtu = 1400; value.probeTimeout = 7
        try value.save(root: root)
        XCTAssertEqual(try UserSettings.load(root: root), value)
    }

    func testCacheTTLUsesOriginalCompletionTimeAndCanBeShortened() throws {
        let initial = UserSettings()
        let saved = try cache(settings: initial)
        var extended = initial; extended.cacheHours = 48
        XCTAssertTrue(saved.isValid(for: account(), now: now.addingTimeInterval(47 * 3600), settings: extended))
        XCTAssertFalse(saved.isValid(for: account(), now: now.addingTimeInterval(48 * 3600), settings: extended))
        XCTAssertEqual(saved.expiry(settings: extended), now.addingTimeInterval(48 * 3600))
        XCTAssertEqual(saved.createdAt, now); XCTAssertEqual(saved.expiresAt, now.addingTimeInterval(6 * 3600))
        XCTAssertFalse(saved.isValid(for: account(), now: now.addingTimeInterval(7 * 3600), settings: initial))
    }

    func testThemeAndTTLDoNotInvalidateMeasurementsButNetworkChangesDo() throws {
        let initial = UserSettings(); let saved = try cache(settings: initial)
        var value = initial; value.theme = .dark; value.cacheHours = 24
        XCTAssertTrue(saved.isValid(for: account(), now: now, settings: value))
        value = initial; value.mtu = 1400; XCTAssertFalse(saved.isValid(for: account(), now: now, settings: value))
        value = initial; value.probeTimeout = 7; XCTAssertFalse(saved.isValid(for: account(), now: now, settings: value))
        value = initial; value.customDNS = "8.8.8.8"; XCTAssertFalse(saved.isValid(for: account(), now: now, settings: value))
        value = initial; value.strength = .high; XCTAssertFalse(saved.isValid(for: account(), now: now, settings: value))
    }

    func testStrengthControlsCandidateBudgetAndCompleteSampleCount() throws {
        XCTAssertEqual(UserSettings.Strength.allCases.map(\.candidates), [64, 160, 320])
        XCTAssertEqual(UserSettings.Strength.allCases.map(\.finalists), [6, 10, 16])
        XCTAssertEqual(UserSettings.Strength.allCases.map(\.rounds), [5, 8, 12])
        for strength in UserSettings.Strength.allCases {
            var value = UserSettings(); value.strength = strength
            let saved = try cache(settings: value)
            XCTAssertEqual(saved.results[0].samples.count, strength.rounds)
            XCTAssertTrue(saved.isValid(for: account(), now: now, settings: value))
            let candidates = EndpointCatalog.candidates(account: account(), previous: nil, limit: strength.candidates)
            let ipv6Candidates = EndpointCatalog.candidates(account: account(), previous: nil, family: .ipv6, limit: strength.candidates)
            XCTAssertEqual(ipv6Candidates.count, strength.candidates)
            XCTAssertLessThanOrEqual(candidates.count, strength.candidates)
        }
        XCTAssertGreaterThan(EndpointCatalog.candidates(account: account(), previous: nil, limit: 96).count, 48)
    }

    func testDNSLeakProtectionRoutesUpstreamAndBootstrapThroughSelectedProxy() throws {
        var value = UserSettings(); value.customDNS = "https://dns.google/dns-query\n8.8.8.8"
        let result = try config(value)
        let dns = try XCTUnwrap(result["dns"] as? [String: Any])
        for key in ["nameserver", "default-nameserver", "proxy-server-nameserver"] {
            XCTAssertTrue(try XCTUnwrap(dns[key] as? [String]).allSatisfy { $0.hasSuffix("#WG 8.39.125.159:2408") })
        }
        let proxies = try XCTUnwrap(result["proxies"] as? [[String: Any]])
        XCTAssertEqual(proxies[0]["remote-dns-resolve"] as? Bool, false)
        value.dnsLeakProtection = false
        let unprotected = try XCTUnwrap(config(value)["dns"] as? [String: Any])
        XCTAssertTrue(try XCTUnwrap(unprotected["nameserver"] as? [String]).allSatisfy { !$0.contains("#") })
    }

    func testActualSDKAcceptsCustomDNSAndMTUForAllProtocols() throws {
        for family in IPAddressFamily.allCases {
            try CoreRuntime.setup(isExtension: false, family: family)
            for kind in WARPProtocol.allCases {
                var value = UserSettings(); value.addressFamily = family; value.mtu = 1400
                value.customDNS = "https://dns.google/dns-query\ntls://1.1.1.1"
                let object = try config(value, kind: kind)
                XCTAssertEqual((object["tun"] as? [String: Any])?["mtu"] as? Int, 1400)
                let text = String(decoding: try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes]), as: UTF8.self)
                var error: NSError?
                XCTAssertTrue(ClashCheckConfig(text, &error), "\(kind): \(error?.localizedDescription ?? "")")
            }
        }
    }

    func testNoDNSIssuedPreservesSystemDNSRoutesAndDisablesHijack() throws {
        var value = UserSettings(); value.doNotSetDNS = true; value.dnsLeakProtection = false; value.customDNS = "ignored#DIRECT"
        let settings = try TunnelNetworkSettings.make(endpoint: WARPEndpoint.fixtures[0], mtu: 1400, dnsAddress: "198.18.0.2", preferences: value,
            systemDNS: ["192.168.1.1", "2606:4700:4700::1111"])
        XCTAssertNil(settings.dnsSettings)
        XCTAssertEqual(settings.ipv4Settings?.includedRoutes?.map(\.destinationAddress), ["0.0.0.0", "128.0.0.0"])
        XCTAssertEqual(settings.ipv6Settings?.includedRoutes?.map(\.destinationNetworkPrefixLength), [1, 1])
        XCTAssertTrue(settings.ipv4Settings!.excludedRoutes!.contains { $0.destinationAddress == "192.168.1.1" })
        XCTAssertTrue(settings.ipv6Settings!.excludedRoutes!.contains { $0.destinationAddress == "2606:4700:4700::1111" })
        let result = try config(value)
        XCTAssertEqual((result["tun"] as? [String: Any])?["dns-hijack"] as? [String], [])
        XCTAssertFalse(String(describing: result).contains("ignored#DIRECT"))
    }

    func testTimeoutIsPassedToRealControllerAndNoProxyPortsOpen() throws {
        let controller = try ProbeController.allocate()
        let node = WARPEndpoint.fixtures[0]
        let components = try XCTUnwrap(URLComponents(url: controller.url(endpoint: node, timeout: 7), resolvingAgainstBaseURL: false))
        XCTAssertEqual(components.queryItems?.first { $0.name == "timeout" }?.value, "7000")
        let text = try WARPConfiguration.render(endpoints: [node], selected: node, account: account(), tunnel: false, controller: controller)
        let result = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
        XCTAssertEqual(result["external-controller"] as? String, controller.address)
        XCTAssertEqual(result["secret"] as? String, controller.secret)
        for key in ["port", "socks-port", "mixed-port"] { XCTAssertEqual(result[key] as? Int, 0) }
        XCTAssertEqual((result["tun"] as? [String: Any])?["enable"] as? Bool, false)
    }

    func testAutomaticSelectionChoosesLowestPositiveLatency() {
        let nodes = WARPEndpoint.fixtures(for: .wg)
        let reliable = ProbeResult(endpoint: nodes[0], samples: [100, 110, 120], testedAt: now)
        let fast = ProbeResult(endpoint: nodes[1], samples: [20, -1, -1], testedAt: now)
        let failed = ProbeResult(endpoint: nodes[2], samples: [-1, -1, -1], testedAt: now)
        XCTAssertEqual(ProbeResult.fastest([reliable, fast, failed]), nodes[1])
        XCTAssertNil(ProbeResult.fastest([failed]))
    }
}
