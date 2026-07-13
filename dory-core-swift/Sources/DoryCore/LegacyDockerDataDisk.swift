import Darwin
import Foundation

public enum DockerDataDiskPreparation: Sendable, Equatable {
    case alreadyPresent
    case adoptedLegacy(source: String)
    case createdBlank
}

public enum DockerDataDiskError: Error, Sendable, Equatable, CustomStringConvertible {
    case invalidLegacyDisk(String)
    case invalidExistingDisk(String)
    case truncatedDisk(path: String, actualBytes: Int64, expectedBytes: Int64)
    case syscall(String, Int32)
    case filesystem(String)

    public var description: String {
        switch self {
        case let .invalidLegacyDisk(path):
            "legacy Docker data disk is not a valid ext4 image: \(path)"
        case let .invalidExistingDisk(path):
            "existing Docker data disk is neither ext4 nor an unallocated sparse blank: \(path); refusing to format possible user data"
        case let .truncatedDisk(path, actualBytes, expectedBytes):
            "Docker data disk appears truncated: \(path) is \(actualBytes) bytes, but its ext4 superblock requires at least \(expectedBytes) bytes; restore or repair the sparse image before retrying"
        case let .syscall(operation, code):
            "\(operation): \(String(cString: strerror(code)))"
        case let .filesystem(message):
            message
        }
    }
}

/// Preserves the v0.2 Apple-container Docker store during the v0.3 engine cutover. Both engines
/// mount an ext4 filesystem at `/var/lib/docker`, so an APFS clone retains image, container,
/// network, and volume IDs without exporting and rebuilding them. The source is never moved,
/// modified, or deleted: rollback continues to use the original disk.
public enum LegacyDockerDataDisk {
    /// Logical capacity only: APFS keeps the backing file sparse and allocates physical blocks as
    /// Docker writes them. 128 GiB avoids a hidden 16 GiB ceiling during engine migration without
    /// reserving 128 GiB on the Mac.
    public static let blankDiskBytes: Int64 = 128 * 1024 * 1024 * 1024

    public static func defaultSource(home: String = NSHomeDirectory()) -> String {
        home + "/Library/Application Support/com.apple.container/volumes/dory-engine-data/volume.img"
    }

