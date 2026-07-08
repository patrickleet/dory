import Darwin
import Foundation

public struct KubernetesServiceRouteProviderConfiguration: Sendable, Equatable {
    public var home: String
    public var kubectlPath: String?
    public var kubeconfigPath: String
    public var proxyPort: UInt16
    public var commandTimeout: TimeInterval

    public init(
        home: String,
        kubectlPath: String?,
        kubeconfigPath: String,
        proxyPort: UInt16 = 18_001,
        commandTimeout: TimeInterval = 5
    ) {
        self.home = home
        self.kubectlPath = kubectlPath
        self.kubeconfigPath = kubeconfigPath
        self.proxyPort = proxyPort
        self.commandTimeout = commandTimeout
    }
}

public final class KubernetesServiceRouteProvider: @unchecked Sendable {
    private let configuration: KubernetesServiceRouteProviderConfiguration
    private let commandRunner: HealthCommandRunning
    private let fileManager: FileManager
    private let lock = NSLock()
    private var proxy: Process?

    public init(
        configuration: KubernetesServiceRouteProviderConfiguration,
        commandRunner: HealthCommandRunning = ProcessHealthCommandRunner(),
        fileManager: FileManager = .default
    ) {
        self.configuration = configuration
        self.commandRunner = commandRunner
        self.fileManager = fileManager
    }

    public func routes(suffix: String) -> [DomainRoute] {
        guard fileManager.fileExists(atPath: configuration.kubeconfigPath),
              let kubectl = kubectlPath() else {
            stop()
            return []
        }
        guard ensureProxy(kubectl: kubectl) else {
            return []
        }
        let output = commandRunner.run(
            executablePath: kubectl,
            arguments: ["--kubeconfig", configuration.kubeconfigPath, "get", "svc", "-A", "-o", "json"],
            environment: kubectlEnvironment(),
            timeout: configuration.commandTimeout
        )
        guard output.exitCode == 0 else { return [] }
        return Self.routes(
            fromKubectlJSON: output.stdout,
            proxyPort: configuration.proxyPort,
            suffix: suffix
        )
    }

    public func stop() {
        lock.lock()
        let current = proxy
        proxy = nil
        lock.unlock()
        if let current, current.isRunning {
            current.terminate()
        }
    }

    public static func routes(fromKubectlJSON json: String, proxyPort: UInt16, suffix rawSuffix: String) -> [DomainRoute] {
        guard let data = json.data(using: .utf8),
              let list = try? JSONDecoder().decode(KubernetesServiceList.self, from: data) else {
            return []
        }
        let suffix = DomainRouter.normalize(rawSuffix).trimmingCharacters(in: CharacterSet(charactersIn: "."))
        return (list.items ?? []).compactMap { item -> DomainRoute? in
            guard let name = item.metadata?.name,
                  let namespace = item.metadata?.namespace,
                  let port = item.spec?.ports?.first?.port,
                  item.spec?.clusterIP != "None" else {
                return nil
            }
            let hostname = DomainRouter.normalize("\(name).\(namespace).k8s.\(suffix)")
            return DomainRoute(
                hostname: hostname,
                address: "127.0.0.1",
                port: proxyPort,
                pathPrefix: "/api/v1/namespaces/\(namespace)/services/\(name):\(port)/proxy"
            )
        }.sorted {
            if $0.hostname == $1.hostname { return $0.pathPrefix < $1.pathPrefix }
            return $0.hostname < $1.hostname
        }
    }

    private func kubectlPath() -> String? {
        if let path = configuration.kubectlPath, fileManager.isExecutableFile(atPath: path) {
            return path
        }
        let linked = "\(configuration.home)/.dory/bin/kubectl"
        return fileManager.isExecutableFile(atPath: linked) ? linked : nil
    }

    private func ensureProxy(kubectl: String) -> Bool {
        lock.lock()
        if let proxy, proxy.isRunning {
            lock.unlock()
            return true
        }
        proxy = nil
        lock.unlock()

        if Self.portAcceptsConnections(configuration.proxyPort) {
            return true
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: kubectl)
        process.arguments = [
            "--kubeconfig", configuration.kubeconfigPath,
            "proxy",
            "--port=\(configuration.proxyPort)",
            "--address=127.0.0.1",
            "--accept-hosts=.*",
        ]
        process.environment = kubectlEnvironment()
        if let null = FileHandle(forWritingAtPath: "/dev/null") {
            process.standardOutput = null
            process.standardError = null
        } else {
            process.standardOutput = Pipe()
            process.standardError = Pipe()
        }

        do {
            try process.run()
        } catch {
            return false
        }

        lock.lock()
        proxy = process
        lock.unlock()

        for _ in 0..<20 {
            if Self.portAcceptsConnections(configuration.proxyPort) {
                return true
            }
            if !process.isRunning {
                lock.lock()
                if proxy === process { proxy = nil }
                lock.unlock()
                return false
            }
            Thread.sleep(forTimeInterval: 0.05)
        }
        return process.isRunning
    }

    private func kubectlEnvironment() -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        environment["HOME"] = configuration.home
        return environment
    }

    private static func portAcceptsConnections(_ port: UInt16) -> Bool {
        guard let fd = DoryTCP.connect(host: "127.0.0.1", port: port) else { return false }
        shutdown(fd, SHUT_RDWR)
        close(fd)
        return true
    }

    deinit {
        stop()
    }
}

private struct KubernetesServiceList: Decodable {
    var items: [KubernetesServiceItem]?
}

private struct KubernetesServiceItem: Decodable {
    var metadata: KubernetesServiceMetadata?
    var spec: KubernetesServiceSpec?
}

private struct KubernetesServiceMetadata: Decodable {
    var name: String?
    var namespace: String?
}

private struct KubernetesServiceSpec: Decodable {
    var ports: [KubernetesServicePort]?
    var clusterIP: String?
}

private struct KubernetesServicePort: Decodable {
    var port: Int?
}
