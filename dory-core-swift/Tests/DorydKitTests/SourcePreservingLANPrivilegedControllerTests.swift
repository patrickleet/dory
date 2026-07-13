@testable import DorydKit
import Darwin
import DoryCore
import XCTest

final class SourcePreservingLANPrivilegedControllerTests: XCTestCase {
    func testPFEnableTokenParsesExactMacOSUnsignedDecimalFormat() {
        XCTAssertEqual(
            SourcePreservingLANPrivilegedController.pfEnableToken(
                from: "pf enabled\nToken : 18446744073709551615\n"
            ),
            "18446744073709551615"
        )
        XCTAssertEqual(
            SourcePreservingLANPrivilegedController.pfEnableToken(
                from: "warning on stderr\n  Token : 42  \n"
            ),
            "42"
        )
    }

    func testPFEnableTokenRejectsMissingMalformedSignedOrHexTokens() {
        XCTAssertNil(SourcePreservingLANPrivilegedController.pfEnableToken(from: "pf enabled\n"))
        XCTAssertNil(SourcePreservingLANPrivilegedController.pfEnableToken(from: "Token : -1\n"))
        XCTAssertNil(SourcePreservingLANPrivilegedController.pfEnableToken(from: "Token : 0x2a\n"))
        XCTAssertNil(SourcePreservingLANPrivilegedController.pfEnableToken(from: "Token: 42\n"))
    }

    func testActivationConfiguresOwnedTunnelRouteAndDestinationOnlyPF() throws {
        let socketPath = try makeDatagramSocket()
        defer { unlink(socketPath) }
        let recorder = Recorder()
        let bridge = FakeBridge(interfaceName: "utun42")
        let controller = SourcePreservingLANPrivilegedController(
            enforceRoot: false,
            runtimeDirectory: "/tmp/dory-source-lan-runtime-\(getpid())-a",
            bridgeFactory: { configuration in
                recorder.configuration = configuration
                return bridge
            },
            runCommand: { command in recorder.run(command) },
            writeAnchor: { recorder.anchors.append($0) }
        )
        let request = SourcePreservingLANRequest(
            operation: .activate,
            sessionID: "engine-1",
            gvproxySocketPath: socketPath,
            bindings: [
                PublishedPortBinding(protocol: .tcp, port: 8080),
                PublishedPortBinding(protocol: .tcp, port: 9000, hostIP: "127.0.0.1"),
            ]
        )

        let response = try controller.apply(request, clientUID: getuid())

        XCTAssertEqual(response.status, "active")
        XCTAssertEqual(response.interfaceName, "utun42")
        XCTAssertEqual(response.lanBindingCount, 1)
        XCTAssertEqual(recorder.configuration?.subnetCIDR, "192.168.215.254/32")
        XCTAssertEqual(recorder.configuration?.gateway, "192.168.215.253")
        XCTAssertEqual(recorder.configuration?.gvproxySocketPath, socketPath)
        XCTAssertTrue(bridge.started)
        XCTAssertTrue(recorder.commands.contains([
            "/sbin/ifconfig", "utun42", "inet", "192.168.215.253", "192.168.215.254",
            "netmask", "255.255.255.255", "mtu", "1500", "up",
        ]))
        XCTAssertTrue(recorder.commands.contains([
            "/sbin/route", "-n", "add", "-host", "192.168.215.254", "-interface", "utun42",
        ]))
        XCTAssertTrue(recorder.commands.contains([
            "/usr/sbin/sysctl", "-w", "net.inet.ip.forwarding=1",
        ]))
        XCTAssertEqual(recorder.commands.suffix(2).first, [
            "/sbin/pfctl", "-a", "com.apple/dev.dory.lan", "-f", "/etc/pf.anchors/dev.dory.lan",
        ])
        XCTAssertEqual(recorder.commands.last, ["/sbin/pfctl", "-E"])
        XCTAssertTrue(recorder.anchors.last?.contains("to self port 8080 -> 192.168.215.254 port 8080") == true)
        XCTAssertFalse(recorder.anchors.last?.contains("9000") == true)
    }

