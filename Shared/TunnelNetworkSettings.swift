import Foundation
import NetworkExtension

enum TunnelNetworkSettings {
    static func make(endpoint: WARPEndpoint, mtu: Int, dnsAddress: String, preferences: UserSettings = UserSettings(),
        systemDNS: [String] = []) throws -> NEPacketTunnelNetworkSettings {
        guard endpoint.isValid else { throw WARPError.message("无效的隧道端点。") }
        let settings = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: endpoint.host)
        settings.mtu = NSNumber(value: mtu)
        let v4 = NEIPv4Settings(addresses: ["198.18.0.1"], subnetMasks: ["255.255.255.252"])
        // Two half-routes cover the Internet without making this interface the DNS default.
        // iOS otherwise reports an unsatisfied path when a default tunnel has no DNS settings.
        v4.includedRoutes = preferences.doNotSetDNS
            ? [NEIPv4Route(destinationAddress: "0.0.0.0", subnetMask: "128.0.0.0"), NEIPv4Route(destinationAddress: "128.0.0.0", subnetMask: "128.0.0.0")]
            : [NEIPv4Route.default()]
        let v6 = NEIPv6Settings(addresses: ["fdfe:dcba:9876::1"], networkPrefixLengths: [126])
        v6.includedRoutes = preferences.doNotSetDNS
            ? [NEIPv6Route(destinationAddress: "::", networkPrefixLength: 1), NEIPv6Route(destinationAddress: "8000::", networkPrefixLength: 1)]
            : [NEIPv6Route.default()]
        // Binding a socket to the physical interface alone does not avoid iOS route recursion.
        // Exclude only the outer server, using the correct address family and host prefix.
        if endpoint.family == .ipv6 {
            v6.excludedRoutes = [NEIPv6Route(destinationAddress: endpoint.host, networkPrefixLength: 128)]
        } else {
            v4.excludedRoutes = [NEIPv4Route(destinationAddress: endpoint.host, subnetMask: "255.255.255.255")]
        }
        if preferences.doNotSetDNS {
            for server in Set(systemDNS) where server != endpoint.host {
                if IPAddressFamily.ipv4.contains(server) {
                    var routes = v4.excludedRoutes ?? []
                    routes.append(NEIPv4Route(destinationAddress: server, subnetMask: "255.255.255.255")); v4.excludedRoutes = routes
                } else if IPAddressFamily.ipv6.contains(server) {
                    var routes = v6.excludedRoutes ?? []
                    routes.append(NEIPv6Route(destinationAddress: server, networkPrefixLength: 128)); v6.excludedRoutes = routes
                }
            }
        }
        settings.ipv4Settings = v4
        settings.ipv6Settings = v6
        if !preferences.doNotSetDNS {
            let dns = NEDNSSettings(servers: [dnsAddress])
            dns.matchDomains = [""]
            dns.matchDomainsNoSearch = true
            settings.dnsSettings = dns
        }
        return settings
    }

    static func parseSystemDNS(_ lines: String) -> [String] {
        lines.split(whereSeparator: { $0.isWhitespace }).compactMap { item in
            let text = String(item)
            if IPAddressFamily.allCases.contains(where: { $0.contains(text) }) { return text }
            return WARPEndpoint.parse(text, kind: .wg)?.host
        }
    }
}
