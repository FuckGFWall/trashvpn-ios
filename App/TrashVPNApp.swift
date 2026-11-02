import SwiftUI

@main
struct TrashVPNApp: App {
    @StateObject private var model = VPNModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            ContentView(model: model)
                .tint(Color(red: 1, green: 0.38, blue: 0.08))
                .preferredColorScheme(model.settings.theme.colorScheme)
                .task { await model.prepare() }
                .onChange(of: scenePhase) { _, phase in
                    if phase == .background { model.enteredBackground() }
                    if phase == .active { model.enteredForeground(); Task { await model.refreshDiagnostics() } }
                }
        }
    }
}
