import Foundation

/// A small public HTTPS request lets iOS present its regional WLAN/cellular permission UI.
/// It carries no registration data, creates no VPN, and never blocks app initialization.
@MainActor
final class NetworkAccessPrimer {
    private var started = false
    private var session: URLSession?
    func start() {
        guard !started else { return }
        started = true
        let options = URLSessionConfiguration.ephemeral
        options.waitsForConnectivity = true
        options.allowsCellularAccess = true
        options.timeoutIntervalForRequest = 15
        options.timeoutIntervalForResource = 60
        let session = URLSession(configuration: options)
        self.session = session
        var request = URLRequest(url: URL(string: WARPConfiguration.testURL)!)
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        Diagnostics.record("network access request started", process: "app")
        session.dataTask(with: request) { [weak self] _, response, error in
            if let error { Diagnostics.record("network access request: \(error.localizedDescription)", process: "app") }
            else { Diagnostics.record("network access response=\((response as? HTTPURLResponse)?.statusCode ?? 0)", process: "app") }
            Task { @MainActor [weak self] in
                self?.session?.finishTasksAndInvalidate(); self?.session = nil
            }
        }.resume()
    }
}
