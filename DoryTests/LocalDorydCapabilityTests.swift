import Foundation
import Testing
@testable import Dory

struct LocalDorydCapabilityTests {
    @Test func localToolsCatalogExposesOnlyImplementedLocalCommands() throws {
        let capabilities = AppStore.localDorydCapabilityCatalog
        let ids = capabilities.map(\.id)

        #expect(Set(ids) == ["doctor", "agent-guide", "mcp", "sandbox", "wait", "events"])
        #expect(ids.count == Set(ids).count)

        for capability in capabilities {
            #expect(capability.command.hasPrefix("dory "))
            #expect(!capability.title.localizedCaseInsensitiveContains("Apple"))
            #expect(!capability.summary.localizedCaseInsensitiveContains("Apple"))
            #expect(!capability.command.localizedCaseInsensitiveContains("apple"))
            #expect(["Stable", "Preview"].contains(capability.status))
        }

        let stableIDs = Set(capabilities.filter { $0.status == "Stable" }.map(\.id))
        #expect(stableIDs == ["doctor", "agent-guide", "mcp", "wait", "events"])

        let sandbox = try #require(capabilities.first { $0.id == "sandbox" })
        #expect(sandbox.status == "Preview")
        #expect(sandbox.summary.contains("dorydctl"))
        #expect(sandbox.summary.contains("machine assets"))
    }

    @Test func settingsAndRuntimeLabelsDoNotAdvertiseUnsupportedAppleRuntime() {
        #expect(SettingsTab.allCases.contains(.localTools))
        #expect(SettingsTab.localTools.label == "Local Tools")
        #expect(RuntimeKind.appleContainer.displayName == "Unsupported runtime")
    }
}
