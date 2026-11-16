import Foundation

enum VPNAuthorizationFlow {
    /// The system presents first-use VPN consent from saveToPreferences. Never start the
    /// tunnel until that operation and the subsequent preference reload both succeed.
    @MainActor
    static func start(save: () async throws -> Void, reload: () async throws -> Void, start: () throws -> Void) async throws {
        try Task.checkCancellation()
        try await save()
        try Task.checkCancellation()
        try await reload()
        try Task.checkCancellation()
        try start()
    }
}
