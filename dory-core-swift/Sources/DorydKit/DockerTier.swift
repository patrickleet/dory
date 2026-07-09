import Darwin
import DoryCore
import Foundation

public enum DockerTierState: String, Sendable {
    case stopped
    case starting
    case running
    case sleeping
    case failed
}

public struct DockerTierStatus: Sendable {
    public var state: DockerTierState
    public var socketPath: String
    public var hvPID: Int32?
    public var lastError: String?
}

public struct DockerTierConfiguration: Sendable {
    public var home: String
    public var forwardSocketPath: String
    public var dockerdSocketPath: String?
    public var cid: UInt32
    public var dockerPort: UInt32
    public var gpuSupported: Bool
    public var activitySocketPath: String?
    public var hvProcess: HvProcessConfiguration?
    public var vmmProcess: VmmDockerProcessConfiguration?
    public var agentControl: AgentControlConfiguration?

    public init(
        home: String = NSHomeDirectory(),
        forwardSocketPath: String,
        dockerdSocketPath: String? = nil,
        cid: UInt32 = 3,
        dockerPort: UInt32 = 1026,
        gpuSupported: Bool = false,
        activitySocketPath: String? = nil,
        hvProcess: HvProcessConfiguration? = nil,
        vmmProcess: VmmDockerProcessConfiguration? = nil,
        agentControl: AgentControlConfiguration? = nil
    ) {
        self.home = home
        self.forwardSocketPath = forwardSocketPath
        self.dockerdSocketPath = dockerdSocketPath
        self.cid = cid
        self.dockerPort = dockerPort
        self.gpuSupported = gpuSupported
        self.activitySocketPath = activitySocketPath
        self.hvProcess = hvProcess
        self.vmmProcess = vmmProcess
        self.agentControl = agentControl
    }

    public var hasManagedHelper: Bool {
        hvProcess != nil || vmmProcess != nil
    }
}

public typealias DockerContainerActivityProbe = @Sendable (DockerTierConfiguration) -> DockerContainerActivity
public typealias DockerReadyWaiter = @Sendable (DockerTierConfiguration, TimeInterval) -> Bool

private protocol DockerManagedProcess: AnyObject, Sendable {
    var pid: Int32? { get }
    var isRunning: Bool { get }
    func start() throws
    func suspend() -> Bool
    func resume() -> Bool
    func stop()
}

extension HvProcess: DockerManagedProcess {
    public func stop() {
        stop(signal: SIGTERM, timeout: 5)
    }
}

extension VmmDockerProcess: DockerManagedProcess {
    public func stop() {
        stop(signal: SIGTERM, timeout: 5)
    }
}

public final class DockerTier: @unchecked Sendable {
    public enum TierError: Error, CustomStringConvertible {
        case alreadyRunning
        case sleepingDataplaneRequiresWakeSupport
        case suspendFailed(pid: Int32?)
        case resumeFailed(pid: Int32?)
        case readyTimeout
        case wakeFailed(String)

        public var description: String {
            switch self {
            case .alreadyRunning:
                return "docker tier is already running"
            case .sleepingDataplaneRequiresWakeSupport:
                return "sleeping docker dataplane requires an idle controller, activity socket, and managed dory-hv process"
            case .suspendFailed(let pid):
                return "failed to suspend dory-hv\(pid.map { " pid \($0)" } ?? "")"
            case .resumeFailed(let pid):
                return "failed to resume dory-hv\(pid.map { " pid \($0)" } ?? "")"
            case .readyTimeout:
                return "docker tier did not become ready after wake"
            case .wakeFailed(let message):
                return message.isEmpty ? "docker tier did not wake" : message
            }
        }
    }

    // A cold fresh-start boots the kernel, mounts the rootfs, initializes the docker data disk on
    // first use, and starts dockerd/containerd — legitimately tens of seconds. Too short a ready
    // window tears the engine down mid-boot; the next request restarts the cold boot, so an empty
    // engine never comes up (boot loop). Resume from a suspended helper is near-instant, so it keeps
    // a short window.
    private static let freshStartReadyTimeout: TimeInterval = 180
    private static let resumeReadyTimeout: TimeInterval = 10

