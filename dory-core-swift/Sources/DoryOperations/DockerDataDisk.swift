import Darwin
import Foundation

public enum DockerDataDiskPreparation: Sendable, Equatable {
    case alreadyPresent
    case createdBlank
}

public enum DockerDataDiskError: Error, Sendable, Equatable, CustomStringConvertible {
    case invalidExistingDisk(String)
    case unsafeExistingDisk(String)
    case truncatedDisk(path: String, actualBytes: Int64, expectedBytes: Int64)
    case invalidCapacityGiB(requested: Int, minimum: Int, maximum: Int)
    case shrinkUnsupported(path: String, currentBytes: Int64, requestedBytes: Int64)
    case syscall(String, Int32)
    case filesystem(String)

    public var description: String {
        switch self {
        case let .invalidExistingDisk(path):
            "existing Docker data disk is neither ext4 nor an unallocated sparse blank: \(path); refusing to format possible user data"
        case let .unsafeExistingDisk(path):
            "Docker data disk must be a private, owner-controlled regular file with one link: \(path)"
        case let .truncatedDisk(path, actualBytes, expectedBytes):
            "Docker data disk appears truncated: \(path) is \(actualBytes) bytes, but its ext4 superblock requires at least \(expectedBytes) bytes; restore or repair the sparse image before retrying"
        case let .invalidCapacityGiB(requested, minimum, maximum):
            "Docker disk capacity must be between \(minimum) and \(maximum) GiB (requested \(requested) GiB)"
        case let .shrinkUnsupported(path, currentBytes, requestedBytes):
            "Docker disk shrinking is not supported: \(path) is \(currentBytes) bytes and cannot be reduced to \(requestedBytes) bytes; back up and restore into a new drive instead"
        case let .syscall(operation, code):
            "\(operation): \(String(cString: strerror(code)))"
        case let .filesystem(message):
            message
        }
    }
}

public struct DockerDataDiskUsage: Codable, Sendable, Equatable {
    public let initialized: Bool
    public let logicalBytes: Int64
    public let allocatedBytes: Int64
    public let capacityGiB: Int
    public let minimumCapacityGiB: Int
    public let maximumCapacityGiB: Int
}

/// Creates and validates Dory's public-v1 Docker data disk. Existing bytes are never formatted or
/// replaced unless the file is a host-proven, entirely unallocated sparse blank from an interrupted
/// first launch.
public enum DockerDataDisk {
    public static let bytesPerGiB: Int64 = 1024 * 1024 * 1024
    public static let minimumCapacityGiB = 128
    public static let maximumCapacityGiB = 2_048

    /// Logical capacity only: APFS keeps the backing file sparse and allocates physical blocks as
    /// Docker writes them. 128 GiB avoids a hidden 16 GiB ceiling during competitor import without
    /// reserving 128 GiB on the Mac.
    public static let blankDiskBytes: Int64 = 128 * 1024 * 1024 * 1024

    @discardableResult
    public static func prepare(
        destination: String,
        blankSize: Int64 = blankDiskBytes,
        fileManager: FileManager = .default
    ) throws -> DockerDataDiskPreparation {
        guard blankSize > 0 else {
            throw DockerDataDiskError.filesystem("Docker data disk size must be positive")
        }
        if try pathEntryExists(destination) {
            let descriptor = try openValidated(destination, flags: O_RDWR)
            defer { close(descriptor) }
            var status = stat()
            guard fstat(descriptor, &status) == 0 else {
                throw DockerDataDiskError.syscall("inspect Docker data disk before growth", errno)
            }
            try validateContents(of: descriptor, at: destination, status: status)
            guard status.st_size < blankSize else { return .alreadyPresent }
            guard ftruncate(descriptor, off_t(blankSize)) == 0 else {
                throw DockerDataDiskError.syscall("grow Docker data disk", errno)
            }
            guard fsync(descriptor) == 0 else {
                throw DockerDataDiskError.syscall("sync grown Docker data disk", errno)
            }
            return .alreadyPresent
        }
        try fileManager.createDirectory(
            at: URL(fileURLWithPath: destination).deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let parent = URL(fileURLWithPath: destination).deletingLastPathComponent().path
        let partial = destination + ".partial"
        try? fileManager.removeItem(atPath: partial)

        let descriptor = open(
            partial,
            O_CREAT | O_EXCL | O_RDWR | O_CLOEXEC | O_NOFOLLOW,
            S_IRUSR | S_IWUSR
        )
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
            try syncDirectory(parent)
            return .createdBlank
        } catch {
            try? fileManager.removeItem(atPath: partial)
            throw DockerDataDiskError.filesystem("publish Docker data disk: \(error)")
        }
    }

