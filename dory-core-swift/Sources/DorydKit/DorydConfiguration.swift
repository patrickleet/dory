import Darwin
import Foundation

public struct DorydEnvironment: Sendable {
    public var values: [String: String]
    public var home: String
    public var cwd: String
    public var executablePath: String

    public init(
        values: [String: String] = ProcessInfo.processInfo.environment,
        home: String? = nil,
        cwd: String = FileManager.default.currentDirectoryPath,
        executablePath: String = ProcessInfo.processInfo.arguments.first ?? ""
    ) {
        self.values = values
        self.home = home ?? values["DORYD_HOME"] ?? NSHomeDirectory()
        self.cwd = cwd
        self.executablePath = executablePath
    }

    public func dockerTierConfiguration() -> DockerTierConfiguration? {
        guard bool("DORYD_DOCKER_TIER", default: true) else { return nil }

        let stateDirectory = string("DORYD_STATE_DIR") ?? "\(home)/.dory/hv"
        let forwardSocket = string("DORYD_AGENT_VSOCK_FORWARD")
            ?? string("DORY_AGENT_VSOCK_FORWARD")
            ?? "\(stateDirectory)/agent-vsock-forward.sock"
        let cid = uint32("DORYD_GUEST_CID") ?? 3

        let explicitForward = string("DORYD_AGENT_VSOCK_FORWARD") != nil
            || string("DORY_AGENT_VSOCK_FORWARD") != nil
        let hvProcess = rawHVSupported ? hvProcessConfiguration(
            stateDirectory: stateDirectory,
            forwardSocket: forwardSocket
        ) : nil

        if hvProcess == nil, !explicitForward,
           let vmmProcess = vmmDockerProcessConfiguration(stateDirectory: stateDirectory) {
            let dockerdSocket = "\(stateDirectory)/dockerd.sock"
            let agentSocket = "\(stateDirectory)/agent.sock"
            return DockerTierConfiguration(
                home: home,
                forwardSocketPath: forwardSocket,
                dockerdSocketPath: dockerdSocket,
                cid: cid,
                dockerPort: uint32("DORYD_DOCKER_PORT") ?? 1026,
                gpuSupported: false,
                activitySocketPath: string("DORYD_ACTIVITY_SOCK")
                    ?? "\(stateDirectory)/dataplane-activity.sock",
                vmmProcess: vmmProcess,
                agentControl: bool("DORYD_AGENT_CONTROL", default: true)
                    ? AgentControlConfiguration(directSocketPath: agentSocket)
                    : nil
            )
        }

        if hvProcess == nil, !explicitForward {
            return nil
        }

        return DockerTierConfiguration(
            home: home,
            forwardSocketPath: forwardSocket,
            cid: cid,
            dockerPort: uint32("DORYD_DOCKER_PORT") ?? 1026,
            gpuSupported: bool("DORYD_GPU_SUPPORTED", default: false)
                || string("DORYD_GPU") == "venus"
                || string("DORY_EXPERIMENTAL_GPU") == "venus",
            activitySocketPath: string("DORYD_ACTIVITY_SOCK")
                ?? "\(stateDirectory)/dataplane-activity.sock",
            hvProcess: hvProcess,
            agentControl: bool("DORYD_AGENT_CONTROL", default: true)
                ? AgentControlConfiguration(forwardSocketPath: forwardSocket, cid: cid)
                : nil
        )
    }

    public func networkingConfiguration() -> NetworkingConfiguration? {
        guard bool("DORYD_NETWORKING", default: false) || string("DORYD_DNS_PORT") != nil else {
            return nil
        }
        return NetworkingConfiguration(
            suffix: string("DORYD_DOMAIN_SUFFIX") ?? "dory.local",
            dnsBindAddress: string("DORYD_DNS_BIND") ?? "127.0.0.1",
            dnsPort: uint16("DORYD_DNS_PORT") ?? 1053,
            httpProxyPort: uint16("DORYD_HTTP_PROXY_PORT") ?? 8080,
            httpsProxyPort: uint16("DORYD_HTTPS_PROXY_PORT") ?? 8443,
            privilegedTCPForwards: privilegedTCPForwards(),
            localCACertificatePath: string("DORYD_CA_CERT") ?? "\(home)/.dory/ca/ca.crt"
        )
    }

