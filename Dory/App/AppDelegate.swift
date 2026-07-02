import AppKit

final class DoryAppDelegate: NSObject, NSApplicationDelegate {
    static var isTestHost: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
            || ProcessInfo.processInfo.environment["XCTestSessionIdentifier"] != nil
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard !Self.isTestHost else { return }
        NSApp.setActivationPolicy(.accessory)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationWillTerminate(_ notification: Notification) {
        DockerContext.deactivateSync()
        SharedVMProvisioner.stopEngineDetached()
    }
}

enum DoryActivation {
    @MainActor static func setForeground(_ foreground: Bool) {
        guard !DoryAppDelegate.isTestHost else { return }
        NSApp.setActivationPolicy(foreground ? .regular : .accessory)
        if foreground { NSApp.activate(ignoringOtherApps: true) }
    }
}
