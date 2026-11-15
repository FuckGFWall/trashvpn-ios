import Foundation

struct ProbeResult: Codable, Equatable, Sendable {
    let endpoint: WARPEndpoint
    let samples: [Int32]
    let testedAt: Date
    var downloadMbps: [Double]? = nil
    var googleSuccesses: Int? = nil
    var qualityVersion: Int? = nil
    static let minimumMbps = 3.0
    var speedMbps: Double? {
        guard let values = downloadMbps, !values.isEmpty else { return nil }
        return values.min()
    }
    var jitter: Int32 {
        let groups = [samples.enumerated().filter { $0.offset % 2 == 0 && $0.element > 0 }.map(\.element),
                      samples.enumerated().filter { $0.offset % 2 == 1 && $0.element > 0 }.map(\.element)]
        return groups.map { ($0.max() ?? 0) - ($0.min() ?? 0) }.max() ?? 0
    }
    func passesStability(_ strength: UserSettings.Strength) -> Bool {
        guard qualityVersion == 2, samples.count == strength.rounds, successes.count >= strength.requiredSuccesses,
              (googleSuccesses ?? 0) >= max(1, strength.rounds / 2 - 1), let median, median <= 1500,
              Double(jitter) <= max(200, Double(median) * strength.jitterFactor) else { return false }
        return true
    }
    func qualifies(_ strength: UserSettings.Strength) -> Bool {
        guard passesStability(strength),
              let speeds = downloadMbps, speeds.count == strength.downloadRounds,
              speeds.allSatisfy({ $0.isFinite && $0 >= Self.minimumMbps }),
              let minimum = speeds.min(), let maximum = speeds.max(), minimum / maximum >= strength.speedConsistency else { return false }
        return true
    }
    var successes: [Int32] { samples.filter { $0 > 0 } }
    var median: Int32? { let values = successes.sorted(); return values.isEmpty ? nil : values[values.count / 2] }
    var label: String { (median.map { "\($0) ms · \(successes.count)/\(samples.count)" } ?? "无法连通") + (speedMbps.map { String(format: " · %.1f Mbps", $0) } ?? "") }
    static func isBetter(_ lhs: ProbeResult, _ rhs: ProbeResult) -> Bool {
        if lhs.successes.count != rhs.successes.count { return lhs.successes.count > rhs.successes.count }
        if lhs.median != rhs.median { return (lhs.median ?? .max) < (rhs.median ?? .max) }
        return lhs.endpoint.id < rhs.endpoint.id
    }
    static func fastest(_ results: [ProbeResult]) -> WARPEndpoint? {
        results.filter { $0.median != nil }.min {
            if $0.median != $1.median { return $0.median! < $1.median! }
            return isBetter($0, $1)
        }?.endpoint
    }
}
