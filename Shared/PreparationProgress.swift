import Foundation

struct PreparationProgress: Equatable, Sendable {
    enum Stage: String, Sendable { case checking, credentials, registering, enrolling, validating, registered, candidates, screening, shortlist, retesting, downloading, ranking, saving, ready, paused, failed }
    let stage: Stage
    let fraction: Double
    let title: String
    let detail: String
    static let registrationMilestone = 0.5
    static let initial = Self(stage: .checking, fraction: 0, title: "检查连接准备", detail: "检查注册身份和节点缓存")
    func stopped(failed: Bool, detail: String) -> Self {
        Self(stage: failed ? .failed : .paused, fraction: fraction, title: failed ? "准备未完成" : "已暂停", detail: detail)
    }
}
