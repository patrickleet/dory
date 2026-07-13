import Darwin
import Foundation
import XCTest
@testable import DoryCore

final class LegacyDockerDataDiskTests: XCTestCase {
    func testCreatesSparseBlankDiskWhenLegacyStoreIsAbsent() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let destination = root + "/state/docker-data.ext4"

        XCTAssertEqual(
            try LegacyDockerDataDisk.prepare(
                destination: destination,
                legacySource: root + "/missing.img",
                blankSize: 8 * 1024 * 1024
            ),
            .createdBlank
        )
        let size = try FileManager.default.attributesOfItem(atPath: destination)[.size] as? NSNumber
        XCTAssertEqual(size?.int64Value, 8 * 1024 * 1024)
        XCTAssertEqual(
            try LegacyDockerDataDisk.prepare(
                destination: destination,
                legacySource: root + "/missing.img",
                blankSize: 8 * 1024 * 1024
            ),
            .alreadyPresent
        )
    }

    func testAdoptsCloneOfValidLegacyExt4WithoutChangingSource() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let source = root + "/legacy/volume.img"
        let destination = root + "/state/docker-data.ext4"
        try FileManager.default.createDirectory(
            at: URL(fileURLWithPath: source).deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        // The adoption gate requires both ext4 magic and internally consistent filesystem
        // geometry; a magic-only fixture would correctly be treated as possible corruption.
        var bytes = ext4Fixture(fileBytes: 4096, declaredBlocks: 4, logBlockSize: 0)
        bytes.replaceSubrange(2048..<2055, with: Data("payload".utf8))
        try bytes.write(to: URL(fileURLWithPath: source))

        XCTAssertEqual(
            try LegacyDockerDataDisk.prepare(destination: destination, legacySource: source, blankSize: 4096),
            .adoptedLegacy(source: source)
        )
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: destination)), bytes)
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: source)), bytes)

        var destinationBytes = try Data(contentsOf: URL(fileURLWithPath: destination))
        destinationBytes[2048] = 0x58
        try destinationBytes.write(to: URL(fileURLWithPath: destination))
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: source)), bytes)
    }

    func testAdoptsFirstExistingSourceFromOrderedLegacyDriveCandidates() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let currentDory = root + "/missing-current.ext4"
        let appleContainer = root + "/apple-container.ext4"
        let destination = root + "/drive/engine/docker-data.ext4"
        let bytes = ext4Fixture(fileBytes: 4096, declaredBlocks: 4, logBlockSize: 0)
        try bytes.write(to: URL(fileURLWithPath: appleContainer))

        XCTAssertEqual(
            try LegacyDockerDataDisk.prepare(
                destination: destination,
                legacySources: [currentDory, appleContainer],
                blankSize: 4096
            ),
            .adoptedLegacy(source: appleContainer)
        )
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: destination)), bytes)
        XCTAssertEqual(
            try String(contentsOfFile: destination + ".migrated-from-legacy", encoding: .utf8),
            appleContainer + "\n"
        )
    }

    func testInvalidNewerLegacyDriveFailsClosedInsteadOfFallingBack() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let currentDory = root + "/current.ext4"
        let appleContainer = root + "/apple-container.ext4"
        let destination = root + "/drive/engine/docker-data.ext4"
        try Data(repeating: 0xA5, count: 4096).write(to: URL(fileURLWithPath: currentDory))
        try ext4Fixture(fileBytes: 4096, declaredBlocks: 4, logBlockSize: 0)
            .write(to: URL(fileURLWithPath: appleContainer))

        XCTAssertThrowsError(try LegacyDockerDataDisk.prepare(
            destination: destination,
            legacySources: [currentDory, appleContainer],
            blankSize: 4096
        )) { error in
            XCTAssertEqual(error as? DockerDataDiskError, .invalidLegacyDisk(currentDory))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination))
    }

    func testRefusesInvalidLegacyDiskInsteadOfBootingBlank() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let source = root + "/legacy.img"
        let destination = root + "/docker-data.ext4"
        try Data(repeating: 0, count: 4096).write(to: URL(fileURLWithPath: source))

        XCTAssertThrowsError(try LegacyDockerDataDisk.prepare(destination: destination, legacySource: source))
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination))
    }

    func testRefusesAllocatedExistingNonExt4DiskInsteadOfFormattingIt() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let destination = root + "/docker-data.ext4"
        let original = Data(repeating: 0xA5, count: 4096)
        try original.write(to: URL(fileURLWithPath: destination))

        XCTAssertThrowsError(
            try LegacyDockerDataDisk.prepare(
                destination: destination,
                legacySource: root + "/missing.img",
                blankSize: 8 * 1024 * 1024
            )
        ) { error in
            XCTAssertEqual(
                error as? DockerDataDiskError,
                .invalidExistingDisk(destination)
            )
        }
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: destination)), original)
    }

    func testAllowsExistingUnallocatedSparseBlankToReachFirstBootFormatting() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let destination = root + "/docker-data.ext4"
        FileManager.default.createFile(atPath: destination, contents: nil)
        let descriptor = open(destination, O_RDWR | O_CLOEXEC)
        XCTAssertGreaterThanOrEqual(descriptor, 0)
        XCTAssertEqual(ftruncate(descriptor, 8 * 1024 * 1024), 0)
        close(descriptor)

        XCTAssertEqual(
            try LegacyDockerDataDisk.prepare(
                destination: destination,
                legacySource: root + "/missing.img",
                blankSize: 16 * 1024 * 1024
            ),
            .alreadyPresent
        )
        let size = try FileManager.default.attributesOfItem(atPath: destination)[.size] as? NSNumber
        XCTAssertEqual(size?.int64Value, 16 * 1024 * 1024)
    }

    func testRefusesExistingExt4MagicWithInvalidGeometryWithoutGrowingIt() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let destination = root + "/docker-data.ext4"
        let invalid = ext4Fixture(fileBytes: 4096, declaredBlocks: 0, logBlockSize: 0)
        try invalid.write(to: URL(fileURLWithPath: destination))

        XCTAssertThrowsError(
            try LegacyDockerDataDisk.prepare(
                destination: destination,
                legacySource: root + "/missing.img",
                blankSize: 16 * 1024 * 1024
            )
        ) { error in
            XCTAssertEqual(error as? DockerDataDiskError, .invalidExistingDisk(destination))
        }
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: destination)), invalid)
    }

    func testRefusesLegacyExt4MagicWithInvalidGeometryWithoutCloningIt() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let source = root + "/legacy.ext4"
        let destination = root + "/docker-data.ext4"
        try ext4Fixture(fileBytes: 4096, declaredBlocks: 0, logBlockSize: 0)
            .write(to: URL(fileURLWithPath: source))

        XCTAssertThrowsError(
            try LegacyDockerDataDisk.prepare(destination: destination, legacySource: source)
        ) { error in
            XCTAssertEqual(error as? DockerDataDiskError, .invalidLegacyDisk(source))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination))
    }

    func testRejectsExistingSparseDiskTruncatedBelowExt4DeclaredLength() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let destination = root + "/docker-data.ext4"
        try ext4Fixture(fileBytes: 4 * 1024 * 1024, declaredBlocks: 4096, logBlockSize: 1)
            .write(to: URL(fileURLWithPath: destination))

        XCTAssertEqual(try LegacyDockerDataDisk.expectedExt4ImageBytes(at: destination), 8 * 1024 * 1024)
        XCTAssertThrowsError(
            try LegacyDockerDataDisk.prepare(destination: destination, legacySource: root + "/missing.img")
        ) { error in
            XCTAssertEqual(
                error as? DockerDataDiskError,
                .truncatedDisk(
                    path: destination,
                    actualBytes: 4 * 1024 * 1024,
                    expectedBytes: 8 * 1024 * 1024
                )
            )
        }
    }

    func testAcceptsSparseDiskAtExt4DeclaredLength() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let destination = root + "/docker-data.ext4"
        try ext4Fixture(fileBytes: 8 * 1024 * 1024, declaredBlocks: 4096, logBlockSize: 1)
            .write(to: URL(fileURLWithPath: destination))

        XCTAssertEqual(
            try LegacyDockerDataDisk.prepare(
                destination: destination,
                legacySource: root + "/missing.img",
                blankSize: 8 * 1024 * 1024
            ),
            .alreadyPresent
        )
    }

    func testGrowsExistingValidDiskSparselyToRequestedLogicalCapacity() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let destination = root + "/docker-data.ext4"
        try ext4Fixture(fileBytes: 8 * 1024 * 1024, declaredBlocks: 4096, logBlockSize: 1)
            .write(to: URL(fileURLWithPath: destination))

        XCTAssertEqual(
            try LegacyDockerDataDisk.prepare(
                destination: destination,
                legacySource: root + "/missing.img",
                blankSize: 32 * 1024 * 1024
            ),
            .alreadyPresent
        )
        let attributes = try FileManager.default.attributesOfItem(atPath: destination)
        XCTAssertEqual((attributes[.size] as? NSNumber)?.int64Value, 32 * 1024 * 1024)
        XCTAssertEqual(try LegacyDockerDataDisk.expectedExt4ImageBytes(at: destination), 8 * 1024 * 1024)
    }

    func testProductionBlankDiskUsesLargeSparseLogicalCapacity() {
        XCTAssertEqual(LegacyDockerDataDisk.blankDiskBytes, 128 * 1024 * 1024 * 1024)
    }

    func testRejectsTruncatedLegacySourceBeforeCloning() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let source = root + "/legacy.ext4"
        let destination = root + "/docker-data.ext4"
        try ext4Fixture(fileBytes: 2 * 1024 * 1024, declaredBlocks: 4096, logBlockSize: 0)
            .write(to: URL(fileURLWithPath: source))

        XCTAssertThrowsError(try LegacyDockerDataDisk.prepare(destination: destination, legacySource: source))
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination))
    }

    private func ext4Fixture(fileBytes: Int, declaredBlocks: UInt32, logBlockSize: UInt32) -> Data {
        var bytes = Data(repeating: 0, count: fileBytes)
        bytes[1024 + 0x38] = 0x53
        bytes[1024 + 0x39] = 0xEF
        writeLittleEndian(declaredBlocks, into: &bytes, at: 1024 + 0x04)
        writeLittleEndian(logBlockSize, into: &bytes, at: 1024 + 0x18)
        return bytes
    }

    private func writeLittleEndian(_ value: UInt32, into data: inout Data, at offset: Int) {
        data[offset] = UInt8(truncatingIfNeeded: value)
        data[offset + 1] = UInt8(truncatingIfNeeded: value >> 8)
        data[offset + 2] = UInt8(truncatingIfNeeded: value >> 16)
        data[offset + 3] = UInt8(truncatingIfNeeded: value >> 24)
    }

    private func temporaryRoot() -> String {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("dory-legacy-data-\(UUID().uuidString)").path
        try? FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        return path
    }
}
