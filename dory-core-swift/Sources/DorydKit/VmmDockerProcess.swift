import Darwin
import Foundation

public struct VmmDockerProcessConfiguration: Sendable {
    public var executablePath: String
    public var arguments: [String]
    public var stateDirectory: String
    public var handoffSocketPath: String
    public var logPath: String?
    public var readyTimeoutSeconds: TimeInterval

    public init(
        executablePath: String,
        arguments: [String],
        stateDirectory: String,
        handoffSocketPath: String,
        logPath: String? = nil,
        readyTimeoutSeconds: TimeInterval = 90
    ) {
        self.executablePath = executablePath
        self.arguments = arguments
        self.stateDirectory = stateDirectory
        self.handoffSocketPath = handoffSocketPath
        self.logPath = logPath
        self.readyTimeoutSeconds = readyTimeoutSeconds
    }
}

public final class VmmDockerProcess: @unchecked Sendable {
    public enum ProcessError: Error, CustomStringConvertible {
        case alreadyRunning
        case executableMissing(String)
        case handoffTimeout
        case handoffFailed(String)

        public var description: String {
            switch self {
            case .alreadyRunning:
                return "dory-vmm docker helper is already running"
            case .executableMissing(let path):
                return "dory-vmm executable missing: \(path)"
            case .handoffTimeout:
                return "dory-vmm docker helper did not become ready before timeout"
            case .handoffFailed(let message):
                return "dory-vmm docker handoff failed: \(message)"
            }
        }
    }

    private let configuration: VmmDockerProcessConfiguration
    private let lock = NSLock()
    private var process: Process?
    private var handoffServer: VmmHandoffServer?
    private var logHandle: FileHandle?
    private var suspended = false

    public init(configuration: VmmDockerProcessConfiguration) {
        self.configuration = configuration
    }

    public var pid: Int32? {
        lock.lock()
        defer { lock.unlock() }
        guard let process, process.isRunning else { return nil }
        return process.processIdentifier
    }

    public var isRunning: Bool {
        lock.lock()
        defer { lock.unlock() }
        return process?.isRunning == true
    }

    public func start() throws {
        lock.lock()
        if process?.isRunning == true {
            lock.unlock()
            throw ProcessError.alreadyRunning
        }
        lock.unlock()

        guard FileManager.default.isExecutableFile(atPath: configuration.executablePath) else {
            throw ProcessError.executableMissing(configuration.executablePath)
        }
        try FileManager.default.createDirectory(atPath: configuration.stateDirectory, withIntermediateDirectories: true)

        let semaphore = DispatchSemaphore(value: 0)
        let result = LockedResultBox<VmmHandoff>()
        let server = VmmHandoffServer(path: configuration.handoffSocketPath) { handoff in
            result.set(handoff)
            semaphore.signal()
        }
        try server.start()

        let task = Process()
        task.executableURL = URL(fileURLWithPath: configuration.executablePath)
        task.arguments = configuration.arguments
        let log = Self.openAppendLog(configuration.logPath)
        task.standardOutput = log ?? FileHandle.standardError
        task.standardError = log ?? FileHandle.standardError

        lock.lock()
        handoffServer = server
        logHandle = log
        lock.unlock()

        do {
            try task.run()
        } catch {
            server.stop()
            try? log?.close()
            lock.lock()
            handoffServer = nil
            logHandle = nil
            lock.unlock()
            throw error
        }

        lock.lock()
        process = task
        suspended = false
        lock.unlock()

        let timeoutMilliseconds = Int(configuration.readyTimeoutSeconds * 1000)
        let deadline = DispatchTime.now() + .milliseconds(max(1, timeoutMilliseconds))
        guard semaphore.wait(timeout: deadline) == .success else {
            stop(signal: SIGTERM, timeout: 5)
            throw ProcessError.handoffTimeout
        }
        switch result.value {
        case .success?:
            return
        case .failure(let error)?:
            stop(signal: SIGTERM, timeout: 5)
            throw ProcessError.handoffFailed("\(error)")
        case nil:
            stop(signal: SIGTERM, timeout: 5)
            throw ProcessError.handoffTimeout
        }
    }

    @discardableResult
    public func suspend() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard let process, process.isRunning else { return false }
        if suspended { return true }
        guard kill(process.processIdentifier, SIGSTOP) == 0 else { return false }
        suspended = true
        return true
    }

    @discardableResult
    public func resume() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard let process, process.isRunning else { return false }
        if !suspended { return true }
        guard kill(process.processIdentifier, SIGCONT) == 0 else { return false }
        suspended = false
        return true
    }

    public func stop(signal: Int32 = SIGTERM, timeout: TimeInterval = 5) {
        let task: Process?
        let server: VmmHandoffServer?
        let log: FileHandle?
        let wasSuspended: Bool
        lock.lock()
        task = process
        process = nil
        server = handoffServer
        handoffServer = nil
        log = logHandle
        logHandle = nil
        wasSuspended = suspended
        suspended = false
        lock.unlock()

        server?.stop()
        defer { try? log?.close() }
        guard let task, task.isRunning else { return }
        if wasSuspended {
            kill(task.processIdentifier, SIGCONT)
        }
        kill(task.processIdentifier, signal)
        let deadline = Date().addingTimeInterval(timeout)
        while task.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.02)
        }
        if task.isRunning {
            kill(task.processIdentifier, SIGKILL)
            task.waitUntilExit()
        }
    }

    private static func openAppendLog(_ path: String?) -> FileHandle? {
        guard let path else { return nil }
        let directory = (path as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        let fd = open(path, O_WRONLY | O_APPEND | O_CREAT, 0o600)
        guard fd >= 0 else { return nil }
        return FileHandle(fileDescriptor: fd, closeOnDealloc: true)
    }

    deinit {
        stop()
    }
}

private final class LockedResultBox<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Result<T, Error>?

    var value: Result<T, Error>? {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }

    func set(_ value: Result<T, Error>) {
        lock.lock()
        stored = value
        lock.unlock()
    }
}
