import Clash
import Foundation
import NetworkExtension
import XCTest
@testable import TrashVPN

final class IPv6Tests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_790_000_000)
    private func account(_ kind: WARPProtocol) -> WARPAccount {
        var value = WARPAccount.make(kind: kind)
        value.id = "test-id"; value.token = "test-token"; value.state = .registered
        value.peerPublicKey = kind == .masque ? WARPConfiguration.masquePeerPEM : WARPConfiguration.peerKey
        value.ipv4 = "172.16.0.2"; value.ipv6 = WARPConfiguration.masqueIPv6
        return value
    }

    func testEndpointParserPreservesIPv6PortAndRejectsAmbiguity() throws {
        let node = try XCTUnwrap(WARPEndpoint.parse("[2606:4700:d0::1]:2408", kind: .awg))
        XCTAssertEqual(node.host, "2606:4700:d0::1")
        XCTAssertEqual(node.address, "[2606:4700:d0::1]:2408")
        XCTAssertEqual(node.family, .ipv6)
        for value in ["2606:4700:d0::1:2408", "[::1]:0", "[::1]:65536", "[fe80::1%en0]:2408", "example.com:2408", "[::1]:443/path"] {
            XCTAssertNil(WARPEndpoint.parse(value, kind: .wg), value)
        }
        XCTAssertNotNil(WARPEndpoint.parse("8.6.112.1:2408", kind: .wg))
    }

    func testRegistrationKeepsBothServerFamiliesAndAssignedIPv6() throws {
        let json = #"{"config":{"interface":{"addresses":{"v4":"172.16.0.2/32","v6":"2606:4700:110::1234/128"}},"peers":[{"endpoint":{"v4":"162.159.192.1:2408","v6":"[2606:4700:d0::1]:2408"}}]}}"#
        let value = try WARPRegistration.apply(Data(json.utf8), to: account(.wg), requireIdentity: false)
        XCTAssertEqual(value.endpoints.map(\.family), [.ipv4, .ipv6])
        XCTAssertEqual(value.ipv6, "2606:4700:110::1234")
    }

    func testIPv6CatalogFiltersCachedAndRegisteredIPv4ForAllProtocols() throws {
        for kind in WARPProtocol.allCases {
            var value = account(kind)
            value.endpoints = [WARPEndpoint(host: "2606:4700:103::9", port: 443, kind: kind)] + WARPEndpoint.fixtures(for: kind)
            let candidates = EndpointCatalog.candidates(account: value, previous: nil, family: .ipv6)
            XCTAssertEqual(candidates.first, value.endpoints.first)
            XCTAssertTrue(candidates.count >= 20)
            XCTAssertEqual(Set(candidates.map(\.id)).count, candidates.count)
            XCTAssertTrue(candidates.allSatisfy { $0.isValid && $0.family == .ipv6 && $0.kind == kind })
        }
    }

    func testActualSDKAcceptsIPv6WGAndAWGAndMASQUEWithDualStackTraffic() throws {
        try CoreRuntime.setup(isExtension: false, family: .ipv6)
        for kind in WARPProtocol.allCases {
            let value = account(kind)
            let nodes = Array(EndpointCatalog.candidates(account: value, previous: nil, family: .ipv6).prefix(2))
            for tunnel in [false, true] {
                let text = try WARPConfiguration.render(endpoints: nodes, selected: nodes[0], account: value, tunnel: tunnel, family: .ipv6)
                let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
                XCTAssertEqual(object["ipv6"] as? Bool, true)
                XCTAssertEqual((object["tun"] as? [String: Any])?["enable"] as? Bool, tunnel)
                let proxies = try XCTUnwrap(object["proxies"] as? [[String: Any]])
                XCTAssertTrue((proxies[0]["ipv6"] as? String ?? "").contains(value.ipv6))
                if kind != .masque { XCTAssertEqual(proxies[0]["allowed-ips"] as? [String], ["0.0.0.0/0", "::/0"]) }
                var error: NSError?
                XCTAssertTrue(ClashCheckConfig(text, &error), "\(kind): \(error?.localizedDescription ?? "")")
            }
        }
    }

    func testMissingAssignedIPv6AndMixedFamiliesCannotStart() throws {
        var value = account(.wg); value.ipv6 = ""
        let node = WARPEndpoint(host: "2606:4700:d0::1", port: 2408)
        XCTAssertThrowsError(try WARPConfiguration.render(endpoints: [node], selected: node, account: value, tunnel: false, family: .ipv6))
        value.ipv6 = WARPConfiguration.masqueIPv6
        XCTAssertThrowsError(try WARPConfiguration.render(endpoints: [node] + WARPEndpoint.fixtures(for: .wg), selected: node, account: value, tunnel: true, family: .ipv6))
    }

    func testCacheIsolationAndLegacyIPv4MigrationNeverRenewExpiry() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = NodeCacheStore(root: directory)
        let value = account(.wg)
        let ipv4 = try NodeCache(account: value, results: [ProbeResult(endpoint: WARPEndpoint.fixtures[0], samples: [10, 20, 30], testedAt: now)], now: now)
        let node = WARPEndpoint(host: "2606:4700:d0::1", port: 2408)
        let ipv6 = try NodeCache(account: value, results: [ProbeResult(endpoint: node, samples: [11, 21, 31], testedAt: now)], now: now, family: .ipv6)
        try store.save(ipv4); try store.save(ipv6)
        XCTAssertEqual(try store.load(.wg), ipv4)
        XCTAssertEqual(try store.load(.wg, family: .ipv6), ipv6)
        XCTAssertFalse(ipv6.isValid(for: value, now: now, family: .ipv4))
        XCTAssertTrue(ipv6.isValid(for: value, now: now, family: .ipv6))
        XCTAssertFalse(ipv6.isValid(for: value, now: now.addingTimeInterval(21600), family: .ipv6))
        var legacy = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(ipv4)) as? [String: Any])
        legacy.removeValue(forKey: "family")
        try JSONSerialization.data(withJSONObject: legacy).write(to: directory.appendingPathComponent("wg.json"))
        let migrated = try XCTUnwrap(store.load(.wg))
        XCTAssertEqual(migrated.addressFamily, .ipv4)
        XCTAssertEqual(migrated.expiresAt, ipv4.expiresAt)
        XCTAssertTrue(migrated.isValid(for: value, now: now))
    }

    func testHostExclusionUsesIPv6Slash128AndBothDefaultRoutesRemainCaptured() throws {
        for node in [WARPEndpoint(host: "2606:4700:d0::1", port: 2408), WARPEndpoint.fixtures[0]] {
            let settings = try TunnelNetworkSettings.make(endpoint: node, mtu: 1280, dnsAddress: "198.18.0.2")
            XCTAssertEqual(settings.ipv4Settings?.includedRoutes?.count, 1)
            XCTAssertEqual(settings.ipv6Settings?.includedRoutes?.count, 1)
            XCTAssertEqual(settings.dnsSettings?.matchDomains, [""])
            if node.family == .ipv6 {
                XCTAssertEqual(settings.ipv6Settings?.excludedRoutes?.first?.destinationAddress, node.host)
                XCTAssertEqual(settings.ipv6Settings?.excludedRoutes?.first?.destinationNetworkPrefixLength, 128)
                XCTAssertTrue(settings.ipv4Settings?.excludedRoutes?.isEmpty ?? true)
            } else {
                XCTAssertEqual(settings.ipv4Settings?.excludedRoutes?.first?.destinationSubnetMask, "255.255.255.255")
                XCTAssertTrue(settings.ipv6Settings?.excludedRoutes?.isEmpty ?? true)
            }
        }
    }

    func testSwitchFamilyReusesIdentityAndPreservesOtherFamilyCache() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let accounts = MemoryAccounts()
        let caches = NodeCacheStore(root: directory)
        let registration = MockRegistration()
        let value = account(.awg)
        try accounts.save(value)
        let ipv4 = try NodeCache(account: value, results: [ProbeResult(endpoint: WARPEndpoint.fixtures(for: .awg)[0], samples: [10, 20, 30], testedAt: now)], now: now)
        try caches.save(ipv4)
        let instant = now
        let service = NodePreparation(accounts: accounts, caches: caches, registration: registration,
            optimizer: IPv6OptimizerStub(), family: .ipv6, now: { instant })
        let first = try await service.prepare(kind: .awg) { _ in }
        let reopened = try await service.prepare(kind: .awg) { _ in }
        XCTAssertFalse(first.reusedCache); XCTAssertTrue(reopened.reusedCache)
        XCTAssertEqual(first.cache, reopened.cache)
        XCTAssertEqual(first.cache.accountFingerprint, ipv4.accountFingerprint)
        XCTAssertEqual(try caches.load(.awg), ipv4)
        XCTAssertEqual(try accounts.load(.awg), value)
        let registrations = await registration.registrations
        XCTAssertEqual(registrations, 0)
    }
}

private struct IPv6OptimizerStub: NodeOptimizing {
    func optimize(account: WARPAccount, previous: NodeCache?,
        progress: @escaping @Sendable (PreparationUpdate) async -> Void) async throws -> [ProbeResult] {
        [ProbeResult(endpoint: WARPEndpoint(host: "2606:4700:d0::1", port: 2408, kind: account.kind),
            samples: Array(repeating: 100, count: UserSettings.Strength.medium.rounds), testedAt: Date(), downloadMbps: Array(repeating: 20, count: UserSettings.Strength.medium.downloadRounds), googleSuccesses: UserSettings.Strength.medium.rounds / 2, qualityVersion: 2)]
    }
}
