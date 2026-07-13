import Foundation

public struct HostCLIInstallResult: Sendable, Equatable {
    public var linked: [String]
    public var missing: [String]
    public var pathProfileChanged: Bool
    public var composePluginInstalled: Bool
    public var buildxPluginInstalled: Bool
    public var dockerContextReconciled: Bool
    public var dockerContextError: String?

    public var dockerLinked: Bool {
        linked.contains("docker")
    }
}

public struct HostCLIRemoveResult: Sendable, Equatable {
    public var removed: [String]
    public var pathProfileChanged: Bool
    public var composePluginRemoved: Bool
    public var buildxPluginRemoved: Bool
}

/// Per-user terminal integration owned by doryd. When the daemon is running from the app bundle,
/// fresh terminals should already have Dory's docker, Compose, kubectl, dory, and support tools.
public typealias HostCLICommandRunner = @Sendable (_ executable: String, _ arguments: [String], _ environment: [String: String]) -> Int32

public struct HostCLIInstaller: Sendable {
    private static let beginSentinel = "# >>> dory cli >>>"
    private static let endSentinel = "# <<< dory cli <<<"
    private static let tools = ["docker", "docker-buildx", "docker-compose", "kubectl", "dory", "dory-doctor", "dorydctl"]
    private static let profiles = [".zprofile", ".zshrc", ".bash_profile", ".bashrc", ".profile"]
    private static let defaultProfiles = [".zprofile", ".zshrc"]

    public var home: String
    public var helpersDirectory: String?
    public var dockerSocketPath: String
    public var commandRunner: HostCLICommandRunner

    public init(
        home: String,
        helpersDirectory: String?,
        dockerSocketPath: String? = nil,
        commandRunner: HostCLICommandRunner? = nil
    ) {
        self.home = home
        self.helpersDirectory = helpersDirectory
        self.dockerSocketPath = dockerSocketPath ?? "\(home)/.dory/dory.sock"
        self.commandRunner = commandRunner ?? Self.runCommand
    }

    public init(
        environment: DorydEnvironment,
        dockerSocketPath: String? = nil,
        commandRunner: HostCLICommandRunner? = nil
    ) {
        self.home = environment.home
        self.helpersDirectory = Self.helpersDirectory(environment: environment)
        self.dockerSocketPath = dockerSocketPath ?? "\(environment.home)/.dory/dory.sock"
        self.commandRunner = commandRunner ?? Self.runCommand
    }

    @discardableResult
    public func install() -> HostCLIInstallResult {
        let fileManager = FileManager.default
        let binDir = "\(home)/.dory/bin"
        let composePluginDir = "\(home)/.docker/cli-plugins"
        var linked: [String] = []
        var missing: [String] = []
        var composePluginInstalled = false
        var buildxPluginInstalled = false

        try? fileManager.createDirectory(atPath: binDir, withIntermediateDirectories: true)
        try? fileManager.createDirectory(atPath: composePluginDir, withIntermediateDirectories: true)

        for tool in Self.tools {
            guard let source = sourcePath(for: tool) else {
                missing.append(tool)
                continue
            }
            // Only count a tool as linked once the symlink actually resolves to it, so a
            // broken/failed link is reported missing and self-heal can retry it.
            if symlink(source, to: "\(binDir)/\(tool)") {
                linked.append(tool)
            } else {
                missing.append(tool)
            }
            if tool == "docker-compose" {
                composePluginInstalled = installOwnedPluginSymlink(source, to: "\(composePluginDir)/docker-compose")
            } else if tool == "docker-buildx" {
                buildxPluginInstalled = installOwnedPluginSymlink(source, to: "\(composePluginDir)/docker-buildx")
            }
        }
        let dockerContext = reconcileDockerContext()

        return HostCLIInstallResult(
            linked: linked,
            missing: missing,
            pathProfileChanged: addToPath(),
            composePluginInstalled: composePluginInstalled,
            buildxPluginInstalled: buildxPluginInstalled,
            dockerContextReconciled: dockerContext.ok,
            dockerContextError: dockerContext.error
        )
    }

