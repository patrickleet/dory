import DoryCore
@testable import DorydKit
import XCTest

final class PrivilegedPortMappingTests: XCTestCase {
    func testMapsLowPublishedPortsToDeterministicHighPorts() {
        XCTAssertEqual(PrivilegedPortMapping.targetPort(forListenPort: 25), 60_025)
        XCTAssertEqual(PrivilegedPortMapping.targetPort(forListenPort: 1023), 61_023)
        XCTAssertNil(PrivilegedPortMapping.targetPort(forListenPort: 0))
        XCTAssertNil(PrivilegedPortMapping.targetPort(forListenPort: 1024))
    }

    func testBuildsDirectForwardsOnlyForNonProxyLowTCPPorts() {
        let forwards = PrivilegedPortMapping.forwards(from: [
            DoryListenPort(protocol: "tcp", port: 25),
            DoryListenPort(protocol: "tcp6", port: 110),
            DoryListenPort(protocol: "tcp", port: 80),
            DoryListenPort(protocol: "tcp", port: 443),
            DoryListenPort(protocol: "udp", port: 53),
            DoryListenPort(protocol: "tcp", port: 8080),
        ])

        XCTAssertEqual(forwards, [
            PrivilegedTCPForward(listenPort: 25, targetPort: 60_025),
            PrivilegedTCPForward(listenPort: 110, targetPort: 60_110),
        ])
    }
}
