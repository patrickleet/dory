import Darwin
import Foundation

public struct VmmDockerProcessConfiguration: Sendable {
    public var executablePath: String
    public var arguments: [String]
    public var stateDirectory: String
    public var handoffSocketPath: String
    public var logPath: String?
    public var readyTimeoutSeconds: TimeInterval
    public var restartPolicy: HvRestartPolicy

    public init(
        executablePath: String,
        arguments: [String],
        stateDirectory: String,
        handoffSocketPath: String,
        logPath: String? = nil,
        readyTimeoutSeconds: TimeInterval = 90,
        restartPolicy: HvRestartPolicy = HvRestartPolicy(maxRestarts: 3, delaySeconds: 0.5)
    ) {
        self.executablePath = executablePath
        self.arguments = arguments
        self.stateDirectory = stateDirectory
        self.handoffSocketPath = handoffSocketPath
        self.logPath = logPath
        self.readyTimeoutSeconds = readyTimeoutSeconds
        self.restartPolicy = restartPolicy
    }
}

public final class VmmDockerProcess: @unchecked Sendable {
    public enum ProcessError: Error, CustomStringConvertible {
        case alreadyRunning
        case executableMissing(String)
        case startCancelled
        case handoffTimeout
        case handoffFailed(String)

        public var description: String {
            switch self {
            case .alreadyRunning:
                return "dory-vmm docker helper is already running"
            case .executableMissing(let path):
                return "dory-vmm executable missing: \(path)"
            case .startCancelled:
                return "dory-vmm docker helper start was cancelled"
            case .handoffTimeout:
                return "dory-vmm docker helper did not become ready before timeout"
            case .handoffFailed(let message):
                return "dory-vmm docker handoff failed: \(message)"
            }
        }
    }

    private let configuration: VmmDockerProcessConfiguration
    private let unexpectedTerminationHandler: HvProcessUnexpectedTerminationHandler?
    private let lock = NSLock()
    private var process: Process?
    private var handoffServer: VmmHandoffServer?
    private var handoffWaiter: DispatchSemaphore?
    private var logHandle: FileHandle?
    private var suspended = false
    private var starting = false
    private var stopping = false
    private var hasStarted = false
    private var lastReady: VmmReadyMessage?

    public init(
        configuration: VmmDockerProcessConfiguration,
        unexpectedTerminationHandler: HvProcessUnexpectedTerminationHandler? = nil
    ) {
        self.configuration = configuration
        self.unexpectedTerminationHandler = unexpectedTerminationHandler
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

    public var readyMessage: VmmReadyMessage? {
        lock.lock()
        defer { lock.unlock() }
        return lastReady
    }

    public func start() throws {
        lock.lock()
        // Hold the reservation under the lock across check + spawn so two concurrent starts
        // can't both bind the handoff socket and double-launch the helper.
        if process?.isRunning == true || starting {
            lock.unlock()
            throw ProcessError.alreadyRunning
        }
        // Preserve a stop that won the race before this first start. Clearing it here would let
        // the VMM spawn after DockerTier.stop() had already completed, recreating the launchd
        // orphan window this class is responsible for closing.
        if stopping, !hasStarted {
            lock.unlock()
            throw ProcessError.startCancelled
        }
        hasStarted = true
        starting = true
        stopping = false
        lock.unlock()

        do {
            try launch()
        } catch {
            lock.lock()
            starting = false
            lock.unlock()
            throw error
        }
        lock.lock()
        guard !stopping, process?.isRunning == true else {
            starting = false
            lock.unlock()
            stop(signal: SIGTERM, timeout: 5)
            throw ProcessError.startCancelled
        }
        starting = false
        lock.unlock()
    }

    private func launch() throws {
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

        lock.lock()
        guard starting, !stopping else {
            lock.unlock()
            server.stop()
            throw ProcessError.startCancelled
        }
        handoffServer = server
        handoffWaiter = semaphore
        lock.unlock()

        let task = Process()
        task.executableURL = URL(fileURLWithPath: configuration.executablePath)
        task.arguments = configuration.arguments
        let log = Self.openAppendLog(configuration.logPath)
        task.standardOutput = log ?? FileHandle.standardError
        task.standardError = log ?? FileHandle.standardError
        task.terminationHandler = { [weak self] task in
            self?.handleTermination(task)
        }

        // Keep the process assignment atomic with run() relative to the termination callback. A
        // helper that exits immediately must not leave a dead Process installed after its callback
        // already observed `process == nil`.
        lock.lock()
        guard starting, !stopping else {
            if handoffServer === server {
                handoffServer = nil
            }
            if handoffWaiter === semaphore {
                handoffWaiter = nil
            }
            lock.unlock()
            server.stop()
            try? log?.close()
            throw ProcessError.startCancelled
        }
        logHandle = log
        do {
            try task.run()
        } catch {
            lock.unlock()
            server.stop()
            try? log?.close()
            lock.lock()
            handoffServer = nil
            handoffWaiter = nil
            logHandle = nil
            lock.unlock()
            throw error
        }
        process = task
        suspended = false
        lock.unlock()

        let timeoutMilliseconds = Int(configuration.readyTimeoutSeconds * 1000)
        let deadline = DispatchTime.now() + .milliseconds(max(1, timeoutMilliseconds))
        let waitResult = semaphore.wait(timeout: deadline)
        lock.lock()
        if handoffWaiter === semaphore {
            handoffWaiter = nil
        }
        let startWasCancelled = stopping || !starting
        lock.unlock()
        guard !startWasCancelled else {
            server.stop()
            throw ProcessError.startCancelled
        }
        guard waitResult == .success else {
            stop(signal: SIGTERM, timeout: 5)
            throw ProcessError.handoffTimeout
        }
        switch result.value {
        case .success(let handoff)?:
            lock.lock()
            guard !stopping, starting, process?.isRunning == true else {
                lastReady = nil
                let cancelled = stopping || !starting
                lock.unlock()
                if cancelled {
                    throw ProcessError.startCancelled
                }
                throw ProcessError.handoffFailed("helper exited immediately after handoff")
            }
            lastReady = handoff.ready
            lock.unlock()
            return
        case .failure(let error)?:
            stop(signal: SIGTERM, timeout: 5)
            throw ProcessError.handoffFailed("\(error)")
        case nil:
            stop(signal: SIGTERM, timeout: 5)
            throw ProcessError.handoffTimeout
        }
    }

    private func handleTermination(_ task: Process) {
        let oldLog: FileHandle?
        let server: VmmHandoffServer?
        let waiter: DispatchSemaphore?
        let wasUnexpected: Bool
        let termination = HvProcessTermination(
            status: task.terminationStatus,
            wasUncaughtSignal: task.terminationReason == .uncaughtSignal
        )
        lock.lock()
        guard process === task else {
            lock.unlock()
            return
        }
        process = nil
        suspended = false
        oldLog = logHandle
        logHandle = nil
        server = handoffServer
        handoffServer = nil
        waiter = handoffWaiter
        handoffWaiter = nil
        lastReady = nil
        wasUnexpected = !stopping
        lock.unlock()
        server?.stop()
        waiter?.signal()
        try? oldLog?.close()
        if wasUnexpected {
            unexpectedTerminationHandler?(termination)
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
        let waiter: DispatchSemaphore?
        lock.lock()
        stopping = true
        task = process
        process = nil
        server = handoffServer
        handoffServer = nil
        waiter = handoffWaiter
        handoffWaiter = nil
        log = logHandle
        logHandle = nil
        wasSuspended = suspended
        suspended = false
        lastReady = nil
        lock.unlock()

        server?.stop()
        waiter?.signal()
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
