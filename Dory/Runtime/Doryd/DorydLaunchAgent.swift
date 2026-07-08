import Darwin
import Foundation

enum DorydLaunchAgent {
    static let label = "dev.dory.doryd"

    struct Status: Sendable, Equatable {
        var loaded: Bool
        var plistPath: String?
        var programPath: String?
    }

    enum Decision: Sendable, Equatable {
        case unavailable(String)
        case upToDate
        case bootstrap
        case replace
    }

    struct CommandResult: Sendable, Equatable {
        var status: Int32
        var stdout: String
        var stderr: String

        var ok: Bool { status == 0 }
    }

    typealias Runner = @Sendable ([String]) async -> CommandResult

    static func ensureCurrent(
        bundle: Bundle = .main,
        runner: @escaping Runner = runLaunchctl
    ) async -> Bool {
        guard let current = currentInstall(bundle: bundle) else { return false }
        let uid = getuid()
        let service = serviceTarget(uid: uid)
        let print = await runner(["print", service])
        let status = print.ok ? parseStatus(print.stdout) : nil

        switch decision(status: status, currentPlist: current.plistPath, currentProgram: current.programPath) {
        case .upToDate:
            return true
        case .bootstrap:
            let bootstrapped = await runner(["bootstrap", domainTarget(uid: uid), current.plistPath])
            if bootstrapped.ok {
                _ = await runner(["kickstart", "-k", service])
            }
            return bootstrapped.ok
        case .replace:
            _ = await runner(["bootout", service])
            let bootstrapped = await runner(["bootstrap", domainTarget(uid: uid), current.plistPath])
            if bootstrapped.ok {
                _ = await runner(["kickstart", "-k", service])
            }
            return bootstrapped.ok
        case .unavailable:
            return false
        }
    }

    static func decision(status: Status?, currentPlist: String?, currentProgram: String?) -> Decision {
        guard let currentPlist, !currentPlist.isEmpty,
              let currentProgram, !currentProgram.isEmpty else {
            return .unavailable("current doryd LaunchAgent is not bundled")
        }
        guard let status, status.loaded else {
            return .bootstrap
        }
        guard normalize(status.programPath) == normalize(currentProgram),
              normalize(status.plistPath) == normalize(currentPlist) else {
            return .replace
        }
        return .upToDate
    }

    static func parseStatus(_ output: String) -> Status {
        Status(
            loaded: output.contains("state = running") || output.contains("job state = running"),
            plistPath: value(for: "path", in: output),
            programPath: value(for: "program", in: output)
        )
    }

    static func currentInstall(bundle: Bundle) -> (plistPath: String, programPath: String)? {
        let bundleURL = bundle.bundleURL
        let plist = bundleURL.appendingPathComponent("Contents/Resources/\(label).plist").path
        let program = bundleURL.appendingPathComponent("Contents/Helpers/doryd").path
        let fileManager = FileManager.default
        guard fileManager.isReadableFile(atPath: plist),
              fileManager.isExecutableFile(atPath: program) else {
            return nil
        }
        return (plist, program)
    }

    static func serviceTarget(uid: uid_t = getuid()) -> String {
        "gui/\(uid)/\(label)"
    }

    static func domainTarget(uid: uid_t = getuid()) -> String {
        "gui/\(uid)"
    }

    private static func value(for key: String, in output: String) -> String? {
        for rawLine in output.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix("\(key) = ") else { continue }
            let value = line.dropFirst(key.count + 3).trimmingCharacters(in: .whitespacesAndNewlines)
            return value.isEmpty ? nil : value
        }
        return nil
    }

    private static func normalize(_ path: String?) -> String? {
        guard let path else { return nil }
        return URL(fileURLWithPath: path).standardizedFileURL.path
    }

    private static func runLaunchctl(_ arguments: [String]) async -> CommandResult {
        await Task.detached(priority: .utility) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
            process.arguments = arguments
            let stdout = Pipe()
            let stderr = Pipe()
            process.standardOutput = stdout
            process.standardError = stderr
            do {
                try process.run()
            } catch {
                return CommandResult(status: 127, stdout: "", stderr: "\(error)")
            }
            let outData = stdout.fileHandleForReading.readDataToEndOfFile()
            let errData = stderr.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return CommandResult(
                status: process.terminationStatus,
                stdout: String(decoding: outData, as: UTF8.self),
                stderr: String(decoding: errData, as: UTF8.self)
            )
        }.value
    }
}