    public func idleSleepConfiguration() -> IdleSleepConfiguration? {
        guard bool("DORYD_IDLE_SLEEP", default: true) else { return nil }
        let idleAfter = double("DORYD_IDLE_SLEEP_AFTER_SECONDS")
            ?? double("DORYD_IDLE_AFTER_SECONDS")
            ?? 300
        guard idleAfter > 0 else { return nil }
        let checkInterval = double("DORYD_IDLE_CHECK_INTERVAL_SECONDS")
            ?? min(30, max(5, idleAfter / 5))
        return IdleSleepConfiguration(
            enabled: true,
            idleAfterSeconds: idleAfter,
            checkIntervalSeconds: checkInterval
        )
    }

    public var hostCLIEnabled: Bool {
        bool("DORYD_HOST_CLI", default: true)
    }

    public var hostCLIReconcileIntervalSeconds: TimeInterval {
        max(30, double("DORYD_HOST_CLI_RECONCILE_SECONDS") ?? 300)
    }

    public var networkRouteReconcileIntervalSeconds: TimeInterval {
        max(1, double("DORYD_NETWORK_ROUTE_RECONCILE_SECONDS") ?? 5)
    }

    public func kubernetesServiceRouteProviderConfiguration() -> KubernetesServiceRouteProviderConfiguration {
        KubernetesServiceRouteProviderConfiguration(
            home: home,
            kubectlPath: hostToolPath(named: "kubectl"),
            kubeconfigPath: string("DORYD_KUBECONFIG")
                ?? string("DORY_KUBECONFIG")
                ?? "\(home)/.kube/dory-config",
            proxyPort: uint16("DORYD_KUBE_PROXY_PORT") ?? 18_001
        )
    }

