import CryptoKit
import Foundation

nonisolated enum MigrationImageArchiveError: Error, Sendable, Equatable, CustomStringConvertible {
    case invalid(String)

    var description: String {
        switch self {
        case let .invalid(detail): "invalid Docker image archive: \(detail)"
        }
    }
}

nonisolated struct MigrationImageLayerFingerprint: Codable, Sendable, Equatable {
    let position: Int
    let archivePath: String
    let logicalBytes: UInt64
    let sha256: String
}

nonisolated struct MigrationImageArchiveFingerprint: Codable, Sendable, Equatable {
    static let schemaVersion = 1

    let schemaVersion: Int
    let configArchivePath: String
    let configBytes: UInt64
    let configSha256: String
    let layers: [MigrationImageLayerFingerprint]
    let archiveBytes: UInt64
    let archiveEntryCount: Int
    let archiveSha256: String
    let archiveContractSha256: String

    init(
        configArchivePath: String,
        configBytes: UInt64,
        configSha256: String,
        layers: [MigrationImageLayerFingerprint],
        archiveBytes: UInt64,
        archiveEntryCount: Int,
        archiveSha256: String
    ) throws {
        schemaVersion = Self.schemaVersion
        self.configArchivePath = configArchivePath
        self.configBytes = configBytes
        self.configSha256 = configSha256
        self.layers = layers
        self.archiveBytes = archiveBytes
        self.archiveEntryCount = archiveEntryCount
        self.archiveSha256 = archiveSha256
        let contract = MigrationImageArchiveContract(
            configSha256: configSha256,
            configBytes: configBytes,
            layers: layers
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(contract) else {
            throw MigrationImageArchiveError.invalid("content contract could not be encoded")
        }
        archiveContractSha256 = SHA256.hash(data: data).hex
    }

    /// Docker's config digest binds platform, runtime configuration, history, and ordered rootfs
    /// diff IDs. A target re-save with this digest is the cross-engine semantic identity proof.
    var semanticIdentity: String { "sha256:\(configSha256)" }
}

nonisolated struct MigrationImageArchiveReader {
    private var parser = MigrationImageTarStreamParser()
    private var archiveHasher = SHA256()

    mutating func feed(_ data: Data) throws {
        archiveHasher.update(data: data)
        try parser.feed(data)
    }

    mutating func finish() throws -> MigrationImageArchiveFingerprint {
        let archive = try parser.finish()
        let hasher = archiveHasher
        return try MigrationImageArchiveManifest.fingerprint(
            archive,
            archiveSha256: hasher.finalize().hex
        )
    }

    static func fingerprint(
        _ stream: AsyncThrowingStream<Data, Error>
    ) async throws -> MigrationImageArchiveFingerprint {
        var reader = MigrationImageArchiveReader()
        for try await chunk in stream {
            try reader.feed(chunk)
        }
        return try reader.finish()
    }
}

private nonisolated struct MigrationImageArchiveContract: Codable {
    let configSha256: String
    let configBytes: UInt64
    let layers: [MigrationImageLayerFingerprint]
}

extension Digest {
    fileprivate nonisolated var hex: String {
        map { String(format: "%02x", $0) }.joined()
    }
}
