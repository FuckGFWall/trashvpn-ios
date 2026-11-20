import Foundation
import NetworkExtension

@MainActor
enum VPNConnectionAwaiter {
    static func wait(timeout: TimeInterval = 30, status: () -> NEVPNStatus, refresh: () -> Void) async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        var started = false
        while true {
            try Task.checkCancellation(); refresh()
            let current = status()
            if current == .connected { return }
            if [.connecting, .reasserting].contains(current) { started = true }
            if started && [.disconnected, .invalid].contains(current) { throw WARPError.message("VPN 连接失败，测试未开始。") }
            guard ProcessInfo.processInfo.systemUptime < deadline else { throw WARPError.message("等待 VPN 连接超时。") }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
    }
}

@MainActor
enum ProviderMessageClient {
    typealias Transport = (Data, @escaping (Data?) -> Void) throws -> Void
    static func send(_ data: Data, timeout: TimeInterval = 20, using transport: Transport) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            let response = PendingProviderResponse(continuation)
            response.deadline = Task {
                do { try await Task.sleep(nanoseconds: UInt64(max(0, timeout) * 1_000_000_000)) } catch { return }
                response.finish(.failure(WARPError.message("隧道响应超时。")))
            }
            do {
                try transport(data) { data in
                    Task { @MainActor in
                        response.finish(data.map(Result.success) ?? .failure(WARPError.message("隧道未返回响应。")))
                    }
                }
            } catch { response.finish(.failure(error)) }
        }
    }
}

@MainActor
enum DisconnectedPreparation {
    static func run(disconnect: () -> Void, waitUntilDisconnected: () async throws -> Void, prepare: () -> Void) async throws {
        disconnect()
        try await waitUntilDisconnected()
        prepare()
    }
}

@MainActor
private final class PendingProviderResponse {
    private var continuation: CheckedContinuation<Data, Error>?
    var deadline: Task<Void, Never>?
    init(_ continuation: CheckedContinuation<Data, Error>) { self.continuation = continuation }
    func finish(_ result: Result<Data, Error>) {
        guard let continuation else { return }
        self.continuation = nil
        deadline?.cancel(); deadline = nil
        continuation.resume(with: result)
    }
}
