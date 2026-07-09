import Foundation
import IOKit
import IOKit.pwr_mgt

public final class IOKitPowerEventSource: PowerEventSource, @unchecked Sendable {
    private let lock = NSLock()
    private var notifyPort: IONotificationPortRef?
    private var notifier: io_object_t = 0
    private var rootPort: io_connect_t = 0
    private var onWillSleep: (@Sendable () -> Void)?
    private var onWake: (@Sendable () -> Void)?
    private var runLoop: CFRunLoop?
    private var workerThread: Thread?
    private var cancelled = false
    private let exited = DispatchSemaphore(value: 0)

    public init() {}

    public func start(
        onWillSleep: @escaping @Sendable () -> Void,
        onWake: @escaping @Sendable () -> Void
    ) throws {
        lock.lock()
        if rootPort != 0 {
            self.onWillSleep = onWillSleep
            self.onWake = onWake
            lock.unlock()
            return
        }
        self.onWillSleep = onWillSleep
        self.onWake = onWake
        cancelled = false
        lock.unlock()

        let start = PowerObserverStart()
        let thread = Thread { [weak self] in
            self?.runPowerObserver(start: start)
        }
        thread.name = "dev.dory.doryd.power-observer"
        lock.lock()
        workerThread = thread
        lock.unlock()
        thread.start()

        guard start.wait(timeout: 5) else {
            stop()
            throw PowerObserverError.registrationFailed
        }
        if let error = start.error {
            stop()
            throw error
        }
    }

    public func stop() {
        lock.lock()
        cancelled = true
        let worker = workerThread
        workerThread = nil
        let localRunLoop = runLoop
        lock.unlock()

        // Wake the worker's run loop so CFRunLoopRun() returns and the worker tears down
        // the IOKit resources on the same thread that created them.
        if let localRunLoop {
            CFRunLoopStop(localRunLoop)
        }

        // Join the worker so no callback (which holds an unretained reference to self)
        // can run after stop() returns. Skip if we are already on the worker thread.
        if let worker, worker != Thread.current {
            _ = exited.wait(timeout: .now() + 5)
        }

        lock.lock()
        onWillSleep = nil
        onWake = nil
        lock.unlock()
    }

    private func runPowerObserver(start: PowerObserverStart) {
        var localNotifyPort: IONotificationPortRef?
        var localNotifier: io_object_t = 0
        let context = UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())
        let port = IORegisterForSystemPower(
            context,
            &localNotifyPort,
            powerCallback,
            &localNotifier
        )
        guard port != 0, let localNotifyPort else {
            start.complete(error: PowerObserverError.registrationFailed)
            exited.signal()
            return
        }

        // stop() may have run during the (up to 5s) registration; if so, tear the freshly
        // registered resources down here instead of leaking them and entering the loop.
        lock.lock()
        if cancelled {
            lock.unlock()
            teardownResources(notifyPort: localNotifyPort, notifier: localNotifier, rootPort: port, runLoop: nil, source: nil)
            start.complete(error: PowerObserverError.registrationFailed)
            exited.signal()
            return
        }
        let currentRunLoop = CFRunLoopGetCurrent()
        let source = IONotificationPortGetRunLoopSource(localNotifyPort).takeUnretainedValue()
        CFRunLoopAddSource(currentRunLoop, source, .commonModes)
        rootPort = port
        notifyPort = localNotifyPort
        notifier = localNotifier
        runLoop = currentRunLoop
        lock.unlock()

        start.complete(error: nil)
        CFRunLoopRun()

        // Run loop stopped by stop(): tear down on this thread, then release the join.
        lock.lock()
        let teardownNotifyPort = notifyPort
        let teardownNotifier = notifier
        let teardownRootPort = rootPort
        let teardownRunLoop = runLoop
        notifyPort = nil
        notifier = 0
        rootPort = 0
        runLoop = nil
        lock.unlock()
        teardownResources(
            notifyPort: teardownNotifyPort,
            notifier: teardownNotifier,
            rootPort: teardownRootPort,
            runLoop: teardownRunLoop,
            source: source
        )
        exited.signal()
    }

    private func teardownResources(
        notifyPort: IONotificationPortRef?,
        notifier: io_object_t,
        rootPort: io_connect_t,
        runLoop: CFRunLoop?,
        source: CFRunLoopSource?
    ) {
        if let notifyPort {
            if let runLoop, let source {
                CFRunLoopRemoveSource(runLoop, source, .commonModes)
            }
            IONotificationPortDestroy(notifyPort)
        }
        if notifier != 0 {
            IOObjectRelease(notifier)
        }
        if rootPort != 0 {
            IOServiceClose(rootPort)
        }
    }

    fileprivate func handle(messageType: UInt32, messageArgument: UnsafeMutableRawPointer?) {
        switch messageType {
        case ioMessageCanSystemSleep:
            allowPowerChange(messageArgument)
        case ioMessageSystemWillSleep:
            lock.lock()
            let callback = onWillSleep
            lock.unlock()
            callback?()
            allowPowerChange(messageArgument)
        case ioMessageSystemHasPoweredOn:
            lock.lock()
            let callback = onWake
            lock.unlock()
            callback?()
        default:
            break
        }
    }

    private func allowPowerChange(_ messageArgument: UnsafeMutableRawPointer?) {
        lock.lock()
        let port = rootPort
        lock.unlock()
        guard port != 0 else { return }
        IOAllowPowerChange(port, Int(bitPattern: messageArgument))
    }

    deinit {
        stop()
    }
}

public enum PowerObserverError: Error, Sendable, Equatable {
    case registrationFailed
}

private final class PowerObserverStart: @unchecked Sendable {
    private let semaphore = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var storedError: Error?

    var error: Error? {
        lock.lock()
        defer { lock.unlock() }
        return storedError
    }

    func complete(error: Error?) {
        lock.lock()
        storedError = error
        lock.unlock()
        semaphore.signal()
    }

    func wait(timeout seconds: TimeInterval) -> Bool {
        semaphore.wait(timeout: .now() + seconds) == .success
    }
}

private let powerCallback: IOServiceInterestCallback = { context, _, messageType, messageArgument in
    guard let context else { return }
    let source = Unmanaged<IOKitPowerEventSource>.fromOpaque(context).takeUnretainedValue()
    source.handle(messageType: messageType, messageArgument: messageArgument)
}

private let ioMessageCanSystemSleep: UInt32 = 0xE000_0270
private let ioMessageSystemWillSleep: UInt32 = 0xE000_0280
private let ioMessageSystemHasPoweredOn: UInt32 = 0xE000_0300
