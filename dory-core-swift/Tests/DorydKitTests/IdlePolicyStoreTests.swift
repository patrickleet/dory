@testable import DorydKit
import XCTest

final class IdlePolicyStoreTests: XCTestCase {
    func testCorruptConfigIsPreservedAndNotSilentlyClobbered() throws {
        let directory = NSTemporaryDirectory() + "dory-idle-\(getpid())-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: directory) }
        let configPath = directory + "/config.json"
        let garbage = "{ this is not valid json "
        try garbage.write(toFile: configPath, atomically: true, encoding: .utf8)

        let store = IdlePolicyStore(environment: ["DORY_CONFIG": configPath])
        _ = store.currentPolicy()

        let backupPath = configPath + ".corrupt"
        XCTAssertTrue(FileManager.default.fileExists(atPath: backupPath))
        XCTAssertEqual(try String(contentsOfFile: backupPath, encoding: .utf8), garbage)
        XCTAssertEqual(try String(contentsOfFile: configPath, encoding: .utf8), garbage)
    }

    func testAbsentConfigReturnsDefaultsWithoutBackup() {
        let directory = NSTemporaryDirectory() + "dory-idle-\(getpid())-\(UUID().uuidString)"
        let configPath = directory + "/config.json"
        let store = IdlePolicyStore(environment: ["DORY_CONFIG": configPath])

        let policy = store.currentPolicy()

        XCTAssertEqual(policy.sleepAfterMinutes, 15)
        XCTAssertEqual(store.currentRuntimeMode(), "always-on")
        XCTAssertFalse(store.schedulerConfiguration(base: IdleSleepConfiguration()).enabled)
        XCTAssertFalse(FileManager.default.fileExists(atPath: configPath + ".corrupt"))
    }

    func testManagedEngineSleepFollowsRuntimeMode() throws {
        let directory = NSTemporaryDirectory() + "dory-idle-\(getpid())-\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(atPath: directory) }
        let configPath = directory + "/config.json"
        let store = IdlePolicyStore(environment: ["DORY_CONFIG": configPath])

        XCTAssertFalse(store.managedEngineSleepEnabled())

        try store.setRuntimeMode("auto-idle")
        XCTAssertTrue(store.managedEngineSleepEnabled())

        try store.setRuntimeMode("battery-saver")
        XCTAssertTrue(store.managedEngineSleepEnabled())

        try store.setRuntimeMode("manual")
        XCTAssertFalse(store.managedEngineSleepEnabled())
    }
}