    func testRefreshAndDeactivateAreBoundToTheActiveSession() throws {
        let socketPath = try makeDatagramSocket()
        defer { unlink(socketPath) }
        let recorder = Recorder()
        let bridge = FakeBridge(interfaceName: "utun7")
        let controller = SourcePreservingLANPrivilegedController(
            enforceRoot: false,
            runtimeDirectory: "/tmp/dory-source-lan-runtime-\(getpid())-b",
            bridgeFactory: { _ in bridge },
            runCommand: { command in recorder.run(command) },
            writeAnchor: { recorder.anchors.append($0) }
        )
        _ = try controller.apply(SourcePreservingLANRequest(
            operation: .activate,
            sessionID: "engine-a",
            gvproxySocketPath: socketPath
        ), clientUID: getuid())

        XCTAssertThrowsError(try controller.apply(SourcePreservingLANRequest(
            operation: .refresh,
            sessionID: "engine-b"
        ), clientUID: getuid())) { error in
            XCTAssertEqual(error as? SourcePreservingLANPrivilegedError, .noActiveSession)
        }

        let refreshed = try controller.apply(SourcePreservingLANRequest(
            operation: .refresh,
            sessionID: "engine-a",
            bindings: [PublishedPortBinding(protocol: .udp, port: 5353)]
        ), clientUID: getuid())
        XCTAssertEqual(refreshed.lanBindingCount, 1)
        XCTAssertTrue(recorder.anchors.last?.contains("proto udp") == true)

        let stopped = try controller.apply(SourcePreservingLANRequest(
            operation: .deactivate,
            sessionID: "engine-a"
        ), clientUID: getuid())
        XCTAssertEqual(stopped.status, "stopped")
        XCTAssertTrue(bridge.stopped)
        XCTAssertEqual(recorder.anchors.last, "# Managed by Dory. Do not edit.\n")
        XCTAssertTrue(recorder.commands.contains([
            "/sbin/pfctl", "-a", "com.apple/dev.dory.lan", "-F", "all",
        ]))
        XCTAssertTrue(recorder.commands.contains(["/sbin/pfctl", "-X", "424242"]))
        XCTAssertEqual(recorder.commands.last, [
            "/usr/sbin/sysctl", "-w", "net.inet.ip.forwarding=0",
        ])
    }

    func testRepeatedActivationForSameSessionIsIdempotentAndRefreshesBindings() throws {
        let socketPath = try makeDatagramSocket()
        defer { unlink(socketPath) }
        let recorder = Recorder()
        let bridge = FakeBridge(interfaceName: "utun9")
        let controller = SourcePreservingLANPrivilegedController(
            enforceRoot: false,
            runtimeDirectory: "/tmp/dory-source-lan-runtime-\(getpid())-idempotent",
            bridgeFactory: { _ in
                recorder.bridgeCreations += 1
                return bridge
            },
            runCommand: { command in recorder.run(command) },
            writeAnchor: { recorder.anchors.append($0) }
        )
        _ = try controller.apply(SourcePreservingLANRequest(
            operation: .activate,
            sessionID: "engine-recovery",
            gvproxySocketPath: socketPath
        ), clientUID: getuid())

        let recovered = try controller.apply(SourcePreservingLANRequest(
            operation: .activate,
            sessionID: "engine-recovery",
            gvproxySocketPath: socketPath,
            bindings: [PublishedPortBinding(protocol: .tcp, port: 8088)]
        ), clientUID: getuid())

        XCTAssertEqual(recorder.bridgeCreations, 1)
        XCTAssertEqual(recovered.status, "active")
        XCTAssertEqual(recovered.interfaceName, "utun9")
        XCTAssertEqual(recovered.lanBindingCount, 1)
        XCTAssertTrue(recorder.anchors.last?.contains("port 8088") == true)
    }

