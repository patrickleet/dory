@testable import DoryCore
import XCTest

final class DoryEngineShutdownTimingTests: XCTestCase {
    func testShutdownDeadlinesCannotCutOffTheEarlierSafetyStage() {
        XCTAssertGreaterThan(
            DoryEngineShutdownTiming.helperWatchdogSeconds,
            DoryEngineShutdownTiming.dockerdGraceSeconds
        )
        XCTAssertGreaterThan(
            DoryEngineShutdownTiming.hostTerminationSeconds,
            DoryEngineShutdownTiming.helperWatchdogSeconds
        )
        XCTAssertGreaterThanOrEqual(DoryEngineShutdownTiming.dockerdPollAttempts, 1)
        XCTAssertEqual(
            Double(DoryEngineShutdownTiming.dockerdPollAttempts)
                * DoryEngineShutdownTiming.pollIntervalSeconds,
            DoryEngineShutdownTiming.dockerdGraceSeconds,
            accuracy: 0.001
        )
    }
}
