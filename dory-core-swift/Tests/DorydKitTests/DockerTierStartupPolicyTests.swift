@testable import DorydKit
import XCTest

final class DockerTierStartupPolicyTests: XCTestCase {
    func testPersistedRuntimeModeWinsOverStaleLaunchAgentHint() {
        XCTAssertTrue(DockerTierStartupPolicy.shouldAutostartDockerTier(
            environment: ["DORYD_AUTOSTART_DOCKER_TIER": "0"],
            persistedRuntimeMode: "always-on"
        ))
        XCTAssertFalse(DockerTierStartupPolicy.shouldAutostartDockerTier(
            environment: ["DORYD_AUTOSTART_DOCKER_TIER": "1"],
            persistedRuntimeMode: "manual"
        ))
    }

    func testExplicitForceAutostartCanOverrideForDevelopment() {
        XCTAssertTrue(DockerTierStartupPolicy.shouldAutostartDockerTier(
            environment: ["DORYD_FORCE_AUTOSTART_DOCKER_TIER": "yes"],
            persistedRuntimeMode: "manual"
        ))
    }

    func testManualAndAutoIdleArmSleepingByDefault() {
        XCTAssertFalse(DockerTierStartupPolicy.shouldAutostartDockerTier(
            environment: [:],
            persistedRuntimeMode: "manual"
        ))
        XCTAssertFalse(DockerTierStartupPolicy.shouldAutostartDockerTier(
            environment: [:],
            persistedRuntimeMode: "auto-idle"
        ))
        XCTAssertFalse(DockerTierStartupPolicy.shouldAutostartDockerTier(
            environment: [:],
            persistedRuntimeMode: "battery-saver"
        ))
    }
}