    func testRejectsForeignOwnedOrNonSocketGVProxyPath() throws {
        let path = "/tmp/dory-source-lan-regular-\(getpid())-\(UUID().uuidString)"
        FileManager.default.createFile(atPath: path, contents: Data())
        defer { unlink(path) }
        let controller = SourcePreservingLANPrivilegedController(
            enforceRoot: false,
            runtimeDirectory: "/tmp/dory-source-lan-runtime-\(getpid())-c",
            bridgeFactory: { _ in FakeBridge(interfaceName: "utun1") },
            runCommand: { _ in "" },
            writeAnchor: { _ in }
        )
        XCTAssertThrowsError(try controller.apply(SourcePreservingLANRequest(
            operation: .activate,
            sessionID: "engine",
            gvproxySocketPath: path
        ), clientUID: getuid())) { error in
            XCTAssertEqual(error as? SourcePreservingLANPrivilegedError, .socketUnavailable(path))
        }
    }

    func testBridgeFailureFlushesPFAndAllowsSessionRecovery() throws {
        let socketPath = try makeDatagramSocket()
        defer { unlink(socketPath) }
        let recorder = Recorder()
        let first = FakeBridge(interfaceName: "utun11")
        let second = FakeBridge(interfaceName: "utun12")
        let bridges = [first, second]
        let controller = SourcePreservingLANPrivilegedController(
            enforceRoot: false,
            runtimeDirectory: "/tmp/dory-source-lan-runtime-\(getpid())-failure",
            bridgeFactory: { _ in
                let bridge = bridges[recorder.bridgeCreations]
                recorder.bridgeCreations += 1
                return bridge
            },
            runCommand: { command in recorder.run(command) },
            writeAnchor: { recorder.anchors.append($0) }
        )
        let activation = SourcePreservingLANRequest(
            operation: .activate,
            sessionID: "engine-failure",
            gvproxySocketPath: socketPath,
            bindings: [PublishedPortBinding(protocol: .tcp, port: 8080)]
        )
        _ = try controller.apply(activation, clientUID: getuid())

        first.fail("fixture disconnect")

        XCTAssertTrue(first.stopped)
        XCTAssertEqual(recorder.anchors.last, "# Managed by Dory. Do not edit.\n")
        XCTAssertTrue(recorder.commands.contains([
            "/sbin/pfctl", "-a", "com.apple/dev.dory.lan", "-F", "all",
        ]))
        XCTAssertTrue(recorder.commands.contains(["/sbin/pfctl", "-X", "424242"]))
        XCTAssertEqual(recorder.commands.last, [
            "/usr/sbin/sysctl", "-w", "net.inet.ip.forwarding=0",
        ])
        XCTAssertThrowsError(try controller.apply(SourcePreservingLANRequest(
            operation: .refresh,
            sessionID: "engine-failure"
        ), clientUID: getuid()))

        let recovered = try controller.apply(activation, clientUID: getuid())
        XCTAssertEqual(recovered.interfaceName, "utun12")
        XCTAssertEqual(recorder.bridgeCreations, 2)
    }

    func testDaemonRestartReleasesPersistedPFReferenceAndFlushesStaleRules() throws {
        let runtime = "/tmp/dory-source-lan-runtime-\(getpid())-stale-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: runtime, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: runtime) }
        try "777777\n".write(
            toFile: runtime + "/pf-enable-token",
            atomically: true,
            encoding: .utf8
        )
        try "restore=0\n".write(
            toFile: runtime + "/ipv4-forwarding-owner",
            atomically: true,
            encoding: .utf8
        )
        let recorder = Recorder()
        let controller = SourcePreservingLANPrivilegedController(
            enforceRoot: false,
            runtimeDirectory: runtime,
            bridgeFactory: { _ in FakeBridge(interfaceName: "utun1") },
            runCommand: { command in recorder.run(command) },
            writeAnchor: { recorder.anchors.append($0) }
        )

        controller.clearStaleAnchor()

        XCTAssertEqual(recorder.anchors.last, "# Managed by Dory. Do not edit.\n")
        XCTAssertTrue(recorder.commands.contains([
            "/sbin/pfctl", "-a", "com.apple/dev.dory.lan", "-F", "all",
        ]))
        XCTAssertTrue(recorder.commands.contains(["/sbin/pfctl", "-X", "777777"]))
        XCTAssertEqual(recorder.commands.last, [
            "/usr/sbin/sysctl", "-w", "net.inet.ip.forwarding=0",
        ])
        XCTAssertFalse(FileManager.default.fileExists(atPath: runtime + "/pf-enable-token"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: runtime + "/ipv4-forwarding-owner"))
    }

