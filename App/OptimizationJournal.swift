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
    func screen(_ result: ProbeResult) throws { value.screening[result.endpoint.id] = result; try save() }
    func shortlist(_ endpoints: [WARPEndpoint]) throws { value.finalists = endpoints; try save() }
    func sample(_ result: ProbeResult) throws { value.partial = result; try save() }
    func finish(_ result: ProbeResult) throws { value.completed.append(result); value.partial = nil; try save() }
}