    @discardableResult
    public func remove() -> HostCLIRemoveResult {
        let fileManager = FileManager.default
        let binDir = "\(home)/.dory/bin"
        let composePlugin = "\(home)/.docker/cli-plugins/docker-compose"
        let buildxPlugin = "\(home)/.docker/cli-plugins/docker-buildx"
        var removed: [String] = []

        for tool in Self.tools {
            let path = "\(binDir)/\(tool)"
            if fileManager.fileExists(atPath: path) || (try? fileManager.destinationOfSymbolicLink(atPath: path)) != nil {
                try? fileManager.removeItem(atPath: path)
                removed.append(tool)
            }
        }

        let hadComposePlugin = removeOwnedPluginSymlink(at: composePlugin, desiredSource: sourcePath(for: "docker-compose"))
        let hadBuildxPlugin = removeOwnedPluginSymlink(at: buildxPlugin, desiredSource: sourcePath(for: "docker-buildx"))

        return HostCLIRemoveResult(
            removed: removed,
            pathProfileChanged: removeFromPath(),
            composePluginRemoved: hadComposePlugin,
            buildxPluginRemoved: hadBuildxPlugin
        )
    }

    public static func pathBlock(binDir: String) -> String {
        "\(beginSentinel)\nDORY_CLI_BIN=\"\(binDir)\"\ncase \":$PATH:\" in\n  *\":$DORY_CLI_BIN:\"*) ;;\n  *) export PATH=\"$DORY_CLI_BIN:$PATH\" ;;\nesac\n\(endSentinel)\n"
    }

    public static func appendingPathBlock(to content: String, binDir: String) -> String? {
        guard !content.contains(beginSentinel) else { return nil }
        let separator = content.isEmpty || content.hasSuffix("\n") ? "\n" : "\n\n"
        return content + separator + pathBlock(binDir: binDir)
    }

    public static func removingPathBlock(from content: String) -> String {
        guard content.contains(beginSentinel) else { return content }
        var output: [String] = []
        var skipping = false
        for line in content.components(separatedBy: "\n") {
            if line == beginSentinel {
                skipping = true
                continue
            }
            if line == endSentinel {
                skipping = false
                continue
            }
            if !skipping {
                output.append(line)
            }
        }
        return output.joined(separator: "\n")
    }

    private static func helpersDirectory(environment: DorydEnvironment) -> String? {
        let fileManager = FileManager.default
        if let explicit = environment.values["DORYD_HELPERS_DIR"], fileManager.fileExists(atPath: explicit) {
            return explicit
        }
        if let explicit = environment.values["DORY_HELPERS_DIR"], fileManager.fileExists(atPath: explicit) {
            return explicit
        }
        if !environment.executablePath.isEmpty {
            let executableURL = URL(fileURLWithPath: environment.executablePath)
            let directory = executableURL.deletingLastPathComponent().path
            if fileManager.fileExists(atPath: directory) {
                return directory
            }
            let bundleHelpers = executableURL
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("Helpers", isDirectory: true)
                .path
            if fileManager.fileExists(atPath: bundleHelpers) {
                return bundleHelpers
            }
        }
        for candidate in ["\(environment.cwd)/Helpers", "\(environment.cwd)/../Helpers"] where fileManager.fileExists(atPath: candidate) {
            return candidate
        }
        return nil
    }

    private func sourcePath(for tool: String) -> String? {
        guard let helpersDirectory else { return nil }
        let path = "\(helpersDirectory)/\(tool)"
        return FileManager.default.isExecutableFile(atPath: path) ? path : nil
    }

    private func installOwnedPluginSymlink(_ source: String, to destination: String) -> Bool {
        let fileManager = FileManager.default
        if let rawTarget = try? fileManager.destinationOfSymbolicLink(atPath: destination) {
            let target = resolvedSymlinkTarget(rawTarget, at: destination)
            if standardized(target) == standardized(source) { return true }
            guard isDoryOwnedPluginTarget(target, desiredSource: source) else { return false }
            do { try fileManager.removeItem(atPath: destination) } catch { return false }
        } else if fileManager.fileExists(atPath: destination) {
            return false
        }
        do {
            try fileManager.createSymbolicLink(atPath: destination, withDestinationPath: source)
            return true
        } catch {
            return false
        }
    }

    @discardableResult
    private func removeOwnedPluginSymlink(at destination: String, desiredSource: String?) -> Bool {
        let fileManager = FileManager.default
        guard let rawTarget = try? fileManager.destinationOfSymbolicLink(atPath: destination) else { return false }
        let target = resolvedSymlinkTarget(rawTarget, at: destination)
        guard isDoryOwnedPluginTarget(target, desiredSource: desiredSource) else { return false }
        do {
            try fileManager.removeItem(atPath: destination)
            return true
        } catch {
            return false
        }
    }

