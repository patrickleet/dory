import DoryCore
import Foundation

/// One validated dual-stack contract shared by gvproxy, the guest interface, Docker's bridge, and
/// Dory's direct-IP tunnel. Keeping these values in one plan prevents a typo from launching an
/// engine that advertises IPv6 but silently routes only one layer of the path.
public struct NativeIPv6NetworkPlan: Sendable, Equatable {
    public let containerSubnet: String
    public let virtualNetwork: String
    public let guestAddress: DirectIPv6Address
    public let hostGateway: DirectIPv6Address
    public let virtualPrefixLength: Int

    public init(
        containerSubnet: String,
        virtualNetwork: String,
        guestAddress: String,
        hostGateway: String
    ) throws {
        let containerRoute = try DirectIPv6Route(cidr: containerSubnet)
        let virtualRoute = try DirectIPv6Route(cidr: virtualNetwork)
        guard let guest = DirectIPv6Address(guestAddress),
              let host = DirectIPv6Address(hostGateway),
              virtualRoute.contains(guest),
              virtualRoute.contains(host),
              guest != host,
              !containerRoute.contains(virtualRoute.network),
              !virtualRoute.contains(containerRoute.network) else {
            throw DirectIPBridgeError.invalidIPv6(
                "container=\(containerSubnet), virtual=\(virtualNetwork), guest=\(guestAddress), host=\(hostGateway)"
            )
        }
        self.containerSubnet = containerSubnet
        self.virtualNetwork = virtualNetwork
        self.guestAddress = guest
        self.hostGateway = host
        self.virtualPrefixLength = virtualRoute.prefixLength
    }

    public init?(directIP: DirectIPBridgeConfiguration?) throws {
        guard let directIP else { return nil }
        let values = [
            directIP.ipv6SubnetCIDR,
            directIP.ipv6Gateway,
            directIP.ipv6VirtualNetworkCIDR,
            directIP.ipv6HostGateway,
        ]
        if values.allSatisfy({ $0 == nil }) { return nil }
        guard let containerSubnet = directIP.ipv6SubnetCIDR,
              let guestAddress = directIP.ipv6Gateway,
              let virtualNetwork = directIP.ipv6VirtualNetworkCIDR,
              let hostGateway = directIP.ipv6HostGateway else {
            throw DirectIPBridgeError.invalidIPv6(values.compactMap { $0 }.joined(separator: ","))
        }
        try self.init(
            containerSubnet: containerSubnet,
            virtualNetwork: virtualNetwork,
            guestAddress: guestAddress,
            hostGateway: hostGateway
        )
    }

    public var gvproxyYAML: String {
        """
        stack:
          ipv6Subnet: \(virtualNetwork)
          ipv6GatewayIP: \(hostGateway)
          nat:
            "192.168.127.254": "127.0.0.1"
            "\(hostGateway)": "::1"

        """
    }

    public var guestSetupCommands: [String] {
        [
            "ip -6 addr replace \(guestAddress)/\(virtualPrefixLength) dev eth0",
            "ip -6 route replace default via \(hostGateway) dev eth0",
            "sysctl -w net.ipv6.conf.all.forwarding=1 >/dev/null",
        ]
    }

    public var dockerDaemonArguments: String {
        "--ipv6=true --fixed-cidr-v6=\(containerSubnet) --ip6tables=true"
    }
}