    @discardableResult
    public static func prepare(
        destination: String,
        legacySource: String = defaultSource(),
        legacySources: [String]? = nil,
        blankSize: Int64 = blankDiskBytes,
        fileManager: FileManager = .default
    ) throws -> DockerDataDiskPreparation {
        if fileManager.fileExists(atPath: destination) {
            if try isExt4Image(at: destination) {
                guard try expectedExt4ImageBytes(at: destination) != nil else {
                    throw DockerDataDiskError.invalidExistingDisk(destination)
                }
                try rejectTruncatedExt4Image(at: destination)
            } else if try !isUnallocatedSparseBlank(at: destination) {
                throw DockerDataDiskError.invalidExistingDisk(destination)
            }
            try growSparseFileIfNeeded(destination, minimumBytes: blankSize)
            return .alreadyPresent
        }
        try fileManager.createDirectory(
            at: URL(fileURLWithPath: destination).deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let partial = destination + ".partial"
        try? fileManager.removeItem(atPath: partial)

        let sources = legacySources ?? [legacySource]
        if let source = sources.first(where: { fileManager.fileExists(atPath: $0) }) {
            guard try isExt4Image(at: source),
                  try expectedExt4ImageBytes(at: source) != nil else {
                throw DockerDataDiskError.invalidLegacyDisk(source)
            }
            try rejectTruncatedExt4Image(at: source)
            guard clonefile(source, partial, 0) == 0 else {
                throw DockerDataDiskError.syscall("clone legacy Docker data disk", errno)
            }
            do {
                try growSparseFileIfNeeded(partial, minimumBytes: blankSize)
                try sync(path: partial)
                try fileManager.moveItem(atPath: partial, toPath: destination)
                let marker = destination + ".migrated-from-legacy"
                try? (source + "\n").write(toFile: marker, atomically: true, encoding: .utf8)
                return .adoptedLegacy(source: source)
            } catch {
                try? fileManager.removeItem(atPath: partial)
                throw error
            }
        }

        let descriptor = open(partial, O_CREAT | O_EXCL | O_RDWR | O_CLOEXEC, S_IRUSR | S_IWUSR | S_IRGRP | S_IROTH)
        guard descriptor >= 0 else { throw DockerDataDiskError.syscall("create Docker data disk", errno) }
        var failure: DockerDataDiskError?
        if ftruncate(descriptor, blankSize) != 0 {
            failure = .syscall("size Docker data disk", errno)
        } else if fsync(descriptor) != 0 {
            failure = .syscall("sync Docker data disk", errno)
        }
        close(descriptor)
        if let failure {
            try? fileManager.removeItem(atPath: partial)
            throw failure
        }
        do {
            try fileManager.moveItem(atPath: partial, toPath: destination)
            return .createdBlank
        } catch {
            try? fileManager.removeItem(atPath: partial)
            throw DockerDataDiskError.filesystem("publish Docker data disk: \(error)")
        }
    }

    public static func isExt4Image(at path: String) throws -> Bool {
        let descriptor = open(path, O_RDONLY | O_CLOEXEC)
        guard descriptor >= 0 else { throw DockerDataDiskError.syscall("open legacy Docker data disk", errno) }
        defer { close(descriptor) }
        // EXT4_SUPER_MAGIC is the little-endian 16-bit value at offset 0x38 in the superblock,
        // whose base is byte 1024.
        var magic = [UInt8](repeating: 0, count: 2)
        let count = magic.withUnsafeMutableBytes {
            pread(descriptor, $0.baseAddress, $0.count, off_t(1024 + 0x38))
        }
        guard count == magic.count else { return false }
        return magic[0] == 0x53 && magic[1] == 0xEF
    }

    /// Returns the byte length declared by an ext4 superblock. Sparse-file migration tools can
    /// preserve the leading metadata while dropping the logical tail, so checking the magic alone
    /// is insufficient before attaching a persistent Docker store to a VM.
    public static func expectedExt4ImageBytes(at path: String) throws -> Int64? {
        let descriptor = open(path, O_RDONLY | O_CLOEXEC)
        guard descriptor >= 0 else { throw DockerDataDiskError.syscall("open Docker data disk", errno) }
        defer { close(descriptor) }

        var superblock = [UInt8](repeating: 0, count: 1024)
        let count = superblock.withUnsafeMutableBytes {
            pread(descriptor, $0.baseAddress, $0.count, off_t(1024))
        }
        guard count == superblock.count,
              superblock[0x38] == 0x53,
              superblock[0x39] == 0xEF else { return nil }

        func littleEndianUInt32(at offset: Int) -> UInt32 {
            UInt32(superblock[offset])
                | (UInt32(superblock[offset + 1]) << 8)
                | (UInt32(superblock[offset + 2]) << 16)
                | (UInt32(superblock[offset + 3]) << 24)
        }

        let logBlockSize = littleEndianUInt32(at: 0x18)
        guard logBlockSize <= 6 else { return nil }
        let blockSize = UInt64(1024) << UInt64(logBlockSize)
        let featureIncompat = littleEndianUInt32(at: 0x60)
        let blocksLow = UInt64(littleEndianUInt32(at: 0x04))
        let blocksHigh = featureIncompat & 0x80 != 0
            ? UInt64(littleEndianUInt32(at: 0x150))
            : 0
        let blocks = blocksLow | (blocksHigh << 32)
        guard blocks > 0,
              blocks <= UInt64(Int64.max) / blockSize else { return nil }
        return Int64(blocks * blockSize)
    }

    private static func rejectTruncatedExt4Image(at path: String) throws {
        guard let expectedBytes = try expectedExt4ImageBytes(at: path) else { return }
        let attributes: [FileAttributeKey: Any]
        do {
            attributes = try FileManager.default.attributesOfItem(atPath: path)
        } catch {
            throw DockerDataDiskError.filesystem("inspect Docker data disk: \(error)")
        }
        guard let size = attributes[.size] as? NSNumber else {
            throw DockerDataDiskError.filesystem("inspect Docker data disk size: \(path)")
        }
        let actualBytes = size.int64Value
        guard actualBytes >= expectedBytes else {
            throw DockerDataDiskError.truncatedDisk(
                path: path,
                actualBytes: actualBytes,
                expectedBytes: expectedBytes
            )
        }
    }

    private static func sync(path: String) throws {
        let descriptor = open(path, O_RDONLY | O_CLOEXEC)
        guard descriptor >= 0 else { throw DockerDataDiskError.syscall("open cloned Docker data disk", errno) }
        defer { close(descriptor) }
        guard fsync(descriptor) == 0 else { throw DockerDataDiskError.syscall("sync cloned Docker data disk", errno) }
    }

    private static func isUnallocatedSparseBlank(at path: String) throws -> Bool {
        let descriptor = open(path, O_RDONLY | O_CLOEXEC)
        guard descriptor >= 0 else {
            throw DockerDataDiskError.syscall("open existing Docker data disk", errno)
        }
        defer { close(descriptor) }
        var status = stat()
        guard fstat(descriptor, &status) == 0 else {
            throw DockerDataDiskError.syscall("inspect existing Docker data disk allocation", errno)
        }
        // `ftruncate` creates a logical disk with no physical blocks. Once formatting or any other
        // writer allocates a block, a missing ext4 superblock is treated as corruption—not as
        // permission to wipe the file and start over.
        return status.st_blocks == 0
    }

    private static func growSparseFileIfNeeded(_ path: String, minimumBytes: Int64) throws {
        guard minimumBytes > 0 else {
            throw DockerDataDiskError.filesystem("Docker data disk size must be positive")
        }
        let descriptor = open(path, O_RDWR | O_CLOEXEC)
        guard descriptor >= 0 else { throw DockerDataDiskError.syscall("open Docker data disk for growth", errno) }
        defer { close(descriptor) }
        var status = stat()
        guard fstat(descriptor, &status) == 0 else {
            throw DockerDataDiskError.syscall("inspect Docker data disk before growth", errno)
        }
        guard status.st_size < minimumBytes else { return }
        guard ftruncate(descriptor, off_t(minimumBytes)) == 0 else {
            throw DockerDataDiskError.syscall("grow Docker data disk", errno)
        }
        guard fsync(descriptor) == 0 else {
            throw DockerDataDiskError.syscall("sync grown Docker data disk", errno)
        }
    }
}