    private func isDoryOwnedPluginTarget(_ target: String, desiredSource: String?) -> Bool {
        let candidate = standardized(target)
        if let desiredSource, candidate == standardized(desiredSource) { return true }
        if isInside(candidate, root: standardized("\(home)/.dory")) { return true }
        if let helpersDirectory, isInside(candidate, root: standardized(helpersDirectory)) { return true }
        return false
    }

    private func resolvedSymlinkTarget(_ target: String, at destination: String) -> String {
        guard !target.hasPrefix("/") else { return target }
        return URL(fileURLWithPath: destination).deletingLastPathComponent()
            .appendingPathComponent(target).standardizedFileURL.path
    }

    private func standardized(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.path
    }

    private func isInside(_ path: String, root: String) -> Bool {
        path == root || path.hasPrefix(root + "/")
    }

    private func reconcileDockerContext() -> (ok: Bool, error: String?) {
        guard let docker = sourcePath(for: "docker") else {
            return (false, "docker helper is missing")
        }
        let host = "unix://\(dockerSocketPath)"
        let environment = dockerCommandEnvironment()
        let inspect = commandRunner(docker, ["context", "inspect", "dory"], environment)
        let configure: Int32
        if inspect == 0 {
            configure = commandRunner(docker, ["context", "update", "dory", "--docker", "host=\(host)"], environment)
        } else {
            configure = commandRunner(
                docker,
                ["context", "create", "dory", "--description", "Dory", "--docker", "host=\(host)"],
                environment
            )
        }
        guard configure == 0 else {
            return (false, "docker context \(inspect == 0 ? "update" : "create") failed with status \(configure)")
        }
        let use = commandRunner(docker, ["context", "use", "dory"], environment)
        guard use == 0 else {
            return (false, "docker context use failed with status \(use)")
        }
        return (true, nil)
    }

    private func dockerCommandEnvironment() -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        environment["HOME"] = home
        return environment
    }

    private static func runCommand(
        executable: String,
        arguments: [String],
        environment: [String: String]
    ) -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.environment = environment
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        do {
            try process.run()
        } catch {
            return 127
        }
        process.waitUntilExit()
        return process.terminationStatus
    }

    @discardableResult
    private func symlink(_ source: String, to destination: String) -> Bool {
        guard source != destination else { return true }
        let fileManager = FileManager.default
        if let existing = try? fileManager.destinationOfSymbolicLink(atPath: destination), existing == source {
            return true
        }
        try? fileManager.removeItem(atPath: destination)
        do {
            try fileManager.createSymbolicLink(atPath: destination, withDestinationPath: source)
        } catch {
            return false
        }
        return (try? fileManager.destinationOfSymbolicLink(atPath: destination)) == source
    }

    private func addToPath() -> Bool {
        let fileManager = FileManager.default
        let binDir = "\(home)/.dory/bin"
        var changed = false
        for name in Self.profiles {
            let path = "\(home)/\(name)"
            guard fileManager.fileExists(atPath: path),
                  let content = try? String(contentsOfFile: path, encoding: .utf8) else { continue }
            guard let updated = Self.appendingPathBlock(to: content, binDir: binDir) else { continue }
            if (try? updated.write(toFile: path, atomically: true, encoding: .utf8)) != nil {
                changed = true
            }
        }
        for name in Self.defaultProfiles where !fileManager.fileExists(atPath: "\(home)/\(name)") {
            if (try? Self.pathBlock(binDir: binDir).write(toFile: "\(home)/\(name)", atomically: true, encoding: .utf8)) != nil {
                changed = true
            }
        }
        return changed
    }

    private func removeFromPath() -> Bool {
        var changed = false
        for name in Self.profiles {
            let path = "\(home)/\(name)"
            guard let content = try? String(contentsOfFile: path, encoding: .utf8),
                  content.contains(Self.beginSentinel) else { continue }
            let stripped = Self.removingPathBlock(from: content)
            if (try? stripped.write(toFile: path, atomically: true, encoding: .utf8)) != nil {
                changed = true
            }
        }
        return changed
    }
}
