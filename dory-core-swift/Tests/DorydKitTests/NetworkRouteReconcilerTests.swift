@testable import DorydKit
import XCTest

final class NetworkRouteReconcilerTests: XCTestCase {
    func testBuildsContainerRoutesFromRunningPublishedTCPPorts() throws {
        let routes = NetworkRouteReconciler.routes(
            containers: .ok(try containers("""
            [
              {
                "Id": "abc",
                "Names": ["/web", "/project_web_1"],
                "State": "running",
                "Ports": [{"PublicPort": 8080, "Type": "tcp"}],
                "Labels": {}
              },
              {
                "Id": "def",
                "Names": ["/db"],
                "State": "exited",
                "Ports": [{"PublicPort": 5432, "Type": "tcp"}],
                "Labels": {}
              }
            ]
            """)),
            machines: [],
            suffix: "Dory.Local."
        )

        XCTAssertEqual(routes, [
            DomainRoute(hostname: "project_web_1.dory.local", address: "127.0.0.1", port: 8080),
            DomainRoute(hostname: "web.dory.local", address: "127.0.0.1", port: 8080),
        ])
    }

    func testLowContainerPortsUsePrivilegedBackendAndLoopbackHosts() throws {
        let routes = NetworkRouteReconciler.routes(
            containers: .ok(try containers("""
            [
              {
                "Id": "abc",
                "Names": ["/web"],
                "State": "running",
                "Ports": [
                  {"PublicPort": 80, "Type": "tcp"},
                  {"PublicPort": 53, "Type": "udp"}
                ],
                "Labels": {}
              }
            ]
            """)),
            machines: [],
            suffix: "dory.local"
        )

        XCTAssertEqual(routes, [
            DomainRoute(hostname: "127.0.0.1", address: "127.0.0.1", port: 60_080),
            DomainRoute(hostname: "localhost", address: "127.0.0.1", port: 60_080),
            DomainRoute(hostname: "web.dory.local", address: "127.0.0.1", port: 60_080),
        ])
    }

    func testBuildsMachineRoutesOnlyForRunningIPv4Addresses() {
        let routes = NetworkRouteReconciler.routes(
            containers: .ok([]),
            machines: [
                DoryMachineStatus(id: "dev", state: .running, address: "192.168.64.10"),
                DoryMachineStatus(id: "friendly", state: .running, address: "friendly.dory.local"),
                DoryMachineStatus(id: "stopped", state: .stopped, address: "192.168.64.11"),
            ],
            suffix: "dory.local"
        )

        XCTAssertEqual(routes, [
            DomainRoute(hostname: "dev.dory.local", address: "192.168.64.10", port: 80),
        ])
    }

    func testMachineRoutesOverrideCollidingContainerNames() throws {
        let routes = NetworkRouteReconciler.routes(
            containers: .ok(try containers("""
            [
              {
                "Id": "abc",
                "Names": ["/dev"],
                "State": "running",
                "Ports": [{"PublicPort": 8080, "Type": "tcp"}],
                "Labels": {}
              }
            ]
            """)),
            machines: [
                DoryMachineStatus(id: "dev", state: .running, address: "192.168.64.10"),
            ],
            suffix: "dory.local"
        )

        XCTAssertEqual(routes, [
            DomainRoute(hostname: "dev.dory.local", address: "192.168.64.10", port: 80),
        ])
    }

    func testUnavailableContainersStillPublishMachineRoutes() {
        let routes = NetworkRouteReconciler.routes(
            containers: .unavailable("engine sleeping"),
            machines: [
                DoryMachineStatus(id: "dev", state: .running, address: "192.168.64.10"),
            ],
            suffix: "dory.local"
        )

        XCTAssertEqual(routes, [
            DomainRoute(hostname: "dev.dory.local", address: "192.168.64.10", port: 80),
        ])
    }

    private func containers(_ json: String) throws -> [DockerContainerSummary] {
        try JSONDecoder().decode([DockerContainerSummary].self, from: Data(json.utf8))
    }
}
