import Clash
import Foundation
import XCTest
@testable import TrashVPN

final class NodeExportTests: XCTestCase {
    private let date = Date(timeIntervalSince1970: 1_790_000_000)
    private func fixture(_ kind: WARPProtocol, family: IPAddressFamily = .ipv4) throws -> (WARPAccount, NodeCache) {
        var account = WARPAccount.make(kind: kind)
        account.id = "do-not-export-device-id"; account.token = "do-not-export-api-token"
        account.peerPublicKey = kind == .masque ? WARPConfiguration.masquePeerPEM : WARPConfiguration.peerKey
        account.ipv4 = "172.16.0.2"; account.ipv6 = WARPConfiguration.masqueIPv6; account.reserved = [11, 22, 33]; account.state = .registered
        let nodes = family == .ipv4 ? Array(WARPEndpoint.fixtures(for: kind).prefix(2)) : [
            WARPEndpoint(host: kind == .masque ? "2606:4700:103::1" : "2606:4700:d0::1", port: kind == .masque ? 443 : 2408, kind: kind)]
        let results = nodes.map { ProbeResult(endpoint: $0, samples: Array(repeating: 100, count: 8), testedAt: date,
            downloadMbps: [12, 11, 12], googleSuccesses: 4, qualityVersion: 2) }
        var settings = UserSettings(); settings.tunnelProtocol = kind; settings.addressFamily = family
        return (account, try NodeCache(account: account, results: results, now: date, family: family, settings: settings))
    }

    func testFormatsAreFilteredWithoutLosingProtocolOptions() throws {
        XCTAssertEqual(NodeExportFormat.available(for: .wg), [.v2ray, .clash, .singBox])
        for kind in [WARPProtocol.awg, .masque] {
            XCTAssertEqual(NodeExportFormat.available(for: kind), [.clash])
            let (account, cache) = try fixture(kind)
            for format in [NodeExportFormat.v2ray, .singBox] {
                XCTAssertThrowsError(try NodeExporter.render(cache: cache, account: account, format: format, mtu: 1280))
            }
        }
    }

    func testEveryV2RayLinkRoundTripsKeysAddressesAndReservedBytes() throws {
        for family in IPAddressFamily.allCases {
            let (account, cache) = try fixture(.wg, family: family)
            let payload = try NodeExporter.render(cache: cache, account: account, format: .v2ray, mtu: 1400)
            let lines = payload.text.split(separator: "\n")
            XCTAssertEqual(lines.count, cache.results.count)
            for (line, result) in zip(lines, cache.results) {
                let url = try XCTUnwrap(URLComponents(string: String(line)))
                XCTAssertEqual(url.scheme, "wireguard")
                XCTAssertEqual(url.user, account.privateKey)
                XCTAssertEqual(url.host?.trimmingCharacters(in: CharacterSet(charactersIn: "[]")), result.endpoint.host)
                XCTAssertEqual(url.port, result.endpoint.port)
                let query = Dictionary((url.queryItems ?? []).map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { _, new in new })
                XCTAssertEqual(query["publickey"], account.peerPublicKey)
                XCTAssertEqual(query["reserved"], "11,22,33")
                XCTAssertEqual(query["mtu"], "1400")
                XCTAssertEqual(query["address"], "172.16.0.2/32" + (family == .ipv6 ? ",\(account.ipv6)/128" : ""))
                XCTAssertEqual(url.fragment, result.endpoint.name)
            }
        }
    }

    func testClashYAMLIsAcceptedByActualSDKForEveryProtocolAndFamily() throws {
        for family in IPAddressFamily.allCases {
            try CoreRuntime.setup(isExtension: false, family: family)
            for kind in WARPProtocol.allCases {
                let (account, cache) = try fixture(kind, family: family)
                let payload = try NodeExporter.render(cache: cache, account: account, format: .clash, mtu: 1280)
                var error: NSError?
                XCTAssertTrue(ClashCheckConfig(payload.text, &error), error?.localizedDescription ?? "Invalid exported YAML")
                XCTAssertTrue(payload.text.hasPrefix("proxies:"))
                XCTAssertEqual(payload.count, cache.results.count)
                XCTAssertEqual(payload.text.contains("amnezia-wg-option:"), kind == .awg)
                if kind == .awg { XCTAssertTrue(payload.text.contains("i1:")) }
                if kind == .masque { XCTAssertTrue(payload.text.contains("consumer-masque.cloudflareclient.com")) }
                XCTAssertFalse(payload.text.contains(account.token))
                XCTAssertFalse(payload.text.contains(account.id))
            }
        }
    }

