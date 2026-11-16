import SwiftUI

struct PreparationProgressBar: View {
    let progress: PreparationProgress
    let running: Bool
    var language: AppLanguage = .system
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    private var complete: Bool { progress.stage == .ready }
    private var tint: Color { complete ? .green : Color(red: 1, green: 0.38, blue: 0.08) }
    private var animating: Bool { running && !complete && !reduceMotion && scenePhase == .active }

    var body: some View {
        VStack(spacing: 8) {
            GeometryReader { geometry in
                let width = geometry.size.width * min(1, max(0, progress.fraction))
                TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !animating)) { timeline in
                    let phase = timeline.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.6) / 1.6
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.secondary.opacity(0.13)).frame(height: 6)
                        Capsule().fill(tint).frame(width: width, height: 6)
                        if animating {
                            LinearGradient(colors: [.clear, .white.opacity(0.65), .clear], startPoint: .leading, endPoint: .trailing)
                                .frame(width: 72, height: 6)
                                .offset(x: (geometry.size.width + 72) * phase - 72)
                                .frame(width: geometry.size.width, alignment: .leading)
                                .mask(alignment: .leading) { Capsule().frame(width: width, height: 6) }
                        }
                        Circle().fill(progress.fraction >= PreparationProgress.registrationMilestone ? tint : Color(.systemGray4))
                            .overlay(Circle().stroke(Color(.secondarySystemGroupedBackground), lineWidth: 3))
                            .frame(width: 14, height: 14)
                            .offset(x: geometry.size.width * PreparationProgress.registrationMilestone - 7)
                    }.frame(height: 14)
                }
                .animation(reduceMotion ? nil : .easeOut(duration: 0.25), value: progress.fraction)
                .animation(reduceMotion ? nil : .easeInOut(duration: 0.3), value: complete)
            }.frame(height: 14)
            GeometryReader { geometry in
                HStack { Spacer(); Text(LocalizedText("就绪").localized(in: language)).foregroundStyle(complete ? .green : .secondary) }
                Text(LocalizedText("注册").localized(in: language)).foregroundStyle(progress.fraction >= PreparationProgress.registrationMilestone ? tint : .secondary)
                    .position(x: geometry.size.width * PreparationProgress.registrationMilestone, y: 7)
            }.font(.caption2).foregroundStyle(.secondary).frame(height: 14)
        }
        .environment(\.layoutDirection, .leftToRight)
        .accessibilityElement(children: .combine).accessibilityIdentifier("preparationProgress")
        .accessibilityValue("\(Int(progress.fraction * 100))%")
    }
}
