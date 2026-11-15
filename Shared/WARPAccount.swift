import CryptoKit
import Foundation
import Security

struct WARPAccount: Codable, Equatable, Sendable {
    enum State: String, Codable { case created, enrolling, registered }
    let kind: WARPProtocol
    var id: String
    var token: String
    let privateKey: String
    let publicKey: String
    var peerPublicKey: String
    var ipv4: String
    var ipv6: String
    var reserved: [UInt8]
    var endpoints: [WARPEndpoint]
    var state: State
    let createdAt: Date

    var fingerprint: String {
        SHA256.hash(data: Data("\(kind.rawValue):\(id):\(publicKey)".utf8)).map { String(format: "%02x", $0) }.joined()
    }
    var isRegistered: Bool {
        state == .registered && !id.isEmpty && !token.isEmpty && !peerPublicKey.isEmpty && !ipv4.isEmpty
    }

    static func make(kind: WARPProtocol, now: Date = Date()) -> WARPAccount {
        let privateKey: String
        let publicKey: String
        if kind == .masque {
            let key = P256.Signing.PrivateKey()
            // The core expects SEC1 ECPrivateKey, while CryptoKit exports PKCS#8.
            let sec1 = Data([0x30, 0x77, 0x02, 0x01, 0x01, 0x04, 0x20]) + key.rawRepresentation
                + Data([0xa0, 0x0a, 0x06, 0x08, 0x2a, 0x86, 0x48, 0xce, 0x3d, 0x03, 0x01, 0x07,
                        0xa1, 0x44, 0x03, 0x42, 0x00]) + key.publicKey.x963Representation
            privateKey = sec1.base64EncodedString()
            publicKey = key.publicKey.derRepresentation.base64EncodedString()
        } else {
            let key = Curve25519.KeyAgreement.PrivateKey()
            privateKey = key.rawRepresentation.base64EncodedString()
            publicKey = key.publicKey.rawRepresentation.base64EncodedString()
        }
        return WARPAccount(kind: kind, id: "", token: "", privateKey: privateKey, publicKey: publicKey,
            peerPublicKey: "", ipv4: "", ipv6: "", reserved: [], endpoints: [], state: .created, createdAt: now)
    }
}

protocol AccountStoring: Sendable {
    func load(_ kind: WARPProtocol) throws -> WARPAccount?
    func save(_ account: WARPAccount) throws
}

struct KeychainAccountStore: AccountStoring {
    private func query(_ kind: WARPProtocol) throws -> [String: Any] {
        guard let group = Bundle.main.object(forInfoDictionaryKey: "WARPKeychainGroup") as? String,
              !group.contains("$("), !group.isEmpty else { throw WARPError.message("共享钥匙串签名配置缺失。") }
        return [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "com.leo.TrashVPN.warp.account.v1",
            kSecAttrAccount as String: kind.rawValue, kSecAttrAccessGroup as String: group]
    }

    func load(_ kind: WARPProtocol) throws -> WARPAccount? {
        var request = try query(kind)
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = item as? Data else {
            throw WARPError.message("无法读取注册身份（钥匙串 \(status)）。")
        }
        let account = try JSONDecoder().decode(WARPAccount.self, from: data)
        guard account.kind == kind else { throw WARPError.message("注册身份的协议不匹配。") }
        return account
    }

    func save(_ account: WARPAccount) throws {
        let request = try query(account.kind)
        let attributes: [String: Any] = [kSecValueData as String: try JSONEncoder().encode(account),
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        var status = SecItemUpdate(request as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            status = SecItemAdd(request.merging(attributes, uniquingKeysWith: { _, new in new }) as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw WARPError.message("无法保存注册身份（钥匙串 \(status)）。") }
    }
}
