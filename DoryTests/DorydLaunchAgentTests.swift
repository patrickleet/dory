import Foundation
import Testing
@testable import Dory

struct DorydLaunchAgentTests {
    @Test func parseStatusExtractsProgramAndPlistPaths() {
        let status = DorydLaunchAgent.parseStatus(
            """
            gui/501/dev.dory.doryd = {
                path = /Applications/Dory.app/Contents/Resources/dev.dory.doryd.plist
                state = running
                program = /Applications/Dory.app/Contents/Helpers/doryd
            }
            """
        )

        #expect(status.loaded)
        #expect(status.plistPath == "/Applications/Dory.app/Contents/Resources/dev.dory.doryd.plist")
        #expect(status.programPath == "/Applications/Dory.app/Contents/Helpers/doryd")
    }

    @Test func decisionBootstrapsWhenJobIsMissing() {
        let decision = DorydLaunchAgent.decision(
            status: nil,
            currentPlist: "/Applications/Dory.app/Contents/Resources/dev.dory.doryd.plist",
            currentProgram: "/Applications/Dory.app/Contents/Helpers/doryd"
        )

        #expect(decision == .bootstrap)
    }

    @Test func decisionReplacesWhenLaunchdPointsAtOldAppBundle() {
        let status = DorydLaunchAgent.Status(
            loaded: true,
            plistPath: "/Users/me/Library/Developer/Xcode/DerivedData/Dory/Build/Products/Debug/Dory.app/Contents/Resources/dev.dory.doryd.plist",
            programPath: "/Users/me/Library/Developer/Xcode/DerivedData/Dory/Build/Products/Debug/Dory.app/Contents/Helpers/doryd"
        )

        let decision = DorydLaunchAgent.decision(
            status: status,
            currentPlist: "/Applications/Dory.app/Contents/Resources/dev.dory.doryd.plist",
            currentProgram: "/Applications/Dory.app/Contents/Helpers/doryd"
        )

        #expect(decision == .replace)
    }

    @Test func decisionLeavesCurrentLaunchdJobAlone() {
        let status = DorydLaunchAgent.Status(
            loaded: true,
            plistPath: "/Applications/Dory.app/Contents/Resources/dev.dory.doryd.plist",
            programPath: "/Applications/Dory.app/Contents/Helpers/doryd"
        )

        let decision = DorydLaunchAgent.decision(
            status: status,
            currentPlist: "/Applications/Dory.app/Contents/Resources/dev.dory.doryd.plist",
            currentProgram: "/Applications/Dory.app/Contents/Helpers/doryd"
        )

        #expect(decision == .upToDate)
    }

    @Test func ensureCurrentReplacesStaleLaunchdJob() async {
        let currentPlist = Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/\(DorydLaunchAgent.label).plist").path
        let currentProgram = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/doryd").path
        guard FileManager.default.isReadableFile(atPath: currentPlist),
              FileManager.default.isExecutableFile(atPath: currentProgram) else {
            return
        }

        let recorder = LaunchctlRecorder(printOutput:
            """
            gui/501/dev.dory.doryd = {
                path = /tmp/OldDory.app/Contents/Resources/dev.dory.doryd.plist
                state = running
                program = /tmp/OldDory.app/Contents/Helpers/doryd
            }
            """
        )

        let ok = await DorydLaunchAgent.ensureCurrent(bundle: .main) { arguments in
            recorder.run(arguments)
        }

        #expect(ok)
        #expect(recorder.commands.map { $0.first ?? "" } == ["print", "bootout", "bootstrap", "kickstart"])
    }
}

private final class LaunchctlRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private let printOutput: String
    private var recorded: [[String]] = []

    init(printOutput: String) {
        self.printOutput = printOutput
    }

    var commands: [[String]] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }

    func run(_ arguments: [String]) -> DorydLaunchAgent.CommandResult {
        lock.lock()
        recorded.append(arguments)
        lock.unlock()
        if arguments.first == "print" {
            return DorydLaunchAgent.CommandResult(status: 0, stdout: printOutput, stderr: "")
        }
        return DorydLaunchAgent.CommandResult(status: 0, stdout: "", stderr: "")
    }
}
