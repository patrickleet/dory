@testable import DorydKit
import XCTest

final class VmmDockerProcessTests: XCTestCase {
    func testImmediateHelperExitUnblocksHandoffWaitAndNotifiesSupervisor() throws {
        let base = "/tmp/dory-vmm-process-exit-\(getpid())-\(UInt32.random(in: 0..<UInt32.max))"
        try FileManager.default.createDirectory(atPath: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: base) }

        let helper = base + "/exit.sh"
        try "#!/bin/sh\nexit 17\n".write(toFile: helper, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: helper)
        let callback = expectation(description: "unexpected exit callback")
        let process = VmmDockerProcess(
            configuration: VmmDockerProcessConfiguration(
                executablePath: helper,
                arguments: [],
                stateDirectory: base + "/state",
                handoffSocketPath: base + "/state/handoff.sock",
                readyTimeoutSeconds: 10
            ),
            unexpectedTerminationHandler: { termination in
                XCTAssertEqual(termination.status, 17)
                callback.fulfill()
            }
        )

        let startedAt = Date()
        XCTAssertThrowsError(try process.start()) { error in
            XCTAssertTrue("\(error)".contains("did not become ready"), "\(error)")
        }

        wait(for: [callback], timeout: 1)
        XCTAssertLessThan(Date().timeIntervalSince(startedAt), 1)
        XCTAssertFalse(process.isRunning)
        XCTAssertNil(process.pid)
        XCTAssertFalse(FileManager.default.fileExists(atPath: base + "/state/handoff.sock"))
    }

    func testStopCancelsBlockedHandoffAndReapsHelper() throws {
        let base = "/tmp/dory-vmm-process-cancel-\(getpid())-\(UInt32.random(in: 0..<UInt32.max))"
        try FileManager.default.createDirectory(atPath: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: base) }

        let handoffPath = base + "/state/handoff.sock"
        let process = VmmDockerProcess(
            configuration: VmmDockerProcessConfiguration(
                executablePath: "/bin/sleep",
                arguments: ["30"],
                stateDirectory: base + "/state",
                handoffSocketPath: handoffPath,
                readyTimeoutSeconds: 30
            )
        )
        let startError = LockedVmmErrorBox()
        let startFinished = DispatchSemaphore(value: 0)

        DispatchQueue.global().async {
            do {
                try process.start()
            } catch {
                startError.set(error)
            }
            startFinished.signal()
        }

        let deadline = Date().addingTimeInterval(2)
        while process.pid == nil, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.005)
        }
        let helperPID = try XCTUnwrap(process.pid)

        let stoppedAt = Date()
        process.stop()

        XCTAssertEqual(startFinished.wait(timeout: .now() + 1), .success)
        XCTAssertLessThan(Date().timeIntervalSince(stoppedAt), 1)
        XCTAssertTrue(startError.value.map { "\($0)".contains("start was cancelled") } ?? false)
        XCTAssertFalse(process.isRunning)
        XCTAssertNil(process.pid)
        XCTAssertFalse(FileManager.default.fileExists(atPath: handoffPath))
        XCTAssertEqual(kill(helperPID, 0), -1)
        XCTAssertEqual(errno, ESRCH)
    }

    func testStopBeforeFirstStartPreventsLateSpawn() throws {
        let base = "/tmp/dory-vmm-process-prestart-cancel-\(getpid())-\(UInt32.random(in: 0..<UInt32.max))"
        try FileManager.default.createDirectory(atPath: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: base) }

        let handoffPath = base + "/state/handoff.sock"
        let process = VmmDockerProcess(
            configuration: VmmDockerProcessConfiguration(
                executablePath: "/bin/sleep",
                arguments: ["30"],
                stateDirectory: base + "/state",
                handoffSocketPath: handoffPath,
                readyTimeoutSeconds: 30
            )
        )

        process.stop()

        XCTAssertThrowsError(try process.start()) { error in
            XCTAssertTrue("\(error)".contains("start was cancelled"), "\(error)")
        }
        XCTAssertFalse(process.isRunning)
        XCTAssertNil(process.pid)
        XCTAssertFalse(FileManager.default.fileExists(atPath: handoffPath))
    }
}

private final class LockedVmmErrorBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Error?

    var value: Error? {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }

    func set(_ error: Error) {
        lock.lock()
        stored = error
        lock.unlock()
    }
}