    private let configuration: DockerTierConfiguration
    private let containerActivityProbe: DockerContainerActivityProbe
    private let dockerReadyWaiter: DockerReadyWaiter
    private let socket: DorySocket
    private let idleController: IdleController?
    private let agentControl: AgentControl?
    private let portPublisher: PortPublisher?
    private let lock = NSLock()
    private var dataplane: DoryDataplaneHandle?
    private var activityServer: DataplaneActivityServer?
    private var helperProcess: (any DockerManagedProcess)?
    private var state: DockerTierState = .stopped
    private var lastError: String?
    private var wakeTask: Task<Void, Never>?

    public init(
        configuration: DockerTierConfiguration,
        idleController: IdleController? = nil,
        agentControl injectedAgentControl: AgentControl? = nil,
        portPublisher injectedPortPublisher: PortPublisher? = nil,
        containerActivityProbe: @escaping DockerContainerActivityProbe = { configuration in
            if let dockerdSocketPath = configuration.dockerdSocketPath {
                return DockerEngineProbe.containerActivity(socketPath: dockerdSocketPath)
            }
            return DockerEngineProbe.containerActivity(
                    forwardSocketPath: configuration.forwardSocketPath,
                    cid: configuration.cid,
                    dockerPort: configuration.dockerPort
                )
        },
        dockerReadyWaiter: @escaping DockerReadyWaiter = { configuration, timeout in
            if let dockerdSocketPath = configuration.dockerdSocketPath {
                return DockerEngineProbe.waitUntilReady(socketPath: dockerdSocketPath, timeout: timeout)
            }
            return DockerEngineProbe.waitUntilReady(
                forwardSocketPath: configuration.forwardSocketPath,
                cid: configuration.cid,
                dockerPort: configuration.dockerPort,
                timeout: timeout
            )
        }
    ) {
        self.configuration = configuration
        self.containerActivityProbe = containerActivityProbe
        self.dockerReadyWaiter = dockerReadyWaiter
        self.idleController = idleController
        self.socket = DorySocket(home: configuration.home)
        if let injectedAgentControl {
            self.agentControl = injectedAgentControl
            self.portPublisher = injectedPortPublisher ?? PortPublisher()
        } else if let agentConfiguration = configuration.agentControl {
            self.agentControl = AgentControl(configuration: agentConfiguration)
            self.portPublisher = PortPublisher()
        } else {
            self.agentControl = nil
            self.portPublisher = nil
        }
        cleanupStaleHelpers()
    }

    public var socketPath: String {
        socket.path
    }

    public func status() -> DockerTierStatus {
        lock.lock()
        defer { lock.unlock() }
        return DockerTierStatus(
            state: state,
            socketPath: socket.path,
            hvPID: helperProcess?.pid,
            lastError: lastError
        )
    }

    /// Publish the Docker socket and activity listener without starting the heavy VM.
    ///
    /// This is doryd's lightweight launch shape: Docker clients can connect to `dory.sock`
    /// immediately, and the app or the first meaningful Docker request promotes it to a live helper.
    public func armSleeping() throws {
        idleController?.beginControlOperation()
        defer { idleController?.endControlOperation() }

        lock.lock()
        if dataplane != nil {
            if state == .stopped {
                state = .sleeping
                idleController?.setSleeping(true)
            }
            lock.unlock()
            return
        }
        guard idleController != nil,
              configuration.activitySocketPath != nil,
              configuration.hasManagedHelper else {
            lock.unlock()
            throw TierError.sleepingDataplaneRequiresWakeSupport
        }
        state = .starting
        lastError = nil
        lock.unlock()

        do {
            let resources = try startDataplane()
            lock.lock()
            dataplane = resources.handle
            activityServer = resources.activityServer
            helperProcess = nil
            state = .sleeping
            wakeTask = nil
            lastError = nil
            idleController?.setSleeping(true)
            lock.unlock()
        } catch {
            tearDown(markStopped: false)
            lock.lock()
            state = .failed
            lastError = "\(error)"
            lock.unlock()
            idleController?.setSleeping(false)
            throw error
        }
    }