    func testPreEnabledIPv4ForwardingIsNotClaimedOrDisabled() throws {
        let socketPath = try makeDatagramSocket()
        defer { unlink(socketPath) }
        let runtime = "/tmp/dory-source-lan-runtime-\(getpid())-preenabled-\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(atPath: runtime) }
        let recorder = Recorder()
        recorder.forwardingValue = "1"
        let bridge = FakeBridge(interfaceName: "utun18")
        let controller = SourcePreservingLANPrivilegedController(
            enforceRoot: false,
            runtimeDirectory: runtime,
            bridgeFactory: { _ in bridge },
            runCommand: { command in recorder.run(command) },
            writeAnchor: { recorder.anchors.append($0) }
        )
        _ = try controller.apply(SourcePreservingLANRequest(
            operation: .activate,
            sessionID: "engine-forwarding",
            gvproxySocketPath: socketPath
        ), clientUID: getuid())
        _ = try controller.apply(SourcePreservingLANRequest(
            operation: .deactivate,
            sessionID: "engine-forwarding"
        ), clientUID: getuid())

        XCTAssertFalse(recorder.commands.contains([
            "/usr/sbin/sysctl", "-w", "net.inet.ip.forwarding=1",
        ]))
        XCTAssertFalse(recorder.commands.contains([
            "/usr/sbin/sysctl", "-w", "net.inet.ip.forwarding=0",
        ]))
        XCTAssertEqual(recorder.forwardingValue, "1")
    }

    private func makeDatagramSocket() throws -> String {
        let path = "/tmp/dory-source-lan-\(getpid())-\(UUID().uuidString).sock"
        let descriptor = socket(AF_UNIX, SOCK_DGRAM, 0)
        guard descriptor >= 0 else { throw POSIXError(.ENOTSOCK) }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8) + [0]
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: bytes) }
        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        close(descriptor)
        guard result == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EINVAL) }
        return path
    }
}

private final class Recorder: @unchecked Sendable {
    var configuration: DirectIPBridgeConfiguration?
    var commands = [[String]]()
    var anchors = [String]()
    var bridgeCreations = 0
    var forwardingValue = "0"

    func run(_ command: [String]) -> String {
        commands.append(command)
        if command == ["/sbin/pfctl", "-E"] { return "pf enabled\nToken : 424242\n" }
        if command == ["/usr/sbin/sysctl", "-n", "net.inet.ip.forwarding"] {
            return forwardingValue + "\n"
        }
        if command == ["/usr/sbin/sysctl", "-w", "net.inet.ip.forwarding=1"] {
            forwardingValue = "1"
        } else if command == ["/usr/sbin/sysctl", "-w", "net.inet.ip.forwarding=0"] {
            forwardingValue = "0"
        }
        return ""
    }
}

private final class FakeBridge: SourcePreservingLANBridgeSession, @unchecked Sendable {
    let activeInterfaceName: String?
    var started = false
    var stopped = false
    var isHealthy = true
    private var failureHandler: (@Sendable (String) -> Void)?

    init(interfaceName: String?) { self.activeInterfaceName = interfaceName }
    func start() throws { started = true }
    func stop() { stopped = true; isHealthy = false }
    func setFailureHandler(_ handler: @escaping @Sendable (String) -> Void) {
        failureHandler = handler
    }
    func fail(_ detail: String) {
        isHealthy = false
        failureHandler?(detail)
    }
}
