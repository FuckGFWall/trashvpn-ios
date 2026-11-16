import Foundation

/// Metadata observed through the current WARP tunnel, never inferred from the ingress IP.
struct ConnectionLocation: Equatable, Sendable {
    let country: String
    let colo: String

    init?(trace: Data) {
        let fields = Dictionary(String(decoding: trace, as: UTF8.self).split(whereSeparator: \.isNewline).compactMap { line -> (String, String)? in
            let pair = line.split(separator: "=", maxSplits: 1)
            guard pair.count == 2 else { return nil }
            return (String(pair[0]), String(pair[1]).trimmingCharacters(in: .whitespaces))
        }, uniquingKeysWith: { _, last in last })
        guard ["on", "plus"].contains(fields["warp"] ?? ""),
              let country = fields["loc"]?.uppercased(), country.utf8.count == 2,
              country.utf8.allSatisfy({ (65...90).contains($0) }),
              Locale.Region.isoRegions.contains(where: { $0.identifier == country }),
              let colo = fields["colo"]?.uppercased(), colo.utf8.count == 3,
              colo.utf8.allSatisfy({ (65...90).contains($0) }) else { return nil }
        // Match the previous WARP exit verification: flag from `loc`, airport from `colo`.
        // These describe different things and do not need to be in the same country.
        self.country = country; self.colo = colo
    }

    var flag: String {
        return String(String.UnicodeScalarView(country.unicodeScalars.compactMap { UnicodeScalar(127397 + $0.value) }))
    }
    var label: String { "国家: \(flag)　数据中心: \(colo)" }
    func localizedLabel(in language: AppLanguage) -> String {
        let text: LocalizedText = "国家: \(flag)　数据中心: \(colo)"
        return text.localized(in: language)
    }

    static func fetch(settings: UserSettings) async throws -> Self {
        let primary = settings.doNotSetDNS ? "1.1.1.1" : "www.cloudflare.com"
        do { return try await fetch(host: primary) }
        catch {
            try Task.checkCancellation()
            // A cold tunnel or DNS lookup may transiently fail. Retry once with Cloudflare's
            // TLS-valid literal address, still requiring warp=on/plus through the system VPN.
            try await Task.sleep(for: .seconds(1))
            return try await fetch(host: "1.1.1.1")
        }
    }

    private static func fetch(host: String) async throws -> Self {
        let options = URLSessionConfiguration.ephemeral
        options.connectionProxyDictionary = [:]
        options.urlCredentialStorage = nil
        options.timeoutIntervalForResource = 20
        let session = URLSession(configuration: options)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: URL(string: "https://\(host)/cdn-cgi/trace?trashvpn=\(UUID().uuidString)")!)
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        request.timeoutInterval = 15
        let (data, response) = try await session.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200, let location = Self(trace: data) else {
            throw WARPError.message("暂时无法读取当前 WARP 出口位置。")
        }
        return location
    }
}