    public func start() throws {
        idleController?.beginControlOperation()
        defer { idleController?.endControlOperation() }

        lock.lock()
        if state == .starting {
            lock.unlock()
            throw TierError.alreadyRunning
        }
        if dataplane != nil {
            if state == .sleeping {
                lock.unlock()
                wakeSynchronously()
                try requireRunningAfterWake()
                return
            }
            lock.unlock()
            throw TierError.alreadyRunning
        }
        state = .starting
        lastError = nil
        lock.unlock()

        var startedHelper: (any DockerManagedProcess)?
        do {
            let helper = makeManagedProcess()
            try helper?.start()
            startedHelper = helper

            if configuration.hasManagedHelper,
               !dockerReadyWaiter(configuration, Self.freshStartReadyTimeout) {
                throw TierError.readyTimeout
            }

            let resources = try startDataplane()

            lock.lock()
            helperProcess = helper
            activityServer = resources.activityServer
            dataplane = resources.handle
            state = .running
            idleController?.setSleeping(false)
            lock.unlock()
        } catch {
            tearDown(markStopped: false, extraHelper: startedHelper)
            lock.lock()
            state = .failed
            lastError = "\(error)"
            lock.unlock()
            throw error
        }
    }

    private func requireRunningAfterWake() throws {
        lock.lock()
        let currentState = state
        let currentError = lastError
        lock.unlock()

        guard currentState == .running else {
            if currentError == TierError.readyTimeout.description {
                throw TierError.readyTimeout
            }
            throw TierError.wakeFailed(currentError ?? "docker tier is \(currentState.rawValue)")
        }
    }

    public func stop() {
        idleController?.beginControlOperation()
        defer { idleController?.endControlOperation() }
        tearDown(markStopped: true)
    }

    @discardableResult
    public func cleanupStaleHelpers() -> [Int32] {
        var killed: [Int32] = []
        if let hvConfiguration = configuration.hvProcess,
           let stateDirectory = HelperProcessJanitor.stateDirectoryArgument(
            in: ([hvConfiguration.executablePath] + hvConfiguration.arguments).joined(separator: " ")
           ) {
            killed.append(contentsOf: HelperProcessJanitor.terminateStaleHelpers(
                executablePath: hvConfiguration.executablePath,
                stateDirectory: stateDirectory
            ))
        }
        if let vmmConfiguration = configuration.vmmProcess {
            killed.append(contentsOf: HelperProcessJanitor.terminateStaleHelpers(
                executablePath: vmmConfiguration.executablePath,
                stateDirectory: vmmConfiguration.stateDirectory
            ))
        }
        return killed
    }

    public func sleepForIdle(idleAfter seconds: TimeInterval, now: Date = Date()) -> Bool {
        sleepForIdle(idleAfter: seconds, now: now, activity: containerActivityProbe(configuration))
    }

    private func sleepForIdle(
        idleAfter seconds: TimeInterval,
        now: Date,
        activity: DockerContainerActivity
    ) -> Bool {
        guard let idleController, configuration.hasManagedHelper else {
            return false
        }

        let claimedSleep: Bool
        switch activity {
        case .empty:
            claimedSleep = idleController.claimSleepForEmptyEngine(idleAfter: seconds, now: now)
        case .active, .unknown:
            claimedSleep = idleController.claimSleepIfIdle(idleAfter: seconds, now: now)
        }
        guard claimedSleep else {
            return false
        }

        lock.lock()
        guard state == .running, let currentHelper = helperProcess else {
            lock.unlock()
            idleController.setSleeping(false)
            return false
        }
        let idleSnapshot = idleController.snapshot
        let staleRequestAllowed = activity == .empty
        guard (idleSnapshot.activeRequests == 0 || staleRequestAllowed),
              idleSnapshot.controlOperations == 0 else {
            lock.unlock()
            idleController.setSleeping(false)
            return false
        }
        state = .sleeping
        wakeTask = nil

        switch activity {
        case .empty:
            helperProcess = nil
            lastError = nil
            agentControl?.disconnect()
            currentHelper.stop()
            lock.unlock()
            return true
        case .active, .unknown:
            agentControl?.disconnect()
            guard currentHelper.suspend() else {
                state = .running
                lastError = TierError.suspendFailed(pid: currentHelper.pid).description
                lock.unlock()
                idleController.setSleeping(false)
                return false
            }
            lastError = nil
            lock.unlock()
            return true
        }
    }

