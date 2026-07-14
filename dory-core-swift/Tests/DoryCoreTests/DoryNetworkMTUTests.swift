import DoryCore
import XCTest

final class DoryNetworkMTUTests: XCTestCase {
    func testDefaultsToVPNAndIPv6SafeMinimum() {
        XCTAssertEqual(DoryNetworkMTU.resolved(environment: [:]), 1_280)
        XCTAssertEqual(DoryNetworkMTU.resolved(environment: [DoryNetworkMTU.environmentKey: ""]), 1_280)
    }

    func testAcceptsOnlyBoundedExplicitOverrides() {
        XCTAssertEqual(DoryNetworkMTU.resolved(environment: [DoryNetworkMTU.environmentKey: "1500"]), 1_500)
        XCTAssertEqual(DoryNetworkMTU.resolved(environment: [DoryNetworkMTU.environmentKey: "9000"]), 9_000)
        XCTAssertEqual(DoryNetworkMTU.resolved(environment: [DoryNetworkMTU.environmentKey: "1279"]), 1_280)
        XCTAssertEqual(DoryNetworkMTU.resolved(environment: [DoryNetworkMTU.environmentKey: "9001"]), 1_280)
        XCTAssertEqual(DoryNetworkMTU.resolved(environment: [DoryNetworkMTU.environmentKey: "invalid"]), 1_280)
    }
}
