import DoryHV
import Testing

struct NativeIPv6NetworkPlanTests {
    @Test func producesOneConsistentDualStackContract() throws {
        let plan = try NativeIPv6NetworkPlan(
            containerSubnet: "fd7d:6f72:7901::/64",
            virtualNetwork: "fd7d:6f72:7900::/64",
            guestAddress: "fd7d:6f72:7900::2",
            hostGateway: "fd7d:6f72:7900::1"
        )

        #expect(plan.gvproxyYAML.contains("ipv6Subnet: fd7d:6f72:7900::/64"))
        #expect(plan.gvproxyYAML.contains("ipv6GatewayIP: fd7d:6f72:7900::1"))
        #expect(plan.gvproxyYAML.contains("\"fd7d:6f72:7900::1\": \"::1\""))
        #expect(plan.guestSetupCommands.contains("ip -6 addr replace fd7d:6f72:7900::2/64 dev eth0"))
        #expect(plan.guestSetupCommands.contains("ip -6 route replace default via fd7d:6f72:7900::1 dev eth0"))
        #expect(plan.dockerDaemonArguments == "--ipv6=true --fixed-cidr-v6=fd7d:6f72:7901::/64 --ip6tables=true")
    }

    @Test func rejectsIncompleteOverlappingAndDuplicateAddressContracts() throws {
        #expect(throws: DirectIPBridgeError.self) {
            _ = try NativeIPv6NetworkPlan(
                containerSubnet: "fd7d:6f72:7900::/80",
                virtualNetwork: "fd7d:6f72:7900::/64",
                guestAddress: "fd7d:6f72:7900::2",
                hostGateway: "fd7d:6f72:7900::1"
            )
        }
        #expect(throws: DirectIPBridgeError.self) {
            _ = try NativeIPv6NetworkPlan(
                containerSubnet: "fd7d:6f72:7901::/64",
                virtualNetwork: "fd7d:6f72:7900::/64",
                guestAddress: "fd7d:6f72:7900::1",
                hostGateway: "fd7d:6f72:7900::1"
            )
        }
        let incomplete = DirectIPBridgeConfiguration(
            subnetCIDR: "192.168.215.0/24",
            gateway: "192.168.127.2",
            ipv6SubnetCIDR: "fd7d:6f72:7901::/64",
            gvproxySocketPath: "/tmp/net.sock",
            localSocketPath: "/tmp/direct.sock"
        )
        #expect(throws: DirectIPBridgeError.self) {
            _ = try NativeIPv6NetworkPlan(directIP: incomplete)
        }
    }
}