    public func prepareForHostSleep(now: Date = Date()) -> HostSleepActionResult {
        lock.lock()
        let currentState = state
        lock.unlock()
        guard currentState == .running else {
            return HostSleepActionResult(
                name: "docker",
                attempted: false,
                slept: false,
                detail: "docker state=\(currentState.rawValue)"
            )
        }

        let activity = containerActivityProbe(configuration)
        switch activity {
        case .empty:
            let slept = sleepForIdle(idleAfter: 0, now: now, activity: activity)
            return HostSleepActionResult(
                name: "docker",
                attempted: true,
                slept: slept,
                detail: slept ? "docker engine empty; helper stopped for host sleep" : "docker engine empty; sleep claim rejected"
            )
        case .active(let count):
            return HostSleepActionResult(
                name: "docker",
                attempted: false,
                slept: false,
                detail: "docker has \(count) active container(s)"
            )
        case .unknown(let reason):
            return HostSleepActionResult(
                name: "docker",
                attempted: false,
                slept: false,
                detail: "docker activity unknown: \(reason)"
            )
        }
    }

    public func refreshPublishedPorts() throws -> PortPublishDiff? {
        guard let agentControl, let portPublisher else { return nil }
        lock.lock()
        let currentState = state
        lock.unlock()
        guard currentState == .running else { return nil }
        return try portPublisher.refresh(from: agentControl)
    }

    public func currentPublishedPorts() -> [DoryListenPort]? {
        guard let portPublisher else { return nil }
        return portPublisher.current
    }

    public func currentDockerPublishedPorts() -> [DoryListenPort]? {
        lock.lock()
        let currentState = state
        lock.unlock()
        guard currentState == .running else { return [] }

        let summaries: DockerContainerList
        if let dockerdSocketPath = configuration.dockerdSocketPath {
            summaries = DockerEngineProbe.containerSummaries(socketPath: dockerdSocketPath)
        } else {
            summaries = DockerEngineProbe.containerSummaries(
                forwardSocketPath: configuration.forwardSocketPath,
                cid: configuration.cid,
                dockerPort: configuration.dockerPort
            )
        }
        switch summaries {
        case let .ok(containers):
            var ports = Set<DoryListenPort>()
            for container in containers where container.isRunning {
                for port in container.ports {
                    guard let listenPort = Self.dockerPublishedPort(port) else { continue }
                    ports.insert(listenPort)
                }
            }
            return ports.sorted {
                if $0.port == $1.port { return $0.protocol < $1.protocol }
                return $0.port < $1.port
            }
        case .unavailable:
            return nil
        }
    }

    public func containerSummariesForIdle() -> DockerContainerList {
        lock.lock()
        let currentState = state
        let currentError = lastError
        lock.unlock()
        switch currentState {
        case .running:
            if let dockerdSocketPath = configuration.dockerdSocketPath {
                return DockerEngineProbe.containerSummaries(socketPath: dockerdSocketPath)
            }
            return DockerEngineProbe.containerSummaries(
                    forwardSocketPath: configuration.forwardSocketPath,
                    cid: configuration.cid,
                    dockerPort: configuration.dockerPort
                )
        case .failed:
            return .unavailable(currentError ?? "docker tier failed")
        case .stopped, .starting, .sleeping:
            return .ok([])
        }
    }

    public func agentInfo() throws -> DoryAgentInfo? {
        guard let agentControl else { return nil }
        lock.lock()
        let currentState = state
        lock.unlock()
        guard currentState == .running else { return nil }
        return try agentControl.info()
    }

    public func telemetry() throws -> DoryTelemetry? {
        guard let agentControl else { return nil }
        lock.lock()
        let currentState = state
        lock.unlock()
        guard currentState == .running else { return nil }
        return try agentControl.telemetry()
    }

    public func memorySnapshot(
        id: String = "docker",
        minimumTargetMB: UInt64 = 512,
        maximumTargetMB: UInt64? = nil
    ) throws -> GuestMemorySnapshot? {
        guard let telemetry = try telemetry() else { return nil }
        return GuestMemorySnapshot(
            id: id,
            kind: .docker,
            telemetry: telemetry,
            minimumTargetMB: minimumTargetMB,
            maximumTargetMB: maximumTargetMB,
            canBalloon: false
        )
    }

    private static func dockerPublishedPort(_ port: DockerContainerPort) -> DoryListenPort? {
        guard let publicPort = port.publicPort,
              (1...65_535).contains(publicPort),
              let portNumber = UInt32(exactly: publicPort) else {
            return nil
        }
        switch (port.type ?? "tcp").lowercased() {
        case "tcp", "tcp6":
            return DoryListenPort(protocol: "tcp", port: portNumber)
        case "udp", "udp6":
            return DoryListenPort(protocol: "udp", port: portNumber)
        default:
            return nil
        }
    }

