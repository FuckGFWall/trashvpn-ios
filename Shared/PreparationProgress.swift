import Foundation

struct PreparationProgress: Codable, Equatable, Sendable {
    enum Stage: String, Codable, Sendable { case checking, credentials, registering, enrolling, validating, registered, candidates, screening, shortlist, retesting, downloading, ranking, saving, finalizing, ready, paused, failed }
    let stage: Stage
    var fraction: Double
    let title: LocalizedText
    let detail: LocalizedText
    var substep: Int? = nil
    var substepTotal: Int? = nil
    var substepLabel: String? = nil
    var steps: [Stage]? = nil
    static let registrationMilestone = 1.0 / 3.0
    static func plan(existing: WARPAccount?, download: Bool) -> [Stage] {
        var stages: [Stage] = [.checking]
        if existing?.isRegistered != true {
            stages += [.credentials]
            if existing?.id.isEmpty != false { stages.append(.registering) }
            stages += [.enrolling, .validating]
        }
        stages += [.registered, .candidates, .screening, .shortlist, .retesting]
        if download { stages.append(.downloading) }
        return stages + [.ranking, .saving, .finalizing]
    }
    var totalSteps: Int { (steps ?? Self.plan(existing: nil, download: true)).count }
    var overallStep: Int? { (steps ?? Self.plan(existing: nil, download: true)).firstIndex(of: stage).map { $0 + 1 } }
    var displayTitle: String {
        guard let overallStep else { return title.source }
        let prefix = "\(overallStep)/\(totalSteps) \(title)"
        guard let substep, let substepTotal, let substepLabel else { return prefix }
        return prefix + " · \(substep)/\(substepTotal) \(substepLabel)"
    }
    func localizedDisplayTitle(in language: AppLanguage) -> String {
        let title = title.localized(in: language)
        guard let overallStep else { return title }
        let prefix = "\(overallStep)/\(totalSteps) \(title)"
        guard let substep, let substepTotal, let substepLabel else { return prefix }
        return prefix + " · \(substep)/\(substepTotal) " + LocalizedText(substepLabel).localized(in: language)
    }
    static let initial = Self(stage: .checking, fraction: 0, title: "检查连接准备", detail: "检查注册身份和节点缓存")
    func stopped(failed: Bool, detail: LocalizedText) -> Self {
        Self(stage: failed ? .failed : .paused, fraction: fraction, title: failed ? "准备未完成" : "已暂停", detail: detail)
    }
}
