import Foundation

enum HostToolScan {
    static func matchedIDs(brewLeaves: [String], presentCommands: Set<String>) -> Set<String> {
        let brewSet = Set(brewLeaves)
        var result = Set<String>()
        for item in ProvisionCatalog.all {
            if let command = item.detectCommand, presentCommands.contains(command) {
                result.insert(item.id)
                continue
            }
            if !item.brewNames.isEmpty, !brewSet.isDisjoint(with: item.brewNames) {
                result.insert(item.id)
            }
        }
        return result
    }

    static func detect() async -> Set<String> {
        let scan = await Task.detached { () -> (Set<String>, [String]) in
            (presentCommands(), brewLeaves())
        }.value
        return matchedIDs(brewLeaves: scan.1, presentCommands: scan.0)
    }

    private static func presentCommands() -> Set<String> {
        let commands = Set(ProvisionCatalog.all.compactMap(\.detectCommand))
        guard !commands.isEmpty else { return [] }
        let list = commands.map { "'\($0)'" }.joined(separator: " ")
        let script = "for c in \(list); do command -v \"$c\" >/dev/null 2>&1 && printf '%s\\n' \"$c\"; done"
        return Set(runLoginShell(script).split(separator: "\n").map(String.init))
    }

    private static func brewLeaves() -> [String] {
        runLoginShell("brew leaves 2>/dev/null").split(separator: "\n").map(String.init)
    }

    private static func runLoginShell(_ script: String) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-lc", script]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return "" }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(data: data, encoding: .utf8) ?? ""
    }
}
