import Darwin
import DoryCore
import Foundation

public enum SourcePreservingLANPrivilegedError: Error, Sendable, Equatable, CustomStringConvertible {
    case rootRequired
    case unsupportedVersion(Int)
    case invalidSessionID
    case invalidSocketPath
    case socketUnavailable(String)
    case socketOwnerMismatch(expected: uid_t, actual: uid_t)
    case sessionConflict
    case noActiveSession
    case interfaceUnavailable
    case commandFailed(String)

    public var description: String {
        switch self {
        case .rootRequired: "source-preserving LAN helper must run as root"
        case .unsupportedVersion(let value): "unsupported source-preserving LAN request version: \(value)"
        case .invalidSessionID: "invalid source-preserving LAN session identifier"
        case .invalidSocketPath: "invalid gvproxy socket path"
        case .socketUnavailable(let path): "gvproxy socket is unavailable: \(path)"
        case .socketOwnerMismatch(let expected, let actual):
            "gvproxy socket owner mismatch (expected uid \(expected), found \(actual))"
        case .sessionConflict: "another source-preserving LAN session is already active"
        case .noActiveSession: "source-preserving LAN session is not active"
        case .interfaceUnavailable: "privileged UTUN did not report an interface name"
        case .commandFailed(let message): "source-preserving LAN privileged command failed: \(message)"
        }
    }
}

public protocol SourcePreservingLANBridgeSession: AnyObject, Sendable {
    var activeInterfaceName: String? { get }
    var isHealthy: Bool { get }
    func start() throws
    func stop()
    func setFailureHandler(_ handler: @escaping @Sendable (String) -> Void)
}

extension DirectIPBridge: SourcePreservingLANBridgeSession {}

/// Root-side owner for the UTUN, gvproxy packet bridge, host route, and a dedicated PF anchor.
/// The controller accepts only a signed-XPC caller's own gvproxy socket and re-derives every rule
/// from closed scalar inputs; callers never submit a command or PF fragment.
public final class SourcePreservingLANPrivilegedController: @unchecked Sendable {
    public typealias BridgeFactory = @Sendable (DirectIPBridgeConfiguration) throws -> any SourcePreservingLANBridgeSession
    public typealias CommandRunner = @Sendable ([String]) throws -> String
    public typealias AnchorWriter = @Sendable (String) throws -> Void

    public static let anchorName = "com.apple/dev.dory.lan"
    public static let anchorPath = "/etc/pf.anchors/dev.dory.lan"
    public static let runtimeDirectory = "/var/run/dev.dory"

    private let operationLock = NSRecursiveLock()
    private let lock = NSLock()
    private let bridgeFactory: BridgeFactory
    private let runCommand: CommandRunner
    private let writeAnchor: AnchorWriter
    private let enforceRoot: Bool
    private let runtimeDirectory: String
    private var activeSessionID: String?
    private var activeBridge: (any SourcePreservingLANBridgeSession)?
    private var activeInterfaceName: String?
    private var activePFToken: String?
    private var activeIPv4ForwardingOwned = false

    public init(
        enforceRoot: Bool = true,
        runtimeDirectory: String = SourcePreservingLANPrivilegedController.runtimeDirectory,
        bridgeFactory: BridgeFactory? = nil,
        runCommand: CommandRunner? = nil,
        writeAnchor: AnchorWriter? = nil
    ) {
        self.enforceRoot = enforceRoot
        self.runtimeDirectory = runtimeDirectory
        self.bridgeFactory = bridgeFactory ?? { configuration in
            try DirectIPBridge(configuration: configuration)
        }
        self.runCommand = runCommand ?? Self.runCommand
        self.writeAnchor = writeAnchor ?? Self.writeAnchor
    }

    deinit {
        activeBridge?.stop()
    }

    public func apply(
        _ request: SourcePreservingLANRequest,
        clientUID: uid_t
    ) throws -> SourcePreservingLANResponse {
        operationLock.lock()
        defer { operationLock.unlock() }
        if enforceRoot, geteuid() != 0 { throw SourcePreservingLANPrivilegedError.rootRequired }
        try Self.validateCommon(request)
        switch request.operation {
        case .activate:
            return try activate(request, clientUID: clientUID)
        case .refresh:
            return try refresh(request)
        case .deactivate:
            return try deactivate(request)
        }
    }