    public func syncAgentClock(now: Date = Date()) -> AgentClockSyncResult {
        // Reached on host wake via the wake coordinator's clock syncers. Reset the idle
        // clock the way the engine-wake path does: a long host sleep otherwise leaves
        // lastActivity far in the past, so the idle scheduler would sleep a just-woken
        // engine almost immediately.
        idleController?.touch(now: now)
        guard let agentControl else {
            return AgentClockSyncResult(name: "docker", attempted: false, synced: false)
        }
        lock.lock()
        let currentState = state
        lock.unlock()
        guard currentState == .running else {
            return AgentClockSyncResult(name: "docker", attempted: false, synced: false)
        }
        do {
            let synced = try agentControl.clockSync(now: now)
            if synced {
                lock.lock()
                lastError = nil
                lock.unlock()
            }
            return AgentClockSyncResult(name: "docker", attempted: true, synced: synced)
        } catch {
            lock.lock()
            lastError = "agent clock sync failed: \(error)"
            lock.unlock()
            return AgentClockSyncResult(
                name: "docker",
                attempted: true,
                synced: false,
                error: "\(error)"
            )
        }
    }

    public func ensureAwake() async {
        guard let task = wakeTaskForEnsureAwake() else { return }
        await task.value
    }

    private func wakeTaskForEnsureAwake() -> Task<Void, Never>? {
        lock.lock()
        if state != .sleeping {
            lock.unlock()
            return nil
        }
        if let wakeTask {
            lock.unlock()
            return wakeTask
        }
        let task = Task.detached { [weak self] in
            if let self {
                self.wakeSynchronously()
            }
        }
        wakeTask = task
        lock.unlock()
        return task
    }

    private func wakeSynchronously() {
        idleController?.beginControlOperation()
        defer { idleController?.endControlOperation() }

        var shouldSyncClock = false
        lock.lock()
        if state == .sleeping, let currentHelper = helperProcess, currentHelper.isRunning {
            guard currentHelper.resume() else {
                lastError = TierError.resumeFailed(pid: currentHelper.pid).description
                wakeTask = nil
                lock.unlock()
                idleController?.setSleeping(true)
                return
            }
            state = .starting
            lastError = nil
            lock.unlock()

            let ready = dockerReadyWaiter(configuration, Self.resumeReadyTimeout)

            lock.lock()
            guard state == .starting else {
                wakeTask = nil
                lock.unlock()
                return
            }
            if ready {
                state = .running
                lastError = nil
                wakeTask = nil
                lock.unlock()
                idleController?.setSleeping(false)
                idleController?.touch()
                shouldSyncClock = true
                if shouldSyncClock {
                    _ = syncAgentClockAfterWake()
                }
                return
            }
            lastError = TierError.readyTimeout.description
            wakeTask = nil
            lock.unlock()
            idleController?.setSleeping(true)
            return
        }
        guard state == .sleeping else {
            wakeTask = nil
            lock.unlock()
            return
        }
        state = .starting
        lastError = nil
        lock.unlock()

        do {
            let helper = try startFreshManagedProcess()
            lock.lock()
            guard state == .starting else {
                // Torn down while the fresh helper was starting; discard it rather than
                // adopt it into a stopped tier.
                wakeTask = nil
                lock.unlock()
                helper?.stop()
                return
            }
            helperProcess = helper
            lock.unlock()

            let ready = dockerReadyWaiter(configuration, Self.freshStartReadyTimeout)

            lock.lock()
            guard state == .starting else {
                wakeTask = nil
                lock.unlock()
                helper?.stop()
                return
            }
            if ready {
                helperProcess = helper
                state = .running
                lastError = nil
                wakeTask = nil
                lock.unlock()
                idleController?.setSleeping(false)
                idleController?.touch()
                shouldSyncClock = true
                if shouldSyncClock {
                    _ = syncAgentClockAfterWake()
                }
            } else {
                helperProcess = nil
                state = .sleeping
                lastError = TierError.readyTimeout.description
                wakeTask = nil
                lock.unlock()
                helper?.stop()
                idleController?.setSleeping(true)
            }
        } catch {
            lock.lock()
            state = .sleeping
            lastError = "\(error)"
            wakeTask = nil
            lock.unlock()
            idleController?.setSleeping(true)
        }
    }