    public func hostToolPath(named name: String) -> String? {
        let envName = name.uppercased().replacingOccurrences(of: "-", with: "_")
        let explicitKeys = ["DORYD_\(envName)_BIN", "DORY_\(envName)_BIN"]
        if let explicit = executablePath(firstOf: explicitKeys, fallbackCandidates: []) {
            return explicit
        }
        let candidates = ["\(home)/.dory/bin/\(name)"] + helperCandidates(named: name)
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    public func machineManagerConfiguration() -> MachineManagerConfiguration? {
        guard let helper = executablePath(firstOf: ["DORYD_VMM_HELPER", "DORY_VMM_HELPER"], fallbackCandidates: helperCandidates(named: "dory-vmm")) else {
            return nil
        }
        let stateDirectory = string("DORYD_MACHINE_STATE_DIR") ?? "\(home)/.dory/machines"
        return MachineManagerConfiguration(
            vmmExecutablePath: helper,
            stateDirectory: stateDirectory,
            baseArguments: splitArguments(string("DORYD_VMM_ARGS") ?? ""),
            passMachineArguments: bool("DORYD_VMM_PASS_MACHINE_ARGS", default: true),
            logDirectory: string("DORYD_MACHINE_LOG_DIR") ?? "\(stateDirectory)/logs",
            requiresReadyHandoff: bool("DORYD_VMM_READY_HANDOFF", default: true)
        )
    }

    private func hvProcessConfiguration(
        stateDirectory: String,
        forwardSocket: String
    ) -> HvProcessConfiguration? {
        guard let helper = executablePath(firstOf: ["DORYD_HV_HELPER", "DORY_HV_HELPER"], fallbackCandidates: helperCandidates(named: "dory-hv")),
              let kernel = existingPath(firstOf: ["DORYD_HV_KERNEL", "DORY_HV_KERNEL"])
                ?? bundledResource(named: ["dory-hv-kernel-\(hostGuestArch)", "dory-hv-kernel"]),
              let gvproxy = executablePath(firstOf: ["DORYD_GVPROXY", "DORY_GVPROXY"], fallbackCandidates: gvproxyCandidates()) else {
            return nil
        }

        let legacyEngineSocket = string("DORYD_HV_ENGINE_SOCK") ?? "\(stateDirectory)/engine.sock"
        var arguments = [
            "engine",
            "--engine-sock", legacyEngineSocket,
            "--agent-vsock-forward", forwardSocket,
            "--kernel", kernel,
            "--gvproxy", gvproxy,
            "--state-dir", stateDirectory,
            "--mem-mb", String(int("DORYD_MEMORY_MB") ?? 2048),
            "--cpus", String(int("DORYD_CPUS") ?? 4),
        ]

        if bool("DORYD_DIRECT_IP", default: true) {
            arguments.append("--direct-ip")
        }
        let engineRootfs = existingPath(firstOf: ["DORYD_ENGINE_ROOTFS", "DORY_ENGINE_ROOTFS"])
            ?? preparedBundledCompressedResource(
                named: ["dory-engine-rootfs-\(hostGuestArch).ext4", "dory-engine-rootfs.ext4"],
                outputName: "dory-engine-rootfs-\(hostGuestArch).ext4",
                stateDirectory: stateDirectory
            )
        if let rootfs = engineRootfs {
            arguments.append(contentsOf: ["--rootfs", rootfs])
        } else if bool("DORYD_REQUIRE_ENGINE_ROOTFS", default: false) {
            return nil
        }
        if string("DORYD_GPU") == "venus" || string("DORY_EXPERIMENTAL_GPU") == "venus" {
            arguments.append(contentsOf: ["--gpu", "venus"])
        }
        if bool("DORYD_AMD64", default: hostGuestArch == "arm64") {
            arguments.append("--amd64")
        }
        if string("DORYD_PUBLISH_HOST") == "0.0.0.0" {
            arguments.append(contentsOf: ["--publish-host", "0.0.0.0"])
        }
        for share in shares() {
            arguments.append(contentsOf: ["--share", share])
        }

        return HvProcessConfiguration(
            executablePath: helper,
            arguments: arguments,
            logPath: string("DORYD_HV_LOG") ?? "\(stateDirectory)/dory-hv.log",
            restartPolicy: HvRestartPolicy(
                maxRestarts: int("DORYD_HV_RESTART_LIMIT") ?? 3,
                delaySeconds: double("DORYD_HV_RESTART_DELAY") ?? 0.5
            )
        )
    }

    private func vmmDockerProcessConfiguration(stateDirectory: String) -> VmmDockerProcessConfiguration? {
        guard let helper = executablePath(firstOf: ["DORYD_VMM_HELPER", "DORY_VMM_HELPER"], fallbackCandidates: helperCandidates(named: "dory-vmm")),
              let kernel = existingPath(firstOf: ["DORYD_VMM_KERNEL", "DORY_VMM_KERNEL"])
                ?? preparedBundledCompressedResource(
                    named: ["dory-vm-kernel-\(hostGuestArch)", "dory-vm-kernel"],
                    outputName: "dory-vm-kernel-\(hostGuestArch)",
                    stateDirectory: stateDirectory
                ),
              let rootfs = existingPath(firstOf: ["DORYD_VMM_ROOTFS", "DORYD_ENGINE_ROOTFS", "DORY_ENGINE_ROOTFS"])
                ?? preparedPersistentBundledCompressedResource(
                    named: ["dory-engine-rootfs-\(hostGuestArch).ext4", "dory-engine-rootfs.ext4", "dory-vm-initfs-\(hostGuestArch).ext4"],
                    outputName: "dory-vz-engine-rootfs-\(hostGuestArch).ext4",
                    stateDirectory: stateDirectory
                )
                ?? preparedPersistentBundledResource(
                    named: ["dory-machine-rootfs-\(hostGuestArch).ext4", "dory-machine-rootfs.ext4"],
                    outputName: "dory-vz-engine-rootfs-\(hostGuestArch).ext4",
                    stateDirectory: stateDirectory
                ) else {
            return nil
        }

        let handoffSocket = "\(stateDirectory)/dory-vmm-docker-handoff.sock"
        let cmdline = "console=hvc0 root=/dev/vda rw rootwait panic=1 dory.machine_id=docker dory.home=\(home)"
        var arguments = [
            "--machine-id", "docker",
            "--state-dir", stateDirectory,
            "--kernel", kernel,
            "--rootfs", rootfs,
            "--handoff-sock", handoffSocket,
            "--memory-mb", String(int("DORYD_MEMORY_MB") ?? 2048),
            "--cpus", String(int("DORYD_CPUS") ?? 4),
            "--cmdline", cmdline,
        ]
        if bool("DORYD_SHARE_HOME", default: true) {
            arguments.append(contentsOf: ["--share", "home=\(home):\(home):rw"])
        }

        return VmmDockerProcessConfiguration(
            executablePath: helper,
            arguments: arguments,
            stateDirectory: stateDirectory,
            handoffSocketPath: handoffSocket,
            logPath: string("DORYD_VMM_DOCKER_LOG") ?? "\(stateDirectory)/dory-vmm-docker.log",
            readyTimeoutSeconds: double("DORYD_VMM_DOCKER_READY_TIMEOUT") ?? 90
        )
    }

    private func shares() -> [String] {
        if let explicit = string("DORYD_SHARES") {
            return explicit.split(separator: ";").map(String.init).filter { !$0.isEmpty }
        }
        guard bool("DORYD_SHARE_HOME", default: true) else { return [] }
        return ["home=\(home):rw:at=\(home):safe"]
    }

    private func helperCandidates(named name: String) -> [String] {
        let arch = hostDarwinArch
        let doryCorePackageRoot = "\(cwd)/dory-core-swift"
        let packageRoot = "\(cwd)/Packages/ContainerizationEngine"
        return [
            bundleHelpersDirectory.map { "\($0)/\(name)" },
            "\(cwd)/.build/debug/\(name)",
            "\(cwd)/.build/release/\(name)",
            "\(cwd)/.build/\(arch)-apple-macosx/debug/\(name)",
            "\(cwd)/.build/\(arch)-apple-macosx/release/\(name)",
            "\(doryCorePackageRoot)/.build/debug/\(name)",
            "\(doryCorePackageRoot)/.build/release/\(name)",
            "\(doryCorePackageRoot)/.build/\(arch)-apple-macosx/debug/\(name)",
            "\(doryCorePackageRoot)/.build/\(arch)-apple-macosx/release/\(name)",
            "\(cwd)/Helpers/\(name)",
            "\(cwd)/../Helpers/\(name)",
            "\(packageRoot)/.build/out/Products/Release/\(name)",
            "\(packageRoot)/.build/out/Products/Debug/\(name)",
            "\(packageRoot)/.build/apple/Products/Release/\(name)",
            "\(packageRoot)/.build/apple/Products/Debug/\(name)",
            "\(packageRoot)/.build/\(arch)-apple-macosx/release/\(name)",
            "\(packageRoot)/.build/\(arch)-apple-macosx/debug/\(name)",
        ].compactMap { $0 }
    }

    private func gvproxyCandidates() -> [String] {
        [
            bundleHelpersDirectory.map { "\($0)/gvproxy" },
            "\(cwd)/Helpers/gvproxy",
            "\(cwd)/../Helpers/gvproxy",
            "/opt/homebrew/opt/podman/libexec/podman/gvproxy",
            "/usr/local/opt/podman/libexec/podman/gvproxy",
            "/opt/homebrew/bin/gvproxy",
            "/usr/local/bin/gvproxy",
        ].compactMap { $0 }
    }

    private func executablePath(firstOf keys: [String], fallbackCandidates: [String]) -> String? {
        if let explicit = path(firstOf: keys), FileManager.default.isExecutableFile(atPath: explicit) {
            return explicit
        }
        return fallbackCandidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    private func path(firstOf keys: [String]) -> String? {
        for key in keys {
            if let value = string(key), !value.isEmpty {
                return value
            }
        }
        return nil
    }

    private func existingPath(firstOf keys: [String]) -> String? {
        guard let value = path(firstOf: keys),
              FileManager.default.fileExists(atPath: value) else {
            return nil
        }
        return value
    }

    private var hostDarwinArch: String {
        ProcessInfo.processInfo.machineHardwareName == "x86_64" ? "x86_64" : "arm64"
    }

    private var hostGuestArch: String {
        hostDarwinArch == "x86_64" ? "amd64" : "arm64"
    }

    private var rawHVSupported: Bool {
        if string("DORYD_RAW_HV_SUPPORTED") != nil {
            return bool("DORYD_RAW_HV_SUPPORTED", default: true)
        }
        if hostDarwinArch == "arm64" {
            if #available(macOS 15, *) {
                return true
            }
            return false
        }
        return true
    }

    private var bundleContentsDirectory: String? {
        guard !executablePath.isEmpty else { return nil }
        let executableURL = URL(fileURLWithPath: executablePath)
        let contentsURL = executableURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        guard FileManager.default.fileExists(atPath: contentsURL.path) else {
            return nil
        }
        return contentsURL.path
    }

    private var bundleResourcesDirectory: String? {
        guard let bundleContentsDirectory else { return nil }
        let resources = URL(fileURLWithPath: bundleContentsDirectory)
            .appendingPathComponent("Resources")
            .path
        return FileManager.default.fileExists(atPath: resources) ? resources : nil
    }

    private var bundleHelpersDirectory: String? {
        guard let bundleContentsDirectory else { return nil }
        let helpers = URL(fileURLWithPath: bundleContentsDirectory)
            .appendingPathComponent("Helpers")
            .path
        return FileManager.default.fileExists(atPath: helpers) ? helpers : nil
    }

    private func bundledResource(named names: [String]) -> String? {
        let directories = [
            bundleResourcesDirectory,
            "\(cwd)/Resources",
            "\(cwd)/../Resources",
        ].compactMap { $0 }

        for directory in directories {
            for name in names {
                let path = URL(fileURLWithPath: directory).appendingPathComponent(name).path
                if FileManager.default.fileExists(atPath: path) {
                    return path
                }
            }
        }
        return nil
    }

    private func preparedBundledCompressedResource(
        named names: [String],
        outputName: String,
        stateDirectory: String
    ) -> String? {
        preparedBundledCompressedResource(
            named: names,
            outputName: outputName,
            stateDirectory: stateDirectory,
            refreshIfSourceNewer: true
        )
    }

    private func preparedPersistentBundledCompressedResource(
        named names: [String],
        outputName: String,
        stateDirectory: String
    ) -> String? {
        preparedBundledCompressedResource(
            named: names,
            outputName: outputName,
            stateDirectory: stateDirectory,
            refreshIfSourceNewer: false
        )
    }

    private func preparedBundledCompressedResource(
        named names: [String],
        outputName: String,
        stateDirectory: String,
        refreshIfSourceNewer: Bool
    ) -> String? {
        let directories = [
            bundleResourcesDirectory,
            "\(cwd)/Resources",
            "\(cwd)/../Resources",
        ].compactMap { $0 }

        for directory in directories {
            for name in names {
                let source = URL(fileURLWithPath: directory)
                    .appendingPathComponent(name)
                    .appendingPathExtension("lzfse")
                guard FileManager.default.fileExists(atPath: source.path) else { continue }
                return prepareCompressedResource(
                    source: source,
                    outputName: outputName,
                    stateDirectory: stateDirectory,
                    refreshIfSourceNewer: refreshIfSourceNewer
                )
            }
        }
        return nil
    }

    private func preparedPersistentBundledResource(
        named names: [String],
        outputName: String,
        stateDirectory: String
    ) -> String? {
        guard let sourcePath = bundledResource(named: names) else { return nil }
        let directory = URL(fileURLWithPath: stateDirectory)
            .appendingPathComponent("assets", isDirectory: true)
        let output = directory.appendingPathComponent(outputName)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            if !FileManager.default.fileExists(atPath: output.path) {
                try FileManager.default.copyItem(atPath: sourcePath, toPath: output.path)
            }
            return FileManager.default.fileExists(atPath: output.path) ? output.path : nil
        } catch {
            return nil
        }
    }

