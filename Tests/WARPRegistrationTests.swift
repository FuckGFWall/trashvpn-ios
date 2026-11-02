import Foundation
import XCTest
@testable import TrashVPN

final class RegistrationURLProtocol: URLProtocol, @unchecked Sendable {
    static var handler: ((URLRequest) throws -> (Int, Data))?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let (code, data) = try Self.handler!(request)
            let response = HTTPURLResponse(url: request.url!, statusCode: code, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}

final class WARPRegistrationTests: XCTestCase {
    private func registrar() -> WARPRegistration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RegistrationURLProtocol.self]
        return WARPRegistration(session: URLSession(configuration: configuration))
    }
    private func response(kind: WARPProtocol, identity: Bool = true) throws -> Data {
        var value: [String: Any] = ["config": ["peers": [["public_key": kind == .masque ? WARPConfiguration.masquePeerPEM : WARPConfiguration.peerKey,
            "endpoint": ["v4": kind == .masque ? "162.159.198.2:443" : "162.159.192.1:2408"]]],
            "interface": ["addresses": ["v4": "172.16.0.2", "v6": "2606:4700:110::1234"]]]]
        if identity { value["id"] = "mock-device"; value["token"] = "mock-token"; value["client_id"] = Data([1, 2, 3]).base64EncodedString() }
        return try JSONSerialization.data(withJSONObject: value)
    }
    func testRegistrationEmitsGranularProgressAndPersistsBeforeCompletion() async throws {
        let store = MemoryAccounts()
        let events = ProgressRecorder()
        RegistrationURLProtocol.handler = { [self] request in (200, try response(kind: .wg, identity: request.httpMethod == "POST")) }
        _ = try await registrar().ensureRegistered(kind: .wg, existing: nil, checkpoint: { try store.save($0) }, progress: { value in await events.append(value) })
        let values = await events.values
        XCTAssertEqual(values.map(\.stage), [.credentials, .registering, .enrolling, .validating, .registered])
        XCTAssertEqual(values.map(\.fraction), values.map(\.fraction).sorted())
        XCTAssertEqual(values.last?.fraction, PreparationProgress.registrationMilestone)
        XCTAssertTrue(try XCTUnwrap(store.load(.wg)).isRegistered)
    }

    override func tearDown() { RegistrationURLProtocol.handler = nil }

    func testFailedEnrollmentResumesPatchWithoutAnotherPostOrKeyRotation() async throws {
        let store = MemoryAccounts()
        var posts = 0; var patches = 0
        RegistrationURLProtocol.handler = { [self] request in
            if request.httpMethod == "POST" { posts += 1; return (200, try response(kind: .wg)) }
            patches += 1
            if patches == 1 { return (503, Data("{}".utf8)) }
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer mock-token")
            return (200, try response(kind: .wg, identity: false))
        }
        do {
            _ = try await registrar().ensureRegistered(kind: .wg, existing: nil) { try store.save($0) }
            XCTFail("first PATCH should fail")
        } catch {}
        let pending = try XCTUnwrap(store.load(.wg))
        XCTAssertEqual(pending.state, .enrolling)
        let final = try await registrar().ensureRegistered(kind: .wg, existing: pending) { try store.save($0) }
        XCTAssertTrue(final.isRegistered)
        XCTAssertEqual(final.privateKey, pending.privateKey)
        XCTAssertEqual(final.reserved, [1, 2, 3])
        XCTAssertEqual(posts, 1); XCTAssertEqual(patches, 2)
    }

    func testMASQUEEnrollsP256PublicKeyAndPreservesReturnedAddresses() async throws {
        let store = MemoryAccounts()
        var methods: [String] = []
        RegistrationURLProtocol.handler = { [self] request in
            methods.append(request.httpMethod!)
            XCTAssertEqual(request.value(forHTTPHeaderField: "CF-Client-Version"), "a-6.35-4471")
            if request.httpMethod == "POST" { return (200, try response(kind: .wg)) }
            return (200, try response(kind: .masque, identity: false))
        }
        let account = try await registrar().ensureRegistered(kind: .masque, existing: nil) { try store.save($0) }
        XCTAssertEqual(methods, ["POST", "PATCH"])
        XCTAssertTrue(account.isRegistered)
        XCTAssertEqual(Data(base64Encoded: account.privateKey)?.prefix(2), Data([0x30, 0x77]))
        XCTAssertEqual(Data(base64Encoded: account.publicKey)?.count, 91)
        XCTAssertEqual(account.ipv6, "2606:4700:110::1234")
        XCTAssertEqual(account.endpoints.first?.host, "162.159.198.2")
        XCTAssertEqual(account.id, "mock-device")
    }

    func testRegisteredAccountDoesNotPerformAnyHTTPRequest() async throws {
        let store = MemoryAccounts()
        RegistrationURLProtocol.handler = { [self] _ in (200, try response(kind: .wg)) }
        let account = try await registrar().ensureRegistered(kind: .wg, existing: nil) { try store.save($0) }
        RegistrationURLProtocol.handler = { _ in XCTFail("unexpected registration request"); return (500, Data()) }
        let reused = try await registrar().ensureRegistered(kind: .wg, existing: account) { try store.save($0) }
        XCTAssertEqual(account, reused)
    }

    func testMASQUECannotBeMarkedRegisteredWithWireGuardPeerKey() async throws {
        let store = MemoryAccounts()
        RegistrationURLProtocol.handler = { [self] _ in (200, try response(kind: .wg)) }
        do {
            _ = try await registrar().ensureRegistered(kind: .masque, existing: nil) { try store.save($0) }
            XCTFail("a WireGuard peer must not complete MASQUE enrollment")
        } catch {}
        let pending = try XCTUnwrap(store.load(.masque))
        XCTAssertEqual(pending.state, .enrolling)
        XCTAssertFalse(pending.isRegistered)
        XCTAssertEqual(pending.id, "mock-device")
    }
}

private actor ProgressRecorder {
    private(set) var values: [PreparationProgress] = []
    func append(_ value: PreparationProgress) { values.append(value) }
}
