import NetworkExtension
import SwiftUI

struct ConnectionPowerButton: View {
    let status: NEVPNStatus
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @State private var level: CGFloat = -0.12
    @State private var ringWarmth = 0.0
    @State private var waves = WaveParameters.random()
    @State private var moving = false
    @State private var settleTask: Task<Void, Never>?
    private let orange = Color(red: 1, green: 0.38, blue: 0.08)
    private var connected: Bool { status == .connected || status == .reasserting }

    var body: some View {
        ZStack {
            ZStack {
                Circle().stroke(Color.secondary.opacity(0.07), lineWidth: 18).opacity(1 - ringWarmth)
                Circle().stroke(orange.opacity(0.1), lineWidth: 18).opacity(ringWarmth)
            }.frame(width: 164, height: 164)
            ZStack {
                Circle().fill(Color(.systemGray3))
                TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !moving || reduceMotion || scenePhase != .active)) { timeline in
                    let time = timeline.date.timeIntervalSinceReferenceDate
                    ZStack {
                        WaterWave(level: level, amplitude: waves.amplitude * 0.7, frequency: waves.frequency * 0.85,
                            phase: time * waves.speed * 0.8 + waves.phase + 1.7)
                            .fill(orange.opacity(0.45))
                        WaterWave(level: level, amplitude: waves.amplitude, frequency: waves.frequency,
                            phase: time * waves.speed + waves.phase)
                            .fill(LinearGradient(colors: [Color(red: 1, green: 0.58, blue: 0.18), orange], startPoint: .topLeading, endPoint: .bottomTrailing))
                    }
                }.clipShape(Circle())
                Image(systemName: "power").font(.system(size: 55, weight: .light)).foregroundStyle(.white)
            }.frame(width: 140, height: 140)
                .shadow(color: orange.opacity(0.23 * ringWarmth), radius: 18, y: 9)
                .shadow(color: Color.black.opacity(0.07 * (1 - ringWarmth)), radius: 18, y: 9)
        }.frame(width: 182, height: 182).padding(.vertical, 4)
            .onAppear { update(status, initial: true) }
            .onChange(of: status) { status in update(status) }
            .onDisappear { settleTask?.cancel() }
    }

    private func update(_ status: NEVPNStatus, initial: Bool = false) {
        let connected = status == .connected || status == .reasserting
        settleTask?.cancel()
        if status == .connecting {
            waves = .random(); moving = true
            // Reveal the first wave promptly even when tunnel setup takes less than a second,
            // then rise slowly until the system confirms success or failure.
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.35)) { level = 0.12 }
            withAnimation(.easeOut(duration: 0.35)) { ringWarmth = 0.18 }
            settleTask = Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(350))
                guard !Task.isCancelled else { return }
                withAnimation(reduceMotion ? nil : .easeInOut(duration: 8)) { level = 0.82 }
                withAnimation(.easeInOut(duration: 8)) { ringWarmth = 0.82 }
            }
        } else {
            moving = !initial
            withAnimation(initial || reduceMotion ? nil : .easeInOut(duration: 0.75)) { level = connected ? 1.12 : -0.12 }
            // Fade both the pale ring and glow, starting as soon as connecting/disconnecting begins.
            withAnimation(initial ? nil : .easeInOut(duration: 0.75)) { ringWarmth = connected ? 1 : 0 }
            settleTask = Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(800))
                guard !Task.isCancelled else { return }
                moving = false
            }
        }
    }
}

private struct WaveParameters {
    let amplitude: CGFloat
    let frequency: Double
    let speed: Double
    let phase: Double
    static func random() -> Self {
        Self(amplitude: .random(in: 0.025...0.05), frequency: .random(in: 1.1...1.8),
            speed: .random(in: 1.8...3.2), phase: .random(in: 0...(2 * .pi)))
    }
}

private struct WaterWave: Shape {
    var level: CGFloat
    let amplitude: CGFloat
    let frequency: Double
    let phase: Double
    var animatableData: CGFloat {
        get { level }
        set { level = newValue }
    }
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let surface = rect.height * (1 - level)
        path.move(to: CGPoint(x: 0, y: rect.maxY))
        for x in stride(from: 0.0, through: Double(rect.width), by: 2) {
            let y = surface + rect.height * amplitude * sin(x / rect.width * 2 * .pi * frequency + phase)
            path.addLine(to: CGPoint(x: x, y: y))
        }
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}
