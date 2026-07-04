import Foundation

/// One-click Kubernetes: runs a k3s server as a container inside Dory's shared VM (the k3d pattern),
/// publishes the API on :6443 (auto-forwarded to `localhost` by the port forwarder), and writes a
/// kubeconfig the host `kubectl` picks up — mirroring OrbStack's built-in cluster. NOTE: k3s brings
/// its own embedded containerd image store, SEPARATE from the shared engine's dockerd store. A
/// locally-built Docker image is therefore NOT automatically visible to Pods — push it to a registry
/// the cluster can reach, or import it into k3s's containerd (`k8s.io` namespace). Auto image-sync is
/// a tracked follow-up.
///
/// Two optional host-side config files extend the cluster without GUI plumbing (and are shared
/// with the `dory k8s` CLI):
///   • `~/.dory/k8s/ports` — extra port publishings, one `HOST:CONTAINER[/proto]` per line.
///     Published ports are auto-forwarded to `localhost` like any container's, so k3s NodePorts
///     become host-reachable (e.g. `30500:30500` for a local registry).
///   • `~/.dory/k8s/registries.yaml` — bind-mounted read-only to `/etc/rancher/k3s/registries.yaml`,
///     k3s' native registry mirror/trust config. Living on the host, it survives the cluster
///     container being recreated (k3s reads it at boot).
enum KubernetesProvisioner {
    static let containerName = "dory-k8s"
    nonisolated static let defaultImage = KubeVersionCatalog.latest.image
    static let apiPort = 6443
    /// Name used for the cluster/user/context in the exported kubeconfig, replacing k3s' generic
    /// `default` so tools can target the cluster with `--context dory`.
    static let contextName = "dory"
    static var kubeconfigPath: String { "\(NSHomeDirectory())/.kube/dory-config" }
    static var configDirectory: String { "\(NSHomeDirectory())/.dory/k8s" }
    static var extraPortsConfigPath: String { "\(configDirectory)/ports" }
    static var registriesConfigPath: String { "\(configDirectory)/registries.yaml" }

    enum K8sError: Error, Sendable { case createFailed, notReady, kubeconfigFailed }

    /// An extra `HOST:CONTAINER[/tcp|udp]` publishing on the cluster container.
    struct PortPublish: Equatable, Sendable {
        var host: Int
        var container: Int
        var proto: String

        static func parse(_ line: String) -> PortPublish? {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { return nil }
            let portsAndProto = trimmed.split(separator: "/", maxSplits: 1)
            let proto = portsAndProto.count == 2 ? String(portsAndProto[1]) : "tcp"
            guard proto == "tcp" || proto == "udp" else { return nil }
            let parts = portsAndProto[0].split(separator: ":")
            guard parts.count == 2, let host = Int(parts[0]), let container = Int(parts[1]),
                  (1...65535).contains(host), (1...65535).contains(container) else { return nil }
            return PortPublish(host: host, container: container, proto: proto)
        }
    }

    static func enable(runtime: any ContainerRuntime, image: String = defaultImage, progress: @Sendable (String) -> Void = { _ in }) async throws {
        let extraPorts = loadExtraPorts()
        if await isRunning(runtime) {
            if await publishedPortsCurrent(runtime, extraPorts: extraPorts) {
                try await writeKubeconfig(runtime)
                progress("Kubernetes is running")
                return
            }
            progress("Port publishing changed — recreating the cluster…")
        }

        progress("Pulling Kubernetes (k3s)…")
        try? await runtime.pull(image: image)

        progress("Starting the cluster in the shared VM…")
        await deleteExisting(runtime)
        let encodedName = DockerImageOps.queryValue(containerName)
        guard let create = await runtime.proxyRequest(method: "POST", path: "/containers/create?name=\(encodedName)",
            headers: [(name: "Content-Type", value: "application/json")],
            body: createBody(image: image, extraPorts: extraPorts, registriesBind: registriesBindSource())),
            create.statusCode == 201, let id = decodeId(create.body) else { throw K8sError.createFailed }
        let encodedID = DockerImageOps.pathComponent(id)
        guard let start = await runtime.proxyRequest(method: "POST", path: "/containers/\(encodedID)/start", headers: [], body: Data()),
            start.statusCode == 204 || start.isSuccess else { throw K8sError.createFailed }

        progress("Waiting for the node to become Ready…")
        for _ in 0..<60 {
            if let result = try? await runtime.exec(containerID: containerName, command: ["kubectl", "get", "nodes", "--no-headers"]),
               result.output.contains("Ready") {
                try await writeKubeconfig(runtime)
                progress("Kubernetes is running")
                return
            }
            try? await Task.sleep(for: .seconds(2))
        }
        throw K8sError.notReady
    }

    static func disable(runtime: any ContainerRuntime) async {
        await deleteExisting(runtime)
        try? FileManager.default.removeItem(atPath: kubeconfigPath)
    }

