import Foundation

enum NodeMeasurementKind: String, Sendable { case latency, download }

struct NodeMeasurement: Codable, Equatable, Sendable {
    var latencyMS: Int?
    var downloadMbps: Double?
}

struct NodeMeasurementStore {
    var root: URL?
    private struct Snapshot: Codable {
        let accountFingerprint: String
        let cacheCreatedAt: Date
        let values: [String: NodeMeasurement]
    }
    private func url(_ cache: NodeCache) throws -> URL {
        let root = try root ?? WARPConfiguration.container()
        return root.appendingPathComponent("measurements-\(cache.kind.rawValue)-\(cache.addressFamily.rawValue).json")
    }
    func load(for cache: NodeCache) -> [String: NodeMeasurement] {
        guard let url = try? url(cache), let data = try? Data(contentsOf: url),
              let stored = try? JSONDecoder().decode(Snapshot.self, from: data),
              stored.accountFingerprint == cache.accountFingerprint, stored.cacheCreatedAt == cache.createdAt else { return [:] }
        let ids = Set(cache.results.map { $0.endpoint.id })
        return stored.values.filter { ids.contains($0.key) }
    }
    func save(_ values: [String: NodeMeasurement], for cache: NodeCache) throws {
        try JSONEncoder().encode(Snapshot(accountFingerprint: cache.accountFingerprint, cacheCreatedAt: cache.createdAt, values: values))
            .write(to: url(cache), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }
}