    /// Reports the logical ceiling separately from physical APFS allocation. An uninitialized
    /// selected drive reports the production default without creating its Docker disk.
    public static func usage(at destination: String) throws -> DockerDataDiskUsage {
        guard try pathEntryExists(destination) else {
            return DockerDataDiskUsage(
                initialized: false,
                logicalBytes: blankDiskBytes,
                allocatedBytes: 0,
                capacityGiB: minimumCapacityGiB,
                minimumCapacityGiB: minimumCapacityGiB,
                maximumCapacityGiB: maximumCapacityGiB
            )
        }
        let descriptor = try openValidated(destination, flags: O_RDONLY)
        defer { close(descriptor) }
        var status = stat()
        guard fstat(descriptor, &status) == 0 else {
            throw DockerDataDiskError.syscall("inspect Docker data disk usage", errno)
        }
        try validateContents(of: descriptor, at: destination, status: status)
        let logicalBytes = Int64(status.st_size)
        let wholeGiB = logicalBytes / bytesPerGiB
        let capacityGiB = Int(wholeGiB + (logicalBytes % bytesPerGiB == 0 ? 0 : 1))
        return DockerDataDiskUsage(
            initialized: true,
            logicalBytes: logicalBytes,
            allocatedBytes: Int64(status.st_blocks) * 512,
            capacityGiB: capacityGiB,
            minimumCapacityGiB: minimumCapacityGiB,
            maximumCapacityGiB: maximumCapacityGiB
        )
    }

    /// Grows the sparse host file. The guest performs the ext4 expansion on its next boot. Shrink
    /// requests fail before mutation because host truncation before an offline ext4 shrink would
    /// destroy data.
    public static func grow(
        destination: String,
        capacityGiB: Int,
        fileManager: FileManager = .default
    ) throws -> DockerDataDiskUsage {
        guard (minimumCapacityGiB...maximumCapacityGiB).contains(capacityGiB) else {
            throw DockerDataDiskError.invalidCapacityGiB(
                requested: capacityGiB,
                minimum: minimumCapacityGiB,
                maximum: maximumCapacityGiB
            )
        }
        let requestedBytes = Int64(capacityGiB) * bytesPerGiB
        let current = try usage(at: destination)
        if current.initialized, current.logicalBytes > requestedBytes {
            throw DockerDataDiskError.shrinkUnsupported(
                path: destination,
                currentBytes: current.logicalBytes,
                requestedBytes: requestedBytes
            )
        }
        _ = try prepare(
            destination: destination,
            blankSize: requestedBytes,
            fileManager: fileManager
        )
        return try usage(at: destination)
    }

    public static func isExt4Image(at path: String) throws -> Bool {
        let descriptor = try openValidated(path, flags: O_RDONLY)
        defer { close(descriptor) }
        return try expectedExt4ImageBytes(on: descriptor) != nil
    }

    /// Returns the byte length declared by an ext4 superblock. Sparse-file migration tools can
    /// preserve the leading metadata while dropping the logical tail, so checking the magic alone
    /// is insufficient before attaching a persistent Docker store to a VM.
    public static func expectedExt4ImageBytes(at path: String) throws -> Int64? {
        let descriptor = try openValidated(path, flags: O_RDONLY)
        defer { close(descriptor) }
        return try expectedExt4ImageBytes(on: descriptor)
    }

    private static func expectedExt4ImageBytes(on descriptor: Int32) throws -> Int64? {
        // EXT4_SUPER_MAGIC is the little-endian 16-bit value at offset 0x38 in the superblock,
        // whose base is byte 1024.
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

    private static func validateContents(
        of descriptor: Int32,
        at path: String,
        status: stat
    ) throws {
        if let expectedBytes = try expectedExt4ImageBytes(on: descriptor) {
            let actualBytes = Int64(status.st_size)
            guard actualBytes >= expectedBytes else {
                throw DockerDataDiskError.truncatedDisk(
                    path: path,
                    actualBytes: actualBytes,
                    expectedBytes: expectedBytes
                )
            }
            return
        }
        guard status.st_blocks == 0 else {
            throw DockerDataDiskError.invalidExistingDisk(path)
        }
    }

    private static func pathEntryExists(_ path: String) throws -> Bool {
        var status = stat()
        if path.withCString({ lstat($0, &status) }) == 0 { return true }
        if errno == ENOENT { return false }
        throw DockerDataDiskError.syscall("inspect Docker data disk path", errno)
    }

    private static func openValidated(_ path: String, flags: Int32) throws -> Int32 {
        let descriptor = path.withCString { open($0, flags | O_CLOEXEC | O_NOFOLLOW) }
        guard descriptor >= 0 else {
            if errno == ELOOP {
                throw DockerDataDiskError.unsafeExistingDisk(path)
            }
            throw DockerDataDiskError.syscall("open Docker data disk", errno)
        }
        var status = stat()
        guard fstat(descriptor, &status) == 0,
              status.st_mode & S_IFMT == S_IFREG,
              status.st_uid == getuid(),
              status.st_mode & 0o077 == 0,
              status.st_nlink == 1 else {
            close(descriptor)
            throw DockerDataDiskError.unsafeExistingDisk(path)
        }
        return descriptor
    }

    private static func syncDirectory(_ path: String) throws {
        let descriptor = path.withCString { open($0, O_RDONLY | O_CLOEXEC | O_NOFOLLOW) }
        guard descriptor >= 0 else {
            throw DockerDataDiskError.syscall("open Docker data disk directory for sync", errno)
        }
        defer { close(descriptor) }
        guard fsync(descriptor) == 0 else {
            throw DockerDataDiskError.syscall("sync Docker data disk directory", errno)
        }
    }
}
