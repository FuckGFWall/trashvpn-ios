import Foundation

struct OptimizationCheckpointWriteError: LocalizedError {
    let underlying: Error
    var errorDescription: String? { let text: LocalizedText = "无法保存优选进度：\(underlying.localizedDescription)"; return text.localized() }
}

/// Serializes probe callbacks and commits each completed measurement before starting another.
actor OptimizationJournal {
    private var value: OptimizationCheckpoint
    private let store: any OptimizationCheckpointStoring
    init(_ value: OptimizationCheckpoint, store: any OptimizationCheckpointStoring) { self.value = value; self.store = store }
    func snapshot() -> OptimizationCheckpoint { value }
    private func save() throws {
        do { try store.save(value) } catch { throw OptimizationCheckpointWriteError(underlying: error) }
    }
    func publish(_ update: PreparationUpdate, to progress: @Sendable (PreparationUpdate) async -> Void) async {
        if case .progress(let next) = update {
            var saved = next
            saved.steps = next.steps ?? value.progress.steps
            saved.fraction = max(value.progress.fraction, next.fraction)
            value.progress = saved
            // Progress is saved before the next request as well as after each completed sample.
            // Measurement commits below propagate I/O errors; UI-only progress is best effort.
            do { try store.save(value) }
            catch { Diagnostics.record("progress checkpoint failed: \(error.localizedDescription)", process: "app") }
            await progress(.progress(value.progress))
        } else { await progress(update) }
    }
    func beginSupplement() throws -> OptimizationCheckpoint {
        value.candidates = EndpointCatalog.supplementalCandidates(for: value.candidates)
        value.screening = [:]
        value.supplementalScreening = true
        try save()
        return value
    }

    func screen(_ result: ProbeResult, at index: Int, followupLimit: Int) throws -> OptimizationCheckpoint {
        let node = result.endpoint
        if result.median != nil, node.kind != .masque, EndpointCatalog.alternatePorts.contains(node.port),
           !value.screening.values.contains(where: { $0.endpoint.port == node.port && $0.median != nil }) {
            // Try the working port on other WARP hosts. Keep the measured prefix and the
            // total budget intact; commit the revised order together with the first hit.
            let prefix = value.candidates.prefix(index + 1)
            let remaining = value.candidates.dropFirst(index + 1)
            var used = Set(prefix.map(\.id)).union(value.screening.keys)
            var followups: [WARPEndpoint] = []
            for candidate in remaining {
                let next = WARPEndpoint(host: candidate.host, port: node.port, kind: node.kind)
                if used.insert(next.id).inserted { followups.append(next) }
                if followups.count == followupLimit { break }
            }
            let promoted = Set(followups.map(\.id))
            let reordered = followups + remaining.filter { !promoted.contains($0.id) }
            value.candidates = Array(prefix) + reordered.prefix(remaining.count)
        }
        value.screening[node.id] = result
        try save()
        return value
    }
    func shortlist(_ endpoints: [WARPEndpoint]) throws { value.finalists = endpoints; try save() }
    func sample(_ result: ProbeResult) throws { value.partial = result; try save() }
    func finish(_ result: ProbeResult) throws { value.completed.append(result); value.partial = nil; try save() }
}
