import CryptoKit
import Foundation

protocol WARPRegistering: Sendable {
    func ensureRegistered(kind: WARPProtocol, existing: WARPAccount?,
        checkpoint: @escaping @Sendable (WARPAccount) throws -> Void,
        progress: @escaping @Sendable (PreparationProgress) async -> Void) async throws -> WARPAccount
}

extension WARPRegistering {
    func ensureRegistered(kind: WARPProtocol, existing: WARPAccount?, checkpoint: @escaping @Sendable (WARPAccount) throws -> Void) async throws -> WARPAccount {
        try await ensureRegistered(kind: kind, existing: existing, checkpoint: checkpoint, progress: { _ in })
    }
}

struct WARPRegistration: WARPRegistering {
    let session: URLSession
    init(session: URLSession? = nil) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 35
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        self.session = session ?? URLSession(configuration: configuration)
    }

    func ensureRegistered(kind: WARPProtocol, existing: WARPAccount?,
        checkpoint: @escaping @Sendable (WARPAccount) throws -> Void,
        progress: @escaping @Sendable (PreparationProgress) async -> Void = { _ in }) async throws -> WARPAccount {
        if let existing, existing.isRegistered {
            await progress(.init(stage: .registered, fraction: 0.5, title: "注册身份已就绪", detail: "复用已注册的 \(kind.label) 身份"))
            return existing
        }
        await progress(.init(stage: .credentials, fraction: 0.10, title: existing == nil ? "生成本机密钥" : "恢复未完成的注册", detail: "密钥只保存在本机共享钥匙串"))
        var account = existing ?? .make(kind: kind)
        guard account.kind == kind else { throw WARPError.message("注册协议不匹配。") }
        try checkpoint(account)
        let version = kind == .masque ? "v0a4471" : "v0a4005"
        let base = URL(string: "https://api.cloudflareclient.com/\(version)/reg")!
        if account.state == .created {
            try Task.checkCancellation()
            let key = kind == .masque ? Curve25519.KeyAgreement.PrivateKey().publicKey.rawRepresentation.base64EncodedString() : account.publicKey
            let payload: [String: Any]
            if kind == .masque {
                let date = ISO8601DateFormatter()
                date.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                payload = ["key": key, "install_id": "", "fcm_token": "", "tos": date.string(from: Date()),
                    "model": "PC", "serial_number": UUID().uuidString.prefix(8).description,
                    "os_version": "10", "key_type": "curve25519", "tunnel_type": "wireguard", "locale": "en_US"]
            } else { payload = ["key": key] }
            await progress(.init(stage: .registering, fraction: 0.24, title: "向 Cloudflare 创建注册", detail: "正在提交 \(kind.label) 设备公钥"))
            let response = try await request(url: base, method: "POST", token: nil, kind: kind, payload: payload)
            account = try Self.apply(response, to: account, requireIdentity: true)
            account.state = .enrolling
            // Save ID/token immediately: a failed PATCH must not mint another device.
            try checkpoint(account)
        }
        try Task.checkCancellation()
        await progress(.init(stage: .enrolling, fraction: 0.36, title: "激活隧道身份", detail: kind == .masque ? "正在登记 MASQUE 的 P-256 公钥" : "正在启用 WireGuard 设备身份"))
        let payload: [String: Any] = kind == .masque
            ? ["key": account.publicKey, "key_type": "secp256r1", "tunnel_type": "masque", "name": "TrashVPN"]
            : ["warp_enabled": true]
        let response = try await request(url: base.appendingPathComponent(account.id), method: "PATCH",
            token: account.token, kind: kind, payload: payload)
        account = try Self.apply(response, to: account, requireIdentity: false)
        await progress(.init(stage: .validating, fraction: 0.46, title: "校验注册结果", detail: "检查分配地址、对端公钥与设备身份"))
        guard !account.peerPublicKey.isEmpty, !account.ipv4.isEmpty else {
            throw WARPError.message("Cloudflare 返回的节点身份不完整，注册未完成。")
        }
        let validPeer: Bool
        if kind == .masque {
            let encoded = try WARPConfiguration.normalizePublicKey(account.peerPublicKey)
            validPeer = Data(base64Encoded: encoded).flatMap { try? P256.Signing.PublicKey(derRepresentation: $0) } != nil
        } else { validPeer = Data(base64Encoded: account.peerPublicKey)?.count == 32 }
        guard validPeer, WARPEndpoint(host: account.ipv4, port: 1, kind: kind).isValid else {
            throw WARPError.message("Cloudflare 未返回有效的 \(kind.label) 对端身份，注册尚未完成。")
        }
        account.state = .registered
        try checkpoint(account)
        await progress(.init(stage: .registered, fraction: 0.5, title: "注册完成", detail: "身份已安全保存，开始准备优选"))
        return account
    }

    private func request(url: URL, method: String, token: String?, kind: WARPProtocol, payload: [String: Any]) async throws -> Data {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(kind == .masque ? "WARP for Android" : "okhttp/3.12.1", forHTTPHeaderField: "User-Agent")
        request.setValue(kind == .masque ? "a-6.35-4471" : "a-6.11-2223", forHTTPHeaderField: "CF-Client-Version")
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        do {
            let (data, response) = try await session.data(for: request)
            guard let response = response as? HTTPURLResponse else { throw WARPError.message("注册服务响应无效。") }
            guard (200..<300).contains(response.statusCode) else {
                if response.statusCode == 429 { throw WARPError.message("Cloudflare 暂时限制注册频率，请稍后重试。已保存的身份不会丢失。") }
                throw WARPError.message("Cloudflare 注册失败（HTTP \(response.statusCode)）。请稍后重试。")
            }
            guard data.count <= 128 * 1024 else { throw WARPError.message("注册服务响应过大。") }
            return data
        } catch {
            if Task.isCancelled { throw CancellationError() }
            throw error
        }
    }

    static func apply(_ data: Data, to existing: WARPAccount, requireIdentity: Bool) throws -> WARPAccount {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw WARPError.message("Cloudflare 注册响应无法解析。")
        }
        let object = root["result"] as? [String: Any] ?? root
        var account = existing
        if let id = object["id"] as? String, !id.isEmpty { account.id = id }
        if let token = object["token"] as? String, !token.isEmpty { account.token = token }
        if requireIdentity && (account.id.isEmpty || account.token.isEmpty) {
            throw WARPError.message("Cloudflare 未返回完整注册身份。")
        }
        if let clientID = object["client_id"] as? String, let bytes = Data(base64Encoded: clientID), bytes.count == 3 {
            account.reserved = Array(bytes)
        }
        if let config = object["config"] as? [String: Any] {
            if let interface = config["interface"] as? [String: Any], let addresses = interface["addresses"] as? [String: Any] {
                if let v4 = addresses["v4"] as? String { account.ipv4 = v4.components(separatedBy: "/")[0] }
                if let v6 = addresses["v6"] as? String { account.ipv6 = v6.components(separatedBy: "/")[0] }
            }
            if let peer = (config["peers"] as? [[String: Any]])?.first {
                if let key = peer["public_key"] as? String, !key.isEmpty { account.peerPublicKey = key }
                if let endpoint = peer["endpoint"] as? [String: Any] {
                    let parsed = ["v4", "v6"].compactMap { key -> WARPEndpoint? in
                        guard let address = endpoint[key] as? String else { return nil }
                        return WARPEndpoint.parse(address, kind: account.kind)
                    }
                    if !parsed.isEmpty { account.endpoints = parsed }
                }
            }
        }
        return account
    }
}
