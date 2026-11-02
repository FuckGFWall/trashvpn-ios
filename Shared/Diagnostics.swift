import Foundation
import os

enum Diagnostics {
    private static let lock = NSLock()
    private static let logger = Logger(subsystem: "com.leo.TrashVPN", category: "WARP")

    static func reset(_ process: String) {
        lock.lock(); defer { lock.unlock() }
        guard let root = try? WARPConfiguration.container() else { return }
        try? FileManager.default.removeItem(at: root.appendingPathComponent("\(process).log"))
    }

    static func record(_ message: String, process: String) {
        // Never log configuration or key material.
        logger.notice("\(process, privacy: .public): \(message, privacy: .public)")
        lock.lock(); defer { lock.unlock() }
        guard let root = try? WARPConfiguration.container() else { return }
        let url = root.appendingPathComponent("\(process).log")
        let line = "\(ISO8601DateFormatter().string(from: Date())) \(message)\n"
        guard let data = line.data(using: .utf8) else { return }
        if FileManager.default.fileExists(atPath: url.path), let file = try? FileHandle(forWritingTo: url) {
            defer { try? file.close() }
            if (try? file.seekToEnd()) ?? 0 > 256_000 {
                try? file.truncate(atOffset: 0)
                try? file.seek(toOffset: 0)
            }
            try? file.write(contentsOf: data)
        } else {
            try? data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        }
    }

    static func read(_ process: String) -> String {
        guard let root = try? WARPConfiguration.container() else { return "" }
        return (try? String(contentsOf: root.appendingPathComponent("\(process).log"), encoding: .utf8)) ?? ""
    }
}
