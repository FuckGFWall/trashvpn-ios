import Darwin
import Foundation

struct ProbeController: Sendable {
    let port: UInt16
    let secret: String
    var address: String { "127.0.0.1:\(port)" }
    static func allocate() throws -> Self {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw WARPError.message("无法创建本地测速接口。") }
        defer { close(fd) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &address) { value in
            value.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let queried = withUnsafeMutablePointer(to: &address) { value in
            value.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) }
        }
        guard bound == 0, queried == 0, address.sin_port != 0 else { throw WARPError.message("无法分配本地测速端口。") }
        return Self(port: UInt16(bigEndian: address.sin_port), secret: UUID().uuidString)
    }
    func url(endpoint: WARPEndpoint, timeout: Int) -> URL {
        var components = URLComponents(string: "http://\(address)")!
        components.path = "/proxies/\(endpoint.name)/delay"
        components.queryItems = [URLQueryItem(name: "url", value: WARPConfiguration.testURL),
            URLQueryItem(name: "timeout", value: String(timeout * 1000)), URLQueryItem(name: "expected", value: "200-299")]
        return components.url!
    }
}

struct ProbeProxy: Sendable {
    let port: UInt16
    let username: String
    let password: String
    static func allocate() throws -> Self {
        Self(port: try ProbeController.allocate().port, username: "probe-" + UUID().uuidString, password: UUID().uuidString)
    }
}