    /// Called once when launchd starts or restarts the daemon. A previous crash must leave closed
    /// ports, never a stale redirect to a dead tunnel.
    public func clearStaleAnchor() {
        operationLock.lock()
        defer { operationLock.unlock() }
        try? writeAnchor("# Managed by Dory. Do not edit.\n")
        _ = try? runCommand(["/sbin/pfctl", "-a", Self.anchorName, "-F", "all"])
        if let token = try? readPersistedPFToken() {
            try? releasePFToken(token)
        }
        try? restoreIPv4ForwardingIfOwned()
    }

    private func activate(
        _ request: SourcePreservingLANRequest,
        clientUID: uid_t
    ) throws -> SourcePreservingLANResponse {
        guard let gvproxySocketPath = request.gvproxySocketPath else {
            throw SourcePreservingLANPrivilegedError.invalidSocketPath
        }
        try Self.validateGVProxySocket(gvproxySocketPath, clientUID: clientUID)

        lock.lock()
        guard activeSessionID == nil || activeSessionID == request.sessionID else {
            lock.unlock()
            throw SourcePreservingLANPrivilegedError.sessionConflict
        }
        if activeBridge != nil, activeSessionID == request.sessionID {
            let interfaceName = activeInterfaceName
            lock.unlock()
            _ = try applyPF(bindings: request.bindings, enable: false)
            return response(request, interfaceName: interfaceName)
        }
        lock.unlock()

        try FileManager.default.createDirectory(
            atPath: runtimeDirectory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o755]
        )
        let localSocket = "\(runtimeDirectory)/\(request.sessionID).sock"
        let interfaceFile = "\(runtimeDirectory)/\(request.sessionID).interface"
        let configuration = DirectIPBridgeConfiguration(
            subnetCIDR: SourcePreservingLANPlan.guestIngressCIDR,
            gateway: "192.168.215.253",
            gvproxySocketPath: gvproxySocketPath,
            localSocketPath: localSocket,
            interfaceNamePath: interfaceFile
        )
        let bridge = try bridgeFactory(configuration)
        bridge.setFailureHandler { [weak self] detail in
            self?.bridgeFailed(sessionID: request.sessionID, detail: detail)
        }
        var acquiredPFToken: String?
        var enabledIPv4Forwarding = false
        do {
            try bridge.start()
            guard let interfaceName = bridge.activeInterfaceName,
                  interfaceName.wholeMatch(of: /utun[0-9]+/) != nil else {
                throw SourcePreservingLANPrivilegedError.interfaceUnavailable
            }
            _ = try runCommand([
                "/sbin/ifconfig", interfaceName, "inet",
                "192.168.215.253", SourcePreservingLANPlan.guestIngressIPv4,
                "netmask", "255.255.255.255", "mtu", "1500", "up",
            ])
            _ = try? runCommand([
                "/sbin/route", "-n", "delete", "-host", SourcePreservingLANPlan.guestIngressIPv4,
            ])
            _ = try runCommand([
                "/sbin/route", "-n", "add", "-host", SourcePreservingLANPlan.guestIngressIPv4,
                "-interface", interfaceName,
            ])
            enabledIPv4Forwarding = try enableIPv4ForwardingIfNeeded()
            acquiredPFToken = try applyPF(bindings: request.bindings, enable: true)
            lock.lock()
            activeSessionID = request.sessionID
            activeBridge = bridge
            activeInterfaceName = interfaceName
            activePFToken = acquiredPFToken
            activeIPv4ForwardingOwned = enabledIPv4Forwarding
            lock.unlock()
            guard bridge.isHealthy else {
                throw SourcePreservingLANPrivilegedError.commandFailed(
                    "gvproxy LAN switch disconnected during activation"
                )
            }
            return response(request, interfaceName: interfaceName)
        } catch {
            lock.lock()
            if activeSessionID == request.sessionID {
                activeSessionID = nil
                activeBridge = nil
                activeInterfaceName = nil
                activePFToken = nil
                activeIPv4ForwardingOwned = false
            }
            lock.unlock()
            try? writeAnchor("# Managed by Dory. Do not edit.\n")
            _ = try? runCommand(["/sbin/pfctl", "-a", Self.anchorName, "-F", "all"])
            if let acquiredPFToken { try? releasePFToken(acquiredPFToken) }
            if enabledIPv4Forwarding { try? restoreIPv4ForwardingIfOwned() }
            bridge.stop()
            throw error
        }
    }

    private func bridgeFailed(sessionID: String, detail: String) {
        operationLock.lock()
        defer { operationLock.unlock() }
        lock.lock()
        guard activeSessionID == sessionID, let bridge = activeBridge else {
            lock.unlock()
            return
        }
        activeSessionID = nil
        activeBridge = nil
        activeInterfaceName = nil
        let pfToken = activePFToken
        activePFToken = nil
        let forwardingOwned = activeIPv4ForwardingOwned
        activeIPv4ForwardingOwned = false
        lock.unlock()

        try? writeAnchor("# Managed by Dory. Do not edit.\n")
        _ = try? runCommand(["/sbin/pfctl", "-a", Self.anchorName, "-F", "all"])
        if let pfToken { try? releasePFToken(pfToken) }
        if forwardingOwned { try? restoreIPv4ForwardingIfOwned() }
        bridge.stop()
        _ = detail
    }

    private func refresh(_ request: SourcePreservingLANRequest) throws -> SourcePreservingLANResponse {
        lock.lock()
        let matches = activeSessionID == request.sessionID && activeBridge != nil
        let interfaceName = activeInterfaceName
        lock.unlock()
        guard matches else { throw SourcePreservingLANPrivilegedError.noActiveSession }
        _ = try applyPF(bindings: request.bindings, enable: false)
        return response(request, interfaceName: interfaceName)
    }

    private func deactivate(_ request: SourcePreservingLANRequest) throws -> SourcePreservingLANResponse {
        lock.lock()
        guard activeSessionID == request.sessionID, let bridge = activeBridge else {
            lock.unlock()
            throw SourcePreservingLANPrivilegedError.noActiveSession
        }
        let interfaceName = activeInterfaceName
        activeSessionID = nil
        activeBridge = nil
        activeInterfaceName = nil
        let pfToken = activePFToken
        activePFToken = nil
        let forwardingOwned = activeIPv4ForwardingOwned
        activeIPv4ForwardingOwned = false
        lock.unlock()

        try writeAnchor("# Managed by Dory. Do not edit.\n")
        _ = try runCommand(["/sbin/pfctl", "-a", Self.anchorName, "-F", "all"])
        bridge.stop()
        var cleanupError: Error?
        if let pfToken {
            do { try releasePFToken(pfToken) } catch { cleanupError = error }
        }
        if forwardingOwned {
            do { try restoreIPv4ForwardingIfOwned() } catch {
                if cleanupError == nil { cleanupError = error }
            }
        }
        if let cleanupError { throw cleanupError }
        return SourcePreservingLANResponse(
            status: "stopped",
            sessionID: request.sessionID,
            interfaceName: interfaceName,
            lanBindingCount: 0
        )
    }

    private func applyPF(bindings: Set<PublishedPortBinding>, enable: Bool) throws -> String? {
        let contents = SourcePreservingLANPlan.pfAnchorContents(bindings: bindings)
        try writeAnchor(contents)
        _ = try runCommand(["/sbin/pfctl", "-a", Self.anchorName, "-f", Self.anchorPath])
        guard enable else { return nil }
        let output = try runCommand(["/sbin/pfctl", "-E"])
        guard let token = Self.pfEnableToken(from: output) else {
            throw SourcePreservingLANPrivilegedError.commandFailed(
                "pfctl -E did not return a releasable enable token"
            )
        }
        do {
            try persistPFToken(token)
        } catch {
            _ = try? runCommand(["/sbin/pfctl", "-X", token])
            throw error
        }
        return token
    }

    /// `/sbin/pfctl -E` writes `Token : %llu` (possibly alongside status text and on either
    /// output stream). DoryShell deliberately merges stdout/stderr so the root daemon can retain
    /// and later release the exact PF enable reference it acquired.
    static func pfEnableToken(from output: String) -> String? {
        for line in output.split(whereSeparator: { $0.isNewline }) {
            let value = line.trimmingCharacters(in: .whitespaces)
            guard value.hasPrefix("Token :") else { continue }
            let token = value.dropFirst("Token :".count).trimmingCharacters(in: .whitespaces)
            if token.wholeMatch(of: /[0-9]+/) != nil { return token }
        }
        return nil
    }

    private var pfTokenPath: String { runtimeDirectory + "/pf-enable-token" }
    private var forwardingMarkerPath: String { runtimeDirectory + "/ipv4-forwarding-owner" }

    /// UTUN packets written by the bridge enter macOS as received packets. IPv4 forwarding must be
    /// enabled while PF-rdr replies travel from that UTUN back to the physical/VPN interface. Dory
    /// records ownership only when it changed the host from 0 to 1, and restores that exact prior
    /// state on normal shutdown, bridge failure, or daemon crash recovery.
    private func enableIPv4ForwardingIfNeeded() throws -> Bool {
        let current = try runCommand(["/usr/sbin/sysctl", "-n", "net.inet.ip.forwarding"])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard current == "0" || current == "1" else {
            throw SourcePreservingLANPrivilegedError.commandFailed(
                "unexpected net.inet.ip.forwarding value: \(current)"
            )
        }
        guard current == "0" else { return false }
        _ = try runCommand(["/usr/sbin/sysctl", "-w", "net.inet.ip.forwarding=1"])
        do {
            try writeOwnedFile(path: forwardingMarkerPath, contents: "restore=0\n")
        } catch {
            _ = try? runCommand(["/usr/sbin/sysctl", "-w", "net.inet.ip.forwarding=0"])
            throw error
        }
        return true
    }

    private func restoreIPv4ForwardingIfOwned() throws {
        let descriptor = open(forwardingMarkerPath, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        if descriptor < 0, errno == ENOENT { return }
        guard descriptor >= 0 else {
            throw SourcePreservingLANPrivilegedError.commandFailed(
                "open \(forwardingMarkerPath): \(String(cString: strerror(errno)))"
            )
        }
        defer { close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_size == 10 else {
            throw SourcePreservingLANPrivilegedError.commandFailed("invalid IPv4 forwarding ownership marker")
        }
        var bytes = [UInt8](repeating: 0, count: Int(info.st_size))
        guard Darwin.read(descriptor, &bytes, bytes.count) == bytes.count,
              String(bytes: bytes, encoding: .utf8) == "restore=0\n" else {
            throw SourcePreservingLANPrivilegedError.commandFailed("invalid IPv4 forwarding ownership marker")
        }
        _ = try runCommand(["/usr/sbin/sysctl", "-w", "net.inet.ip.forwarding=0"])
        if unlink(forwardingMarkerPath) != 0, errno != ENOENT {
            throw SourcePreservingLANPrivilegedError.commandFailed(
                "unlink \(forwardingMarkerPath): \(String(cString: strerror(errno)))"
            )
        }
    }

    private func writeOwnedFile(path: String, contents: String) throws {
        let bytes = Array(contents.utf8)
        let descriptor = open(path, O_WRONLY | O_CREAT | O_TRUNC | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else {
            throw SourcePreservingLANPrivilegedError.commandFailed(
                "open \(path): \(String(cString: strerror(errno)))"
            )
        }
        defer { close(descriptor) }
        _ = fchmod(descriptor, 0o600)
        var offset = 0
        while offset < bytes.count {
            let written = bytes.withUnsafeBytes { raw in
                Darwin.write(descriptor, raw.baseAddress?.advanced(by: offset), bytes.count - offset)
            }
            guard written > 0 else {
                throw SourcePreservingLANPrivilegedError.commandFailed(
                    "write \(path): \(String(cString: strerror(errno)))"
                )
            }
            offset += written
        }
        guard fsync(descriptor) == 0 else {
            throw SourcePreservingLANPrivilegedError.commandFailed(
                "fsync \(path): \(String(cString: strerror(errno)))"
            )
        }
    }

    private func persistPFToken(_ token: String) throws {
        let bytes = Array((token + "\n").utf8)
        let descriptor = open(pfTokenPath, O_WRONLY | O_CREAT | O_TRUNC | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else {
            throw SourcePreservingLANPrivilegedError.commandFailed(
                "open \(pfTokenPath): \(String(cString: strerror(errno)))"
            )
        }
        defer { close(descriptor) }
        _ = fchmod(descriptor, 0o600)
        var offset = 0
        while offset < bytes.count {
            let written = bytes.withUnsafeBytes { raw in
                Darwin.write(descriptor, raw.baseAddress?.advanced(by: offset), bytes.count - offset)
            }
            guard written > 0 else {
                throw SourcePreservingLANPrivilegedError.commandFailed(
                    "write \(pfTokenPath): \(String(cString: strerror(errno)))"
                )
            }
            offset += written
        }
        guard fsync(descriptor) == 0 else {
            throw SourcePreservingLANPrivilegedError.commandFailed(
                "fsync \(pfTokenPath): \(String(cString: strerror(errno)))"
            )
        }
    }

    private func readPersistedPFToken() throws -> String? {
        let descriptor = open(pfTokenPath, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        if descriptor < 0, errno == ENOENT { return nil }
        guard descriptor >= 0 else {
            throw SourcePreservingLANPrivilegedError.commandFailed(
                "open \(pfTokenPath): \(String(cString: strerror(errno)))"
            )
        }
        defer { close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_size > 0, info.st_size <= 64 else {
            throw SourcePreservingLANPrivilegedError.commandFailed("invalid persisted PF enable token")
        }
        var bytes = [UInt8](repeating: 0, count: Int(info.st_size))
        let count = Darwin.read(descriptor, &bytes, bytes.count)
        guard count == bytes.count,
              let value = String(bytes: bytes, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
              value.wholeMatch(of: /[0-9]+/) != nil else {
            throw SourcePreservingLANPrivilegedError.commandFailed("invalid persisted PF enable token")
        }
        return value
    }

    private func releasePFToken(_ token: String) throws {
        _ = try runCommand(["/sbin/pfctl", "-X", token])
        if unlink(pfTokenPath) != 0, errno != ENOENT {
            throw SourcePreservingLANPrivilegedError.commandFailed(
                "unlink \(pfTokenPath): \(String(cString: strerror(errno)))"
            )
        }
    }

    private func response(
        _ request: SourcePreservingLANRequest,
        interfaceName: String?
    ) -> SourcePreservingLANResponse {
        SourcePreservingLANResponse(
            status: "active",
            sessionID: request.sessionID,
            interfaceName: interfaceName,
            lanBindingCount: SourcePreservingLANPlan.lanBindings(from: request.bindings).count
        )
    }

    private static func validateCommon(_ request: SourcePreservingLANRequest) throws {
        guard request.version == SourcePreservingLANRequest.schemaVersion else {
            throw SourcePreservingLANPrivilegedError.unsupportedVersion(request.version)
        }
        guard request.sessionID.wholeMatch(of: /[A-Za-z0-9][A-Za-z0-9.-]{0,63}/) != nil,
              !request.sessionID.contains(".."),
              request.bindings.count <= 4_096 else {
            throw SourcePreservingLANPrivilegedError.invalidSessionID
        }
    }

    private static func validateGVProxySocket(_ path: String, clientUID: uid_t) throws {
        guard path.hasPrefix("/"), !path.contains("\0"), !path.contains("\n"),
              path.utf8.count < MemoryLayout.size(ofValue: sockaddr_un().sun_path) else {
            throw SourcePreservingLANPrivilegedError.invalidSocketPath
        }
        var info = stat()
        guard lstat(path, &info) == 0, info.st_mode & S_IFMT == S_IFSOCK else {
            throw SourcePreservingLANPrivilegedError.socketUnavailable(path)
        }
        guard info.st_uid == clientUID else {
            throw SourcePreservingLANPrivilegedError.socketOwnerMismatch(
                expected: clientUID,
                actual: info.st_uid
            )
        }
    }

    private static func writeAnchor(_ contents: String) throws {
        let bytes = Array(contents.utf8)
        let descriptor = open(Self.anchorPath, O_WRONLY | O_CREAT | O_TRUNC | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else {
            throw SourcePreservingLANPrivilegedError.commandFailed(
                "open \(Self.anchorPath): \(String(cString: strerror(errno)))"
            )
        }
        defer { close(descriptor) }
        var offset = 0
        while offset < bytes.count {
            let written = bytes.withUnsafeBytes { raw in
                Darwin.write(descriptor, raw.baseAddress?.advanced(by: offset), bytes.count - offset)
            }
            guard written > 0 else {
                throw SourcePreservingLANPrivilegedError.commandFailed(
                    "write \(Self.anchorPath): \(String(cString: strerror(errno)))"
                )
            }
            offset += written
        }
        guard fsync(descriptor) == 0 else {
            throw SourcePreservingLANPrivilegedError.commandFailed(
                "fsync \(Self.anchorPath): \(String(cString: strerror(errno)))"
            )
        }
    }

    private static func runCommand(_ command: [String]) throws -> String {
        do {
            return try DoryShell.run(command[0], Array(command.dropFirst()))
        } catch {
            throw SourcePreservingLANPrivilegedError.commandFailed(
                "\(command.joined(separator: " ")): \(error)"
            )
        }
    }
}
