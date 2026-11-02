import Foundation
import Network

enum IPAddressFamily: String, Codable, CaseIterable, Identifiable, Sendable {
    case ipv4, ipv6
    var id: String { rawValue }
    var label: String { self == .ipv4 ? "IPv4" : "IPv6" }
    var queryMode: String { self == .ipv4 ? "ipv4-only" : "prefer-ipv6" }
    func contains(_ host: String) -> Bool {
        self == .ipv4 ? IPv4Address(host) != nil : IPv6Address(host) != nil && !host.contains("%")
    }
}

/// Preferences are separate from a running tunnel's immutable provider configuration.
struct NetworkPreferences: Codable, Equatable {
    var addressFamily: IPAddressFamily = .ipv4
    static func load() throws -> Self {
        let url = try WARPConfiguration.container().appendingPathComponent("network-preferences.json")
        guard FileManager.default.fileExists(atPath: url.path) else { return Self() }
        return try JSONDecoder().decode(Self.self, from: Data(contentsOf: url))
    }
    func save() throws {
        try JSONEncoder().encode(self).write(to: WARPConfiguration.container().appendingPathComponent("network-preferences.json"),
            options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }
}
