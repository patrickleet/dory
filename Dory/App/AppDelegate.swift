import AppKit
import Darwin

final class DoryAppDelegate: NSObject, NSApplicationDelegate {
    private static let mainWindowIdentifier = NSUserInterfaceItemIdentifier("dory.main-window")
    private static let instanceLock = NSLock()
    private static var instanceLockFD: Int32 = -1

    static var isTestHost: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
            || ProcessInfo.processInfo.environment["XCTestSessionIdentifier"] != nil
            || ProcessInfo.processInfo.environment["DORY_UI_TEST"] == "1"
    }

    static func exitDuplicateInstanceIfNeeded() {
        guard !isTestHost, let bundleIdentifier = Bundle.main.bundleIdentifier else { return }
        guard acquireInstanceLock() else {
            runningInstance(bundleIdentifier: bundleIdentifier)?.activate(options: [.activateAllWindows])
            exit(EXIT_SUCCESS)
        }
        terminateStaleInstances(bundleIdentifier: bundleIdentifier)
    }

    nonisolated static func hasOtherInstance(currentProcessIdentifier: pid_t, candidates: [pid_t]) -> Bool {
        candidates.contains { $0 > 0 && $0 != currentProcessIdentifier }
    }

    nonisolated static func staleInstancePIDs(currentProcessIdentifier: pid_t, candidates: [pid_t]) -> [pid_t] {
        candidates.filter { $0 > 0 && $0 != currentProcessIdentifier }
    }

    nonisolated static func instanceLockPath(home: String) -> String {
        "\(home)/.dory/dory-app.lock"
    }

    private static func acquireInstanceLock(home: String = NSHomeDirectory()) -> Bool {
        instanceLock.lock()
        defer { instanceLock.unlock() }
        if instanceLockFD >= 0 { return true }

        let path = instanceLockPath(home: home)
        try? FileManager.default.createDirectory(
            atPath: (path as NSString).deletingLastPathComponent,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let fd = open(path, O_WRONLY | O_CREAT, 0o600)
        guard fd >= 0 else { return true }
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            close(fd)
            return false
        }
        instanceLockFD = fd
        return true
    }

    private static func runningInstance(bundleIdentifier: String) -> NSRunningApplication? {
        let current = getpid()
        let candidates = NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier)
            .filter { !$0.isTerminated && $0.processIdentifier != current }
        return candidates.first(where: { $0.isActive }) ?? candidates.first
    }

    private static func terminateStaleInstances(bundleIdentifier: String) {
        let current = getpid()
        let stale = NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier)
            .filter { !$0.isTerminated && $0.processIdentifier != current }
        guard !stale.isEmpty else { return }
        stale.forEach { $0.terminate() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            for app in stale where !app.isTerminated {
                app.forceTerminate()
            }
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard !Self.isTestHost else { return }
        NSApp.setActivationPolicy(.accessory)
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(500))
            Self.closeDuplicateMainWindows()
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        Task { @MainActor in Self.closeDuplicateMainWindows() }
    }

    func applicationWillTerminate(_ notification: Notification) {
        Self.instanceLock.lock()
        let fd = Self.instanceLockFD
        Self.instanceLockFD = -1
        Self.instanceLock.unlock()
        if fd >= 0 {
            flock(fd, LOCK_UN)
            close(fd)
        }
    }

    @MainActor static func markMainWindow(_ window: NSWindow) {
        window.identifier = mainWindowIdentifier
        window.title = "Dory"
        closeDuplicateMainWindows(keeping: window)
    }

    @MainActor static func hasVisibleMainWindow() -> Bool {
        NSApp.windows.contains { $0.identifier == mainWindowIdentifier && $0.isVisible }
    }

    @MainActor static func closeDuplicateMainWindows(keeping preferred: NSWindow? = nil) {
        let windows = NSApp.windows.filter { $0.identifier == mainWindowIdentifier }
        guard windows.count > 1 else { return }
        let keeper = preferred ?? windows.first(where: { $0.isKeyWindow }) ?? windows.first
        for window in windows where window !== keeper {
            window.close()
        }
    }
}

enum DoryActivation {
    @MainActor static func setForeground(_ foreground: Bool) {
        guard !DoryAppDelegate.isTestHost else { return }
        let target: NSApplication.ActivationPolicy = foreground ? .regular : .accessory
        // Every setActivationPolicy call re-inserts the MenuBarExtra status item, so a redundant call
        // (already .regular, asked for .regular) makes the menu-bar icon flicker/duplicate. Only flip
        // when the policy actually changes.
        if NSApp.activationPolicy() != target {
            NSApp.setActivationPolicy(target)
        }
        if foreground { NSApp.activate(ignoringOtherApps: true) }
    }
}
