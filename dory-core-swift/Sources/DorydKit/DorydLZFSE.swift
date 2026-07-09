import Compression
import Foundation

public enum DorydLZFSEError: Error, CustomStringConvertible {
    case openInput(String)
    case openOutput(String)
    case streamInit
    case read
    case write
    case process
    case decodedTooLarge(Int)

    public var description: String {
        switch self {
        case .openInput(let path): "cannot open input \(path)"
        case .openOutput(let path): "cannot open output \(path)"
        case .streamInit: "compression_stream_init failed"
        case .read: "read failed"
        case .write: "write failed"
        case .process: "compression_stream_process failed"
        case .decodedTooLarge(let cap): "decompressed output exceeds \(cap) bytes"
        }
    }
}

public enum DorydLZFSE {
    private static let chunk = 1 << 20
    // Guard against a decompression bomb. The largest legitimate payload here is an
    // engine rootfs ext4 image (a few GiB); 16 GiB leaves generous headroom while
    // bounding a malicious archive that would otherwise fill the disk.
    private static let maxDecodedBytes = 16 << 30

    public static func compress(source: String, destination: String) throws {
        try transform(source: source, destination: destination, operation: COMPRESSION_STREAM_ENCODE)
    }

    public static func decompress(source: String, destination: String) throws {
        try transform(source: source, destination: destination, operation: COMPRESSION_STREAM_DECODE)
    }

    private static func transform(source: String, destination: String, operation: compression_stream_operation) throws {
        guard let input = InputStream(fileAtPath: source) else { throw DorydLZFSEError.openInput(source) }
        guard let output = OutputStream(toFileAtPath: destination, append: false) else { throw DorydLZFSEError.openOutput(destination) }
        input.open()
        output.open()
        defer { input.close(); output.close() }

        let sourceBuffer = UnsafeMutablePointer<UInt8>.allocate(capacity: chunk)
        let sinkBuffer = UnsafeMutablePointer<UInt8>.allocate(capacity: chunk)
        defer {
            sourceBuffer.deallocate()
            sinkBuffer.deallocate()
        }

        var stream = compression_stream(
            dst_ptr: sinkBuffer,
            dst_size: chunk,
            src_ptr: UnsafePointer(sourceBuffer),
            src_size: 0,
            state: nil
        )
        guard compression_stream_init(&stream, operation, COMPRESSION_LZFSE) == COMPRESSION_STATUS_OK else {
            throw DorydLZFSEError.streamInit
        }
        defer { compression_stream_destroy(&stream) }

        stream.src_size = 0
        stream.dst_ptr = sinkBuffer
        stream.dst_size = chunk
        var inputExhausted = false
        var totalProduced = 0
        let decoding = operation == COMPRESSION_STREAM_DECODE

        while true {
            if stream.src_size == 0, !inputExhausted {
                let read = input.read(sourceBuffer, maxLength: chunk)
                if read < 0 { throw DorydLZFSEError.read }
                if read == 0 { inputExhausted = true }
                stream.src_ptr = UnsafePointer(sourceBuffer)
                stream.src_size = read
            }

            let flags = inputExhausted ? Int32(COMPRESSION_STREAM_FINALIZE.rawValue) : 0
            let status = compression_stream_process(&stream, flags)
            guard status == COMPRESSION_STATUS_OK || status == COMPRESSION_STATUS_END else {
                throw DorydLZFSEError.process
            }

            let produced = chunk - stream.dst_size
            if produced > 0 {
                totalProduced += produced
                if decoding, totalProduced > maxDecodedBytes {
                    throw DorydLZFSEError.decodedTooLarge(maxDecodedBytes)
                }
                var offset = 0
                while offset < produced {
                    let written = output.write(sinkBuffer + offset, maxLength: produced - offset)
                    if written <= 0 { throw DorydLZFSEError.write }
                    offset += written
                }
                stream.dst_ptr = sinkBuffer
                stream.dst_size = chunk
            }

            if status == COMPRESSION_STATUS_END { return }
        }
    }
}
