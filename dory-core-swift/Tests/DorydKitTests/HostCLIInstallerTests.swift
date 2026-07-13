@testable import DorydKit
import XCTest

final class HostCLIInstallerTests: XCTestCase {
    func testDorydStartupInstallerLinksBundledToolsAndComposePlugin() throws {
        let directory = "/tmp/doryd-cli-install-\(getpid())-\(UUID().uuidString)"
        let home = directory + "/home"
        let helpers = directory + "/Dory.app/Contents/Helpers"
        try FileManager.default.createDirectory(atPath: helpers, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: directory) }

        for tool in ["docker", "docker-buildx", "docker-compose", "kubectl", "dory", "dory-doctor", "dorydctl"] {
            _ = try executableFixture(at: helpers + "/\(tool)")
        }

        let result = HostCLIInstaller(home: home, helpersDirectory: helpers).install()

        XCTAssertTrue(result.dockerLinked)
        XCTAssertTrue(result.missing.isEmpty)
        XCTAssertTrue(result.composePluginInstalled)
        XCTAssertTrue(result.buildxPluginInstalled)
        XCTAssertTrue(result.dockerContextReconciled)
        XCTAssertNil(result.dockerContextError)
        XCTAssertTrue(FileManager.default.fileExists(atPath: home + "/.dory/bin/docker"))
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: home + "/.dory/bin/docker"), helpers + "/docker")
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: home + "/.docker/cli-plugins/docker-compose"), helpers + "/docker-compose")
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: home + "/.docker/cli-plugins/docker-buildx"), helpers + "/docker-buildx")
        let profile = try String(contentsOfFile: home + "/.zprofile", encoding: .utf8)
        XCTAssertTrue(profile.contains("DORY_CLI_BIN=\"\(home)/.dory/bin\""))
        XCTAssertTrue(FileManager.default.fileExists(atPath: home + "/.zshrc"))
    }

    func testInstallerIsIdempotent() throws {
        let directory = "/tmp/doryd-cli-idempotent-\(getpid())-\(UUID().uuidString)"
        let home = directory + "/home"
        let helpers = directory + "/Dory.app/Contents/Helpers"
        try FileManager.default.createDirectory(atPath: helpers, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: directory) }

        for tool in ["docker", "docker-buildx", "docker-compose", "kubectl", "dory", "dory-doctor", "dorydctl"] {
            _ = try executableFixture(at: helpers + "/\(tool)")
        }

        let installer = HostCLIInstaller(home: home, helpersDirectory: helpers)
        XCTAssertTrue(installer.install().pathProfileChanged)
        XCTAssertFalse(installer.install().pathProfileChanged)
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: home + "/.dory/bin/docker"), helpers + "/docker")
    }

    func testInstallerCreatesDockerContextForDorySocket() throws {
        let directory = "/tmp/doryd-cli-context-create-\(getpid())-\(UUID().uuidString)"
        let home = directory + "/home"
        let helpers = directory + "/Dory.app/Contents/Helpers"
        try FileManager.default.createDirectory(atPath: helpers, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: directory) }

        for tool in ["docker", "docker-buildx", "docker-compose", "kubectl", "dory", "dory-doctor", "dorydctl"] {
            _ = try executableFixture(at: helpers + "/\(tool)")
        }
        let recorder = HostCLICommandRecorder(inspectStatus: 1)

        let result = HostCLIInstaller(
            home: home,
            helpersDirectory: helpers,
            dockerSocketPath: home + "/.dory/dory.sock",
            commandRunner: recorder.run
        ).install()

        XCTAssertTrue(result.dockerContextReconciled)
        XCTAssertEqual(recorder.calls.map(\.arguments), [
            ["context", "inspect", "dory"],
            ["context", "create", "dory", "--description", "Dory", "--docker", "host=unix://\(home)/.dory/dory.sock"],
            ["context", "use", "dory"],
        ])
        XCTAssertEqual(recorder.calls.first?.environment["HOME"], home)
    }

    func testInstallerUpdatesExistingDockerContextForDorySocket() throws {
        let directory = "/tmp/doryd-cli-context-update-\(getpid())-\(UUID().uuidString)"
        let home = directory + "/home"
        let helpers = directory + "/Dory.app/Contents/Helpers"
        try FileManager.default.createDirectory(atPath: helpers, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: directory) }

        for tool in ["docker", "docker-buildx", "docker-compose", "kubectl", "dory", "dory-doctor", "dorydctl"] {
            _ = try executableFixture(at: helpers + "/\(tool)")
        }
        let recorder = HostCLICommandRecorder(inspectStatus: 0)

        let result = HostCLIInstaller(
            home: home,
            helpersDirectory: helpers,
            dockerSocketPath: home + "/.dory/dory.sock",
            commandRunner: recorder.run
        ).install()

        XCTAssertTrue(result.dockerContextReconciled)
        XCTAssertEqual(recorder.calls.map(\.arguments), [
            ["context", "inspect", "dory"],
            ["context", "update", "dory", "--docker", "host=unix://\(home)/.dory/dory.sock"],
            ["context", "use", "dory"],
        ])
    }

    func testInstallerFindsBundleHelpersFromDorydExecutable() throws {
        let directory = "/tmp/doryd-cli-env-\(getpid())-\(UUID().uuidString)"
        let home = directory + "/home"
        let helpers = directory + "/Dory.app/Contents/Helpers"
        try FileManager.default.createDirectory(atPath: helpers, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: directory) }

        let doryd = try executableFixture(at: helpers + "/doryd")
        for tool in ["docker", "docker-buildx", "docker-compose", "kubectl", "dory", "dory-doctor", "dorydctl"] {
            _ = try executableFixture(at: helpers + "/\(tool)")
        }

        let environment = DorydEnvironment(values: ["DORYD_HOME": home], cwd: directory, executablePath: doryd)
        let result = HostCLIInstaller(environment: environment).install()

        XCTAssertTrue(result.dockerLinked)
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: home + "/.dory/bin/dorydctl"), helpers + "/dorydctl")
    }

    func testPathBlockAppendIsIdempotent() throws {
        let once = try XCTUnwrap(HostCLIInstaller.appendingPathBlock(to: "export FOO=1\n", binDir: "/home/u/.dory/bin"))
        XCTAssertNil(HostCLIInstaller.appendingPathBlock(to: once, binDir: "/home/u/.dory/bin"))
        XCTAssertTrue(once.contains("case \":$PATH:\" in"))
        XCTAssertTrue(once.contains("DORY_CLI_BIN=\"/home/u/.dory/bin\""))
    }

    func testInstallerCreatesLoginAndInteractiveZshProfilesForCleanHome() throws {
        let directory = "/tmp/doryd-cli-zsh-profiles-\(getpid())-\(UUID().uuidString)"
        let home = directory + "/home"
        let helpers = directory + "/Dory.app/Contents/Helpers"
        try FileManager.default.createDirectory(atPath: helpers, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: directory) }

        for tool in ["docker", "docker-buildx", "docker-compose", "kubectl", "dory", "dory-doctor", "dorydctl"] {
            _ = try executableFixture(at: helpers + "/\(tool)")
        }

        let result = HostCLIInstaller(home: home, helpersDirectory: helpers).install()

        XCTAssertTrue(result.pathProfileChanged)
        for profile in [".zprofile", ".zshrc"] {
            let content = try String(contentsOfFile: home + "/\(profile)", encoding: .utf8)
            XCTAssertTrue(content.contains("DORY_CLI_BIN=\"\(home)/.dory/bin\""), profile)
            XCTAssertTrue(content.contains("case \":$PATH:\" in"), profile)
        }
    }

    func testRemoveUnlinksToolsComposePluginAndPathBlock() throws {
        let directory = "/tmp/doryd-cli-remove-\(getpid())-\(UUID().uuidString)"
        let home = directory + "/home"
        let helpers = directory + "/Dory.app/Contents/Helpers"
        try FileManager.default.createDirectory(atPath: helpers, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: directory) }

        for tool in ["docker", "docker-buildx", "docker-compose", "kubectl", "dory", "dory-doctor", "dorydctl"] {
            _ = try executableFixture(at: helpers + "/\(tool)")
        }

        let installer = HostCLIInstaller(home: home, helpersDirectory: helpers)
        XCTAssertTrue(installer.install().dockerLinked)

        let result = installer.remove()

        XCTAssertTrue(result.removed.contains("docker"))
        XCTAssertTrue(result.composePluginRemoved)
        XCTAssertTrue(result.buildxPluginRemoved)
        XCTAssertTrue(result.pathProfileChanged)
        XCTAssertFalse(FileManager.default.fileExists(atPath: home + "/.dory/bin/docker"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: home + "/.docker/cli-plugins/docker-compose"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: home + "/.docker/cli-plugins/docker-buildx"))
        let profile = try String(contentsOfFile: home + "/.zprofile", encoding: .utf8)
        XCTAssertFalse(profile.contains("dory cli"))
    }

    func testReconcilerRestoresMissingLinks() throws {
        let directory = "/tmp/doryd-cli-reconcile-\(getpid())-\(UUID().uuidString)"
        let home = directory + "/home"
        let helpers = directory + "/Dory.app/Contents/Helpers"
        try FileManager.default.createDirectory(atPath: helpers, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: directory) }

        for tool in ["docker", "docker-buildx", "docker-compose", "kubectl", "dory", "dory-doctor", "dorydctl"] {
            _ = try executableFixture(at: helpers + "/\(tool)")
        }

        let reconciler = HostCLIReconciler(
            installer: HostCLIInstaller(home: home, helpersDirectory: helpers),
            interval: 30
        )
        XCTAssertTrue(reconciler.reconcileNow().dockerLinked)
        try FileManager.default.removeItem(atPath: home + "/.dory/bin/docker")

        XCTAssertTrue(reconciler.reconcileNow().dockerLinked)

        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: home + "/.dory/bin/docker"), helpers + "/docker")
    }

    func testInstallerNeverReplacesUnownedDockerPlugins() throws {
        let directory = "/tmp/doryd-cli-plugin-ownership-\(getpid())-\(UUID().uuidString)"
        let home = directory + "/home"
        let helpers = directory + "/Dory.app/Contents/Helpers"
        let plugins = home + "/.docker/cli-plugins"
        try FileManager.default.createDirectory(atPath: helpers, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: plugins, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: directory) }

        for tool in ["docker", "docker-buildx", "docker-compose", "kubectl", "dory", "dory-doctor", "dorydctl"] {
            _ = try executableFixture(at: helpers + "/\(tool)")
        }
        try "user-compose\n".write(toFile: plugins + "/docker-compose", atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(
            atPath: plugins + "/docker-buildx",
            withDestinationPath: "/opt/homebrew/lib/docker/cli-plugins/docker-buildx"
        )

        let installer = HostCLIInstaller(home: home, helpersDirectory: helpers)
        let result = installer.install()

        XCTAssertFalse(result.composePluginInstalled)
        XCTAssertFalse(result.buildxPluginInstalled)
        XCTAssertEqual(try String(contentsOfFile: plugins + "/docker-compose", encoding: .utf8), "user-compose\n")
        XCTAssertEqual(
            try FileManager.default.destinationOfSymbolicLink(atPath: plugins + "/docker-buildx"),
            "/opt/homebrew/lib/docker/cli-plugins/docker-buildx"
        )

        let removal = installer.remove()
        XCTAssertFalse(removal.composePluginRemoved)
        XCTAssertFalse(removal.buildxPluginRemoved)
        XCTAssertTrue(FileManager.default.fileExists(atPath: plugins + "/docker-compose"))
        XCTAssertEqual(
            try FileManager.default.destinationOfSymbolicLink(atPath: plugins + "/docker-buildx"),
            "/opt/homebrew/lib/docker/cli-plugins/docker-buildx"
        )
    }

    private func executableFixture(at path: String) throws -> String {
        try "#!/bin/sh\nexit 0\n".write(toFile: path, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path)
        return path
    }
}

private final class HostCLICommandRecorder: @unchecked Sendable {
    struct Call: Equatable {
        var executable: String
        var arguments: [String]
        var environment: [String: String]
    }

    private let lock = NSLock()
    private let inspectStatus: Int32
    private var recorded: [Call] = []

    init(inspectStatus: Int32) {
        self.inspectStatus = inspectStatus
    }

    var calls: [Call] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }

    func run(executable: String, arguments: [String], environment: [String: String]) -> Int32 {
        lock.lock()
        recorded.append(Call(executable: executable, arguments: arguments, environment: environment))
        lock.unlock()
        if arguments == ["context", "inspect", "dory"] {
            return inspectStatus
        }
        return 0
    }
}