    private func syncAgentClockAfterWake(timeout: TimeInterval = 5) -> AgentClockSyncResult {
        let deadline = Date().addingTimeInterval(timeout)
        var result = syncAgentClock()
        while result.attempted, !result.synced, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.25)
            result = syncAgentClock()
        }
        return result
    }

    private func startFreshManagedProcess() throws -> (any DockerManagedProcess)? {
        let helper = makeManagedProcess()
        try helper?.start()
        return helper
    }

    private func makeManagedProcess() -> (any DockerManagedProcess)? {
        if let vmmConfiguration = configuration.vmmProcess {
            return VmmDockerProcess(configuration: vmmConfiguration)
        }
        if let hvConfiguration = configuration.hvProcess {
            return HvProcess(configuration: hvConfiguration)
        }
        return nil
    }

    private func startActivityServerIfNeeded() throws -> DataplaneActivityServer? {
        guard let idleController, let path = configuration.activitySocketPath else { return nil }
        let server = DataplaneActivityServer(path: path, idle: idleController) { [weak self] in
            await self?.ensureAwake()
        }
        try server.start()
        return server
    }

    private struct DataplaneResources {
        var handle: DoryDataplaneHandle
        var activityServer: DataplaneActivityServer?
    }

    private func startDataplane() throws -> DataplaneResources {
        let server = try startActivityServerIfNeeded()
        do {
            let fd = try socket.bind()
            let handle: DoryDataplaneHandle
            if let dockerdSocketPath = configuration.dockerdSocketPath {
                if let activitySocketPath = configuration.activitySocketPath, idleController != nil {
                    handle = DoryCore.startDockerDataplane(
                        listenFD: fd,
                        dockerdSocketPath: dockerdSocketPath,
                        gpuSupported: configuration.gpuSupported,
                        activitySocketPath: activitySocketPath
                    )
                } else {
                    handle = DoryCore.startDockerDataplane(
                        listenFD: fd,
                        dockerdSocketPath: dockerdSocketPath,
                        gpuSupported: configuration.gpuSupported
                    )
                }
            } else {
                if let activitySocketPath = configuration.activitySocketPath, idleController != nil {
                    handle = DoryCore.startDockerForwardDataplane(
                        listenFD: fd,
                        forwardSocketPath: configuration.forwardSocketPath,
                        cid: configuration.cid,
                        port: configuration.dockerPort,
                        gpuSupported: configuration.gpuSupported,
                        activitySocketPath: activitySocketPath
                    )
                } else {
                    handle = DoryCore.startDockerForwardDataplane(
                        listenFD: fd,
                        forwardSocketPath: configuration.forwardSocketPath,
                        cid: configuration.cid,
                        port: configuration.dockerPort,
                        gpuSupported: configuration.gpuSupported
                    )
                }
            }
            return DataplaneResources(handle: handle, activityServer: server)
        } catch {
            server?.stop()
            throw error
        }
    }

    private func tearDown(markStopped: Bool, extraHelper: (any DockerManagedProcess)? = nil) {
        let currentDataplane: DoryDataplaneHandle?
        let currentHelper: (any DockerManagedProcess)?
        let currentActivityServer: DataplaneActivityServer?
        let inFlightWake: Task<Void, Never>?
        lock.lock()
        currentDataplane = dataplane
        currentHelper = helperProcess ?? extraHelper
        currentActivityServer = activityServer
        inFlightWake = wakeTask
        dataplane = nil
        helperProcess = nil
        activityServer = nil
        wakeTask = nil
        if markStopped {
            state = .stopped
            idleController?.setSleeping(false)
        }
        lock.unlock()

        // Cancel any in-flight wake so it stops resuming; it also re-checks state under
        // the lock and discards a freshly started helper now that state != .sleeping.
        inFlightWake?.cancel()

        currentDataplane?.shutdown()
        currentActivityServer?.stop()
        agentControl?.disconnect()
        currentHelper?.stop()
        unlink(socket.path)
    }

    deinit {
        stop()
    }
}

extension DockerTier: HostSleepHandling, WakeClockSyncing {}
