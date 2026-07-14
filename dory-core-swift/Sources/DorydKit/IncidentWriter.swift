import Darwin
import Foundation

public struct IncidentRecord: Sendable, Equatable {
    public var at: Date
    public var type: String
    public var detail: String?

    public init(at: Date = Date(), type: String, detail: String? = nil) {
        self.at = at
        self.type = type
        self.detail = detail
    }

    public var xpcDictionary: NSDictionary {
        var dictionary: [String: Any] = [
            "at": incidentISO8601String(at),
            "type": type,
        ]
        if let detail, !detail.isEmpty {
            dictionary["detail"] = detail
        }
        return dictionary as NSDictionary
    }
}

public final class IncidentWriter: @unchecked Sendable {
    private static let maximumRecords = 500
    private static let maximumReadBytes = 8 * 1024 * 1024

    private let path: String
    private let lock = NSLock()

    public init(path: String) {
        self.path = path
    }

    public func record(type: String, detail: String? = nil, at: Date = Date()) {
        record(IncidentRecord(at: at, type: type, detail: detail))
    }

    public func record(_ incident: IncidentRecord) {
        lock.lock()
        defer { lock.unlock() }
        let directory = (path as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)

        guard var line = try? JSONSerialization.data(withJSONObject: incident.xpcDictionary, options: [.sortedKeys]) else {
            return
        }
        line.append(0x0A)

        let coordinationFD = openPrivateRegularFile(
            at: path + ".lock",
            flags: O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW
        )
        guard coordinationFD >= 0 else { return }
        defer { close(coordinationFD) }
        guard flock(coordinationFD, LOCK_EX) == 0 else { return }
        defer { flock(coordinationFD, LOCK_UN) }

        let fd = openPrivateRegularFile(
            at: path,
            flags: O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW
        )
        guard fd >= 0 else { return }
        defer { close(fd) }
        guard lseek(fd, 0, SEEK_END) >= 0, writeAll(line, to: fd) else { return }
        trimLocked(fd: fd)
    }

    public func read(limit: Int = 50) -> [IncidentRecord] {
        readLocked(limit: limit, matchingTypes: nil)
    }

    public func read(limit: Int, matchingTypes: Set<String>) -> [IncidentRecord] {
        readLocked(limit: limit, matchingTypes: matchingTypes)
    }

    private func readLocked(limit: Int, matchingTypes: Set<String>?) -> [IncidentRecord] {
        lock.lock()
        defer { lock.unlock() }
        guard limit > 0 else {
            return []
        }

        let coordinationFD = openPrivateRegularFile(
            at: path + ".lock",
            flags: O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW
        )
        guard coordinationFD >= 0 else { return [] }
        defer { close(coordinationFD) }
        guard flock(coordinationFD, LOCK_SH) == 0 else { return [] }
        defer { flock(coordinationFD, LOCK_UN) }

        let fd = openPrivateRegularFile(at: path, flags: O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard fd >= 0 else { return [] }
        defer { close(fd) }
        let content = String(decoding: boundedTail(fd: fd), as: UTF8.self)
        let rows = content
            .split(separator: "\n")
            .compactMap { IncidentRecord(jsonLine: String($0)) }
            .filter { matchingTypes?.contains($0.type) ?? true }
        return Array(rows.suffix(limit).reversed())
    }

    private func trimLocked(fd: Int32) {
        let tail = boundedTail(fd: fd)
        let lines = tail.split(separator: 0x0A, omittingEmptySubsequences: true)
        guard lines.count > Self.maximumRecords else { return }
        var retained = Data()
        for line in lines.suffix(Self.maximumRecords) {
            retained.append(contentsOf: line)
            retained.append(0x0A)
        }
        guard ftruncate(fd, 0) == 0, lseek(fd, 0, SEEK_SET) >= 0 else { return }
        _ = writeAll(retained, to: fd)
    }

    private func boundedTail(fd: Int32) -> Data {
        var metadata = stat()
        guard fstat(fd, &metadata) == 0 else { return Data() }
        let size = max(0, Int64(metadata.st_size))
        let offset = max(0, size - Int64(Self.maximumReadBytes))
        guard lseek(fd, off_t(offset), SEEK_SET) >= 0 else { return Data() }

        var data = Data()
        data.reserveCapacity(Int(min(Int64(Self.maximumReadBytes), size - offset)))
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while data.count < Self.maximumReadBytes {
            let requested = min(buffer.count, Self.maximumReadBytes - data.count)
            let count = buffer.withUnsafeMutableBytes { bytes in
                Darwin.read(fd, bytes.baseAddress, requested)
            }
            if count <= 0 { break }
            data.append(contentsOf: buffer.prefix(count))
        }
        if offset > 0 {
            guard let newline = data.firstIndex(of: 0x0A) else { return Data() }
            data.removeSubrange(data.startIndex...newline)
        }
        return data
    }

    private func openPrivateRegularFile(at path: String, flags: Int32) -> Int32 {
        let fd = open(path, flags, S_IRUSR | S_IWUSR)
        guard fd >= 0 else { return -1 }
        var metadata = stat()
        guard fstat(fd, &metadata) == 0,
              metadata.st_uid == geteuid(),
              metadata.st_nlink == 1,
              metadata.st_mode & S_IFMT == S_IFREG else {
            close(fd)
            return -1
        }
        guard fchmod(fd, S_IRUSR | S_IWUSR) == 0 else {
            close(fd)
            return -1
        }
        return fd
    }

    private func writeAll(_ data: Data, to fd: Int32) -> Bool {
        data.withUnsafeBytes { rawBuffer in
            guard let base = rawBuffer.baseAddress else { return data.isEmpty }
            var written = 0
            while written < data.count {
                let result = Darwin.write(fd, base.advanced(by: written), data.count - written)
                if result <= 0 { return false }
                written += result
            }
            return true
        }
    }
}

private extension IncidentRecord {
    init?(jsonLine: String) {
        guard let data = jsonLine.data(using: .utf8),
              let raw = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let atString = raw["at"] as? String,
              let at = incidentISO8601Date(atString),
              let type = raw["type"] as? String else {
            return nil
        }
        self.init(at: at, type: type, detail: raw["detail"] as? String)
    }
}

private func incidentISO8601String(_ date: Date) -> String {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter.string(from: date)
}

private func incidentISO8601Date(_ value: String) -> Date? {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter.date(from: value)
}
