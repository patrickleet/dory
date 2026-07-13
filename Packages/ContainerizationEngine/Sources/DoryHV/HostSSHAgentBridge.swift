import Darwin
import Foundation

/// Bridges the guest's well-known SSH-agent vsock port to the current user's macOS SSH agent.
///
/// Host Unix sockets are deliberately not exposed as ordinary virtio-fs inodes: Linux can apply
/// special-file semantics before FUSE receives an OPEN, and cross-kernel AF_UNIX connections cannot
/// be represented safely by a filesystem lookup. The guest agent instead owns a normal Linux Unix
/// socket at `/run/host-services/ssh-auth.sock` and opens one vsock stream here per client.
public final class HostSSHAgentBridge: @unchecked Sendable {
    public enum ConfigurationError: Error, Equatable, CustomStringConvertible, Sendable {
        case relativePath(String)
        case embeddedNull(String)
        case pathTooLong(path: String, utf8ByteCount: Int, maximumUTF8ByteCount: Int)

        public var description: String {
            switch self {
            case .relativePath(let path): "SSH agent socket path must be absolute: \(path)"
            case .embeddedNull(let path): "SSH agent socket path contains a NUL byte: \(path)"
            case let .pathTooLong(path, count, maximum):
                "SSH agent socket path is \(count) UTF-8 bytes (maximum \(maximum)): \(path)"
            }
        }
    }

    private let socketPath: String
    private let expectedUID: uid_t
    private let log: @Sendable (String) -> Void

    public init(
        socketPath: String,
        expectedUID: uid_t = getuid(),
        log: @escaping @Sendable (String) -> Void = { _ in }
    ) throws {
        try Self.validate(socketPath: socketPath)
        self.socketPath = socketPath
        self.expectedUID = expectedUID
        self.log = log
    }

    public static func validate(socketPath: String) throws {
        guard socketPath.hasPrefix("/") else {
            throw ConfigurationError.relativePath(socketPath)
        }
        let bytes = Array(socketPath.utf8)
        guard !bytes.contains(0) else {
            throw ConfigurationError.embeddedNull(socketPath)
        }
        guard bytes.count <= VsockUnixRelay.maximumSocketPathByteCount else {
            throw ConfigurationError.pathTooLong(
                path: socketPath,
                utf8ByteCount: bytes.count,
                maximumUTF8ByteCount: VsockUnixRelay.maximumSocketPathByteCount
            )
        }
    }

    public func attach(to vsock: VirtioVsock) {
        vsock.listen(port: VsockPorts.sshAgent) { [self] connection in
            let box = ConnectionBox(connection)
            Thread.detachNewThread {
                guard let fd = Self.connectSameUserSocket(
                    path: self.socketPath,
                    expectedUID: self.expectedUID
                ) else {
                    self.log("SSH agent bridge rejected an unavailable or non-owned host socket")
                    box.connection.close()
                    return
                }
                VsockUnixRelay.serve(client: fd, connection: box.connection)
            }
        }
        log("SSH agent bridge ready on guest vsock:\(VsockPorts.sshAgent)")
    }

    private final class ConnectionBox: @unchecked Sendable {
        let connection: VsockConnection
        init(_ connection: VsockConnection) { self.connection = connection }
    }

    static func connectSameUserSocket(
        path: String,
        expectedUID: uid_t,
        timeoutMilliseconds: Int32 = 2_000
    ) -> Int32? {
        var status = stat()
        guard lstat(path, &status) == 0,
              status.st_mode & mode_t(S_IFMT) == mode_t(S_IFSOCK),
              status.st_uid == expectedUID else {
            return nil
        }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        let originalFlags = fcntl(fd, F_GETFL, 0)
        guard originalFlags >= 0,
              fcntl(fd, F_SETFL, originalFlags | O_NONBLOCK) == 0 else {
            close(fd)
            return nil
        }
        var noSigpipe: Int32 = 1
        _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigpipe, socklen_t(MemoryLayout<Int32>.size))
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(path.utf8)
        withUnsafeMutableBytes(of: &address.sun_path) { destination in
            pathBytes.withUnsafeBytes { source in
                destination.baseAddress!.copyMemory(
                    from: source.baseAddress!,
                    byteCount: pathBytes.count
                )
            }
        }
        let connected = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        if connected != 0 {
            guard errno == EINPROGRESS else {
                close(fd)
                return nil
            }
            var descriptor = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
            guard poll(&descriptor, 1, max(0, timeoutMilliseconds)) > 0 else {
                close(fd)
                return nil
            }
            var socketError: Int32 = 0
            var socketErrorLength = socklen_t(MemoryLayout<Int32>.size)
            guard getsockopt(
                fd,
                SOL_SOCKET,
                SO_ERROR,
                &socketError,
                &socketErrorLength
            ) == 0, socketError == 0 else {
                close(fd)
                return nil
            }
        }
        guard fcntl(fd, F_SETFL, originalFlags) == 0 else {
            close(fd)
            return nil
        }
        return fd
    }
}