    private func prepareCompressedResource(
        source: URL,
        outputName: String,
        stateDirectory: String,
        refreshIfSourceNewer: Bool
    ) -> String? {
        let directory = URL(fileURLWithPath: stateDirectory)
            .appendingPathComponent("assets", isDirectory: true)
        let output = directory.appendingPathComponent(outputName)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            if !FileManager.default.fileExists(atPath: output.path)
                || (refreshIfSourceNewer && shouldRefreshAsset(source: source, output: output)) {
                let temporary = directory.appendingPathComponent("\(outputName).partial-\(UUID().uuidString)")
                do {
                    try DorydLZFSE.decompress(source: source.path, destination: temporary.path)
                    _ = try? FileManager.default.removeItem(at: output)
                    try FileManager.default.moveItem(at: temporary, to: output)
                } catch {
                    try? FileManager.default.removeItem(at: temporary)
                    return nil
                }
            }
            return FileManager.default.fileExists(atPath: output.path) ? output.path : nil
        } catch {
            return nil
        }
    }

    private func shouldRefreshAsset(source: URL, output: URL) -> Bool {
        guard FileManager.default.fileExists(atPath: output.path) else { return true }
        let sourceValues = try? source.resourceValues(forKeys: [.contentModificationDateKey])
        let outputValues = try? output.resourceValues(forKeys: [.contentModificationDateKey])
        if let sourceDate = sourceValues?.contentModificationDate,
           let outputDate = outputValues?.contentModificationDate {
            return outputDate < sourceDate
        }
        return false
    }

    private func string(_ key: String) -> String? {
        values[key].flatMap { $0.isEmpty ? nil : $0 }
    }

    private func int(_ key: String) -> Int? {
        string(key).flatMap(Int.init)
    }

    private func uint32(_ key: String) -> UInt32? {
        string(key).flatMap(UInt32.init)
    }

    private func uint16(_ key: String) -> UInt16? {
        string(key).flatMap(UInt16.init)
    }

    private func double(_ key: String) -> TimeInterval? {
        string(key).flatMap(TimeInterval.init)
    }

    private func bool(_ key: String, default defaultValue: Bool) -> Bool {
        guard let value = string(key)?.lowercased() else { return defaultValue }
        if ["1", "true", "yes", "on"].contains(value) { return true }
        if ["0", "false", "no", "off"].contains(value) { return false }
        return defaultValue
    }

    private func splitArguments(_ raw: String) -> [String] {
        raw.split(separator: " ").map(String.init).filter { !$0.isEmpty }
    }

    private func privilegedTCPForwards() -> [PrivilegedTCPForward] {
        let raw = string("DORYD_PRIVILEGED_TCP_FORWARDS")
            ?? string("DORYD_PRIVILEGED_PORT_FORWARDS")
            ?? ""
        var forwards: [UInt16: PrivilegedTCPForward] = [:]
        for entry in raw.split(separator: ",") {
            let parts = entry.split(separator: ":", maxSplits: 1)
            guard parts.count == 2,
                  let listen = UInt16(String(parts[0]).trimmingCharacters(in: .whitespaces)),
                  let target = UInt16(String(parts[1]).trimmingCharacters(in: .whitespaces)) else {
                continue
            }
            forwards[listen] = PrivilegedTCPForward(listenPort: listen, targetPort: target)
        }
        return forwards.values.sorted { $0.listenPort < $1.listenPort }
    }
}

private extension ProcessInfo {
    var machineHardwareName: String {
        var systemInfo = utsname()
        uname(&systemInfo)
        return withUnsafePointer(to: &systemInfo.machine) {
            $0.withMemoryRebound(to: CChar.self, capacity: 1) { String(cString: $0) }
        }
    }
}
