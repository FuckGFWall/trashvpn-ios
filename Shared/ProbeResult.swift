import Foundation

/// Persist the requirements used for a measurement, including intentionally skipped downloads.
struct ProbeQualityProfile: Codable, Equatable, Sendable {
    let strength: UserSettings.Strength
    let downloadEnabled: Bool
    let minimumMbps: Double
    var isValid: Bool { minimumMbps.isFinite && (downloadEnabled ? (0.1...1000).contains(minimumMbps) : minimumMbps == 0) }
}

struct ProbeResult: Codable, Equatable, Sendable {
    let endpoint: WARPEndpoint
    let samples: [Int32]
    let testedAt: Date
    var downloadMbps: [Double]? = nil
    var googleSuccesses: Int? = nil
    var qualityVersion: Int? = nil
    var qualityProfile: ProbeQualityProfile? = nil
    static let minimumMbps = 3.0
    var speedMbps: Double? {
        guard let values = downloadMbps, !values.isEmpty else { return nil }
        return values.min()
    }
    var jitter: Int32 {
        let window = samples.enumerated().filter { $0.offset >= qualityWindowStart }
        let groups = [window.filter { $0.offset % 2 == 0 && $0.element > 0 }.map(\.element),
                      window.filter { $0.offset % 2 == 1 && $0.element > 0 }.map(\.element)]
        return groups.map { ($0.max() ?? 0) - ($0.min() ?? 0) }.max() ?? 0
    }
    func passesStability(_ strength: UserSettings.Strength) -> Bool {
        if qualityVersion == 3, let qualityProfile, qualityProfile.strength == strength { return passesStability(qualityProfile) }
        guard qualityVersion == 2, samples.count == strength.rounds, successes.count >= strength.requiredSuccesses,
              (googleSuccesses ?? 0) >= max(1, strength.rounds / 2 - 1), let median, median <= 1500,
              Double(jitter) <= max(200, Double(median) * strength.jitterFactor) else { return false }
        return true
    }
    func qualifies(_ strength: UserSettings.Strength) -> Bool {
        if qualityVersion == 3, let qualityProfile, qualityProfile.strength == strength { return qualifies(qualityProfile) }
        guard passesStability(strength),
              let speeds = downloadMbps, speeds.count == strength.downloadRounds,
              speeds.allSatisfy({ $0.isFinite && $0 >= Self.minimumMbps }),
              let minimum = speeds.min(), let maximum = speeds.max(), minimum / maximum >= strength.speedConsistency else { return false }
        return true
    }
    func passesStability(_ profile: ProbeQualityProfile) -> Bool {
        let window = Array(samples.suffix(profile.strength.minimumRounds))
        return qualityVersion == 3 && qualityProfile == profile && profile.isValid
            && samples.count <= profile.strength.maximumRounds && window.count == profile.strength.minimumRounds
            && samples.allSatisfy { $0 > 0 || $0 == -1 } && window.allSatisfy { $0 > 0 }
            && googleSuccesses == samples.enumerated().filter { $0.offset % 2 == 1 && $0.element > 0 }.count
            && median.map { $0 <= 1500 && Double(jitter) <= max(200, Double($0) * profile.strength.jitterFactor) } == true
    }
    func qualifies(_ profile: ProbeQualityProfile) -> Bool {
        guard passesStability(profile), let speeds = downloadMbps else { return false }
        return profile.downloadEnabled ? speeds.count == 1 && speeds.allSatisfy { $0.isFinite && $0 >= profile.minimumMbps } : speeds.isEmpty
    }
    func qualifies(settings: UserSettings) -> Bool {
        if qualityVersion == 3 { return qualifies(settings.qualityProfile) }
        return settings.downloadTestEnabled && settings.minimumDownloadMbps == Self.minimumMbps && qualifies(settings.strength)
    }
    /// Only add samples while a stable consecutive window can still fit in this node's budget.
    func needsMoreLatency(_ profile: ProbeQualityProfile) -> Bool {
        guard !passesStability(profile), samples.count < profile.strength.maximumRounds else { return false }
        let trailingSuccesses = samples.reversed().prefix { $0 > 0 }.count
        return trailingSuccesses + profile.strength.maximumRounds - samples.count >= profile.strength.minimumRounds
    }
    var measurementFinished: Bool {
        guard qualityVersion == 3, let qualityProfile else { return false }
        if !passesStability(qualityProfile) { return !needsMoreLatency(qualityProfile) }
        return !qualityProfile.downloadEnabled || downloadMbps?.count == 1
    }
    private var qualityWindowStart: Int { qualityVersion == 3 ? max(0, samples.count - (qualityProfile?.strength.minimumRounds ?? samples.count)) : 0 }
    var successes: [Int32] { samples.filter { $0 > 0 } }
    var median: Int32? { let values = samples.dropFirst(qualityWindowStart).filter { $0 > 0 }.sorted(); return values.isEmpty ? nil : values[values.count / 2] }
    var localizedLabel: LocalizedText {
        let latency: LocalizedText = median.map { "\($0) ms · \(successes.count)/\(samples.count)" } ?? "无法连通"
        if qualityProfile?.downloadEnabled == false { return "\(latency) · 未测下载" }
        if let speedMbps { return "\(latency) · \(String(format: "%.1f", speedMbps)) Mbps" }
        return latency
    }
    var label: String { localizedLabel.source }
    static func isBetter(_ lhs: ProbeResult, _ rhs: ProbeResult) -> Bool {
        if lhs.qualityVersion == 3, rhs.qualityVersion == 3,
           let left = lhs.qualityProfile, let right = rhs.qualityProfile,
           lhs.qualifies(left), rhs.qualifies(right) {
            if lhs.median != rhs.median { return (lhs.median ?? .max) < (rhs.median ?? .max) }
            if lhs.jitter != rhs.jitter { return lhs.jitter < rhs.jitter }
            return lhs.endpoint.id < rhs.endpoint.id
        }
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