    func testSingBoxUsesModernEndpointsAndPreservesPeerParameters() throws {
        for family in IPAddressFamily.allCases {
            let (account, cache) = try fixture(.wg, family: family)
            let payload = try NodeExporter.render(cache: cache, account: account, format: .singBox, mtu: 1400)
            let attachment = XCTAttachment(data: Data(payload.text.utf8), uniformTypeIdentifier: "public.json")
            attachment.name = "Synthetic sing-box \(family.rawValue) export"
            attachment.lifetime = .keepAlways; add(attachment)
            let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(payload.text.utf8)) as? [String: Any])
            let endpoints = try XCTUnwrap(object["endpoints"] as? [[String: Any]])
            XCTAssertEqual(endpoints.count, cache.results.count)
            for (endpoint, result) in zip(endpoints, cache.results) {
                XCTAssertEqual(endpoint["type"] as? String, "wireguard")
                XCTAssertEqual(endpoint["tag"] as? String, result.endpoint.name)
                XCTAssertEqual(endpoint["private_key"] as? String, account.privateKey)
                XCTAssertEqual(endpoint["system"] as? Bool, false)
                XCTAssertEqual(endpoint["mtu"] as? Int, 1400)
                XCTAssertEqual((endpoint["address"] as? [String])?.count, family == .ipv6 ? 2 : 1)
                let peer = try XCTUnwrap((endpoint["peers"] as? [[String: Any]])?.first)
                XCTAssertEqual(peer["address"] as? String, result.endpoint.host)
                XCTAssertEqual(peer["port"] as? Int, result.endpoint.port)
                XCTAssertEqual(peer["public_key"] as? String, account.peerPublicKey)
                XCTAssertEqual(peer["reserved"] as? [Int], [11, 22, 33])
                XCTAssertEqual(peer["persistent_keepalive_interval"] as? Int, 0)
            }
            XCTAssertFalse(payload.text.contains(account.token))
            XCTAssertFalse(payload.text.contains(account.id))
        }
    }

    func testExportReadsOnlyRequestedLocalProtocolAndDoesNotRefreshItsAge() throws {
        let accounts = MemoryAccounts(); let caches = MemoryCaches()
        for kind in WARPProtocol.allCases {
            let (account, cache) = try fixture(kind); try accounts.save(account); try caches.save(cache)
        }
        let service = NodeExportService(accounts: accounts, caches: caches)
        let before = try XCTUnwrap(caches.load(.masque))
        let payload = try service.export(kind: .masque, family: .ipv4, format: .clash, mtu: 1280)
        XCTAssertEqual(payload.count, before.results.count)
        XCTAssertTrue(payload.text.contains("type: \"masque\""))
        XCTAssertFalse(payload.text.contains("amnezia-wg-option"))
        XCTAssertEqual(try caches.load(.masque), before)
        XCTAssertEqual(try service.count(kind: .masque, family: .ipv6), 0)
        XCTAssertThrowsError(try service.export(kind: .masque, family: .ipv6, format: .clash, mtu: 1280))
    }

    func testMissingOrMismatchedIdentityCannotExportAnotherDeviceKeys() throws {
        let accounts = MemoryAccounts(); let caches = MemoryCaches()
        let (account, cache) = try fixture(.wg); try caches.save(cache)
        let service = NodeExportService(accounts: accounts, caches: caches)
        XCTAssertEqual(try service.count(kind: .wg, family: .ipv4), 0)
        XCTAssertThrowsError(try service.export(kind: .wg, family: .ipv4, format: .v2ray, mtu: 1280))
        var different = account; different.id = "another-identity"; try accounts.save(different)
        XCTAssertEqual(try service.count(kind: .wg, family: .ipv4), 0)
        XCTAssertThrowsError(try service.export(kind: .wg, family: .ipv4, format: .clash, mtu: 1280))
    }
}