    static func createJSON(image: String, extraPorts: [PortPublish] = [], registriesBind: String? = nil) -> String {
        var exposed = ["\"\(apiPort)/tcp\":{}"]
        var bindings = ["\"\(apiPort)/tcp\":[{\"HostPort\":\"\(apiPort)\"}]"]
        for port in extraPorts where !(port.container == apiPort && port.proto == "tcp") {
            exposed.append("\"\(port.container)/\(port.proto)\":{}")
            bindings.append("\"\(port.container)/\(port.proto)\":[{\"HostPort\":\"\(port.host)\"}]")
        }
        let binds = registriesBind.map { ",\"Binds\":[\"\($0):/etc/rancher/k3s/registries.yaml:ro\"]" } ?? ""
        return """
        {"Image":"\(image)",\
        "Cmd":["server","--disable=traefik","--tls-san=127.0.0.1","--tls-san=host.docker.internal"],\
        "ExposedPorts":{\(exposed.joined(separator: ","))},\
        "HostConfig":{"Privileged":true,"PortBindings":{\(bindings.joined(separator: ","))}\(binds)}}
        """
    }

    static func loadExtraPorts(path: String? = nil) -> [PortPublish] {
        let file = path ?? extraPortsConfigPath
        guard let content = try? String(contentsOfFile: file, encoding: .utf8) else { return [] }
        return content.split(separator: "\n").compactMap { PortPublish.parse(String($0)) }
    }

    /// The host registries.yaml to bind into the node, when the user has created one. The home
    /// directory is shared into the VM at the same path (SharedVMProvisioner), so the host path is
    /// directly bind-mountable by the VM's dockerd.
    static func registriesBindSource() -> String? {
        FileManager.default.fileExists(atPath: registriesConfigPath) ? registriesConfigPath : nil
    }

    /// Rename k3s' generic `default` cluster/user/context to `dory`. k3s.yaml is single-entry with
    /// a stable shape, so targeted textual rewrites are sufficient and dependency-free.
    static func renameContext(_ kubeconfig: String) -> String {
        kubeconfig
            .replacingOccurrences(of: "name: default", with: "name: \(contextName)")
            .replacingOccurrences(of: "cluster: default", with: "cluster: \(contextName)")
            .replacingOccurrences(of: "user: default", with: "user: \(contextName)")
            .replacingOccurrences(of: "current-context: default", with: "current-context: \(contextName)")
    }

    private static func createBody(image: String, extraPorts: [PortPublish], registriesBind: String?) -> Data {
        Data(createJSON(image: image, extraPorts: extraPorts, registriesBind: registriesBind).utf8)
    }

    private static func writeKubeconfig(_ runtime: any ContainerRuntime) async throws {
        guard let result = try? await runtime.exec(containerID: containerName, command: ["cat", "/etc/rancher/k3s/k3s.yaml"]),
              result.output.contains("server:") else { throw K8sError.kubeconfigFailed }
        // k3s.yaml already targets 127.0.0.1:6443, which the port forwarder makes host-reachable.
        let directory = (kubeconfigPath as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        try renameContext(result.output).write(toFile: kubeconfigPath, atomically: true, encoding: .utf8)
    }

    private static func isRunning(_ runtime: any ContainerRuntime) async -> Bool {
        let encodedName = DockerImageOps.pathComponent(containerName)
        guard let response = await runtime.proxyRequest(method: "GET", path: "/containers/\(encodedName)/json", headers: [], body: Data()),
              response.isSuccess else { return false }
        return String(data: response.body, encoding: .utf8)?.contains("\"Running\":true") ?? false
    }

    /// Whether the existing container already publishes every requested extra port, so an enable
    /// with unchanged config can reuse it instead of recreating (bindings are fixed at create).
    private static func publishedPortsCurrent(_ runtime: any ContainerRuntime, extraPorts: [PortPublish]) async -> Bool {
        guard !extraPorts.isEmpty else { return true }
        let encodedName = DockerImageOps.pathComponent(containerName)
        guard let response = await runtime.proxyRequest(method: "GET", path: "/containers/\(encodedName)/json", headers: [], body: Data()),
              response.isSuccess, let json = String(data: response.body, encoding: .utf8) else { return false }
        return extraPorts.allSatisfy {
            json.contains("\"\($0.container)/\($0.proto)\"") && json.contains("\"HostPort\":\"\($0.host)\"")
        }
    }

    private static func deleteExisting(_ runtime: any ContainerRuntime) async {
        let encodedName = DockerImageOps.pathComponent(containerName)
        _ = await runtime.proxyRequest(method: "DELETE", path: "/containers/\(encodedName)?force=true", headers: [], body: Data())
    }

    private static func decodeId(_ data: Data) -> String? {
        struct Out: Decodable { let Id: String }
        return (try? JSONDecoder().decode(Out.self, from: data))?.Id
    }
}
