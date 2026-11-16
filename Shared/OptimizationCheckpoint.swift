import Foundation

/// Contains measurements, never registration credentials. Its age starts with the original scan.
struct OptimizationCheckpoint: Codable, Equatable, Sendable {
    let schema: Int
    let id: UUID
    let kind: WARPProtocol
    let family: IPAddressFamily
    let accountFingerprint: String
    let measurementFingerprint: String
    let startedAt: Date
    let candidates: [WARPEndpoint]
    var screening: [String: ProbeResult] = [:]
    var finalists: [WARPEndpoint]?
    var completed: [ProbeResult] = []
    var partial: ProbeResult?
    var progress: PreparationProgress
    var userInitiated: Bool?

    init(account: WARPAccount, settings: UserSettings, candidates: [WARPEndpoint], now: Date = Date(), userInitiated: Bool = false) {
        schema = 1; id = UUID(); kind = account.kind; family = settings.addressFamily
        accountFingerprint = account.fingerprint; measurementFingerprint = settings.measurementFingerprint
        startedAt = now; self.candidates = candidates
        self.userInitiated = userInitiated
        progress = .init(stage: .candidates, fraction: 0.36, title: "生成候选端点",
            detail: "已汇总 \(candidates.count) 个 \(family.label) 端点，准备逐个检查")
    }

    func isValid(account: WARPAccount, settings: UserSettings, now: Date) -> Bool {
        guard schema == 1, account.isRegistered, account.kind == kind, settings.tunnelProtocol == kind,
              family == settings.addressFamily, account.fingerprint == accountFingerprint,
              settings.measurementFingerprint == measurementFingerprint,
              (settings.cacheNeverExpires || now >= startedAt && now < settings.cacheExpiry(from: startedAt)),
              !candidates.isEmpty, candidates.count <= settings.strength.candidates,
              Set(candidates.map(\.id)).count == candidates.count,
              candidates.allSatisfy({ $0.isValid && $0.kind == kind && $0.family == family }),
              progress.fraction.isFinite, (0...1).contains(progress.fraction) else { return false }
        let screenRounds = kind == .masque ? 3 : 2
        guard screening.allSatisfy({ id, result in
            id == result.endpoint.id && candidates.contains(result.endpoint) && !result.samples.isEmpty
                && result.samples.count <= screenRounds && result.samples.allSatisfy { $0 > 0 || $0 == -1 }
        }) else { return false }
        guard let finalists else { return completed.isEmpty && partial == nil }
        guard !finalists.isEmpty, finalists.count <= settings.strength.finalists,
              Set(finalists.map(\.id)).count == finalists.count,
              finalists.allSatisfy({ candidates.contains($0) && screening[$0.id]?.median != nil }),
              completed.count <= finalists.count,
              completed.enumerated().allSatisfy({ $0.element.endpoint == finalists[$0.offset] && validQuality($0.element, settings: settings) }) else { return false }
        if let partial {
            guard completed.count < finalists.count, partial.endpoint == finalists[completed.count], validQuality(partial, settings: settings) else { return false }
        }
        return true
    }

    private func validQuality(_ result: ProbeResult, settings: UserSettings) -> Bool {
        let successes = result.samples.enumerated().filter { $0.offset % 2 == 1 && $0.element > 0 }.count
        if result.qualityVersion == 3 {
            return result.qualityProfile == settings.qualityProfile && settings.qualityProfile.isValid
                && result.samples.count <= settings.strength.maximumRounds && result.samples.allSatisfy { $0 > 0 || $0 == -1 }
                && result.googleSuccesses == successes
                && result.downloadMbps.map { $0.count <= (settings.downloadTestEnabled ? 1 : 0) && $0.allSatisfy { $0.isFinite && $0 >= 0 } } == true
                && (result.downloadMbps?.isEmpty == true || result.passesStability(settings.qualityProfile))
        }
        return result.qualityVersion == 2 && result.samples.count <= settings.strength.rounds
            && result.samples.allSatisfy { $0 > 0 || $0 == -1 }
            && result.googleSuccesses == successes
            && result.downloadMbps.map { $0.count <= settings.strength.downloadRounds && $0.allSatisfy { $0.isFinite && $0 >= 0 } } == true
            && (result.downloadMbps?.isEmpty == true || result.passesStability(settings.strength))
    }

    var displayResults: [ProbeResult] {
        var values = screening
        for result in completed { values[result.endpoint.id] = result }
        if let partial { values[partial.endpoint.id] = partial }
        return values.values.sorted(by: ProbeResult.isBetter)
    }
}

protocol OptimizationCheckpointStoring: Sendable {
    func load(_ kind: WARPProtocol, family: IPAddressFamily) throws -> OptimizationCheckpoint?
    func save(_ checkpoint: OptimizationCheckpoint) throws
    func remove(_ kind: WARPProtocol, family: IPAddressFamily) throws
}

struct OptimizationCheckpointStore: OptimizationCheckpointStoring {
    var root: URL?
    private func url(_ kind: WARPProtocol, family: IPAddressFamily) throws -> URL {
        let directory = try root ?? WARPConfiguration.container().appendingPathComponent("optimization-checkpoints")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("\(kind.rawValue)-\(family.rawValue).json")
    }
    func load(_ kind: WARPProtocol, family: IPAddressFamily) throws -> OptimizationCheckpoint? {
        let path = try url(kind, family: family)
        guard FileManager.default.fileExists(atPath: path.path), let data = try? Data(contentsOf: path) else { return nil }
        return try? JSONDecoder().decode(OptimizationCheckpoint.self, from: data)
    }
    func save(_ checkpoint: OptimizationCheckpoint) throws {
        try JSONEncoder().encode(checkpoint).write(to: url(checkpoint.kind, family: checkpoint.family),
            options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }
    func remove(_ kind: WARPProtocol, family: IPAddressFamily) throws {
        let path = try url(kind, family: family)
        if FileManager.default.fileExists(atPath: path.path) { try FileManager.default.removeItem(at: path) }
    }
}
