import Testing
@testable import Dory

struct HostToolScanTests {
    @Test func matchesByDetectCommand() {
        let matched = HostToolScan.matchedIDs(brewLeaves: [], presentCommands: ["node", "go"])
        #expect(matched.contains("node"))
        #expect(matched.contains("go"))
        #expect(!matched.contains("rust"))
    }

    @Test func matchesByBrewName() {
        let matched = HostToolScan.matchedIDs(brewLeaves: ["ripgrep", "fd", "jq"], presentCommands: [])
        #expect(matched.contains("ripgrep"))
        #expect(matched.contains("fd"))
        #expect(matched.contains("jq"))
    }

    @Test func silverSearcherBrewNameMapsToItsItem() {
        let matched = HostToolScan.matchedIDs(brewLeaves: ["the_silver_searcher"], presentCommands: [])
        #expect(matched.contains("the-silver-searcher"))
    }

    @Test func unknownInputsMatchNothing() {
        let matched = HostToolScan.matchedIDs(brewLeaves: ["some-obscure-formula"], presentCommands: ["nonexistent-cmd"])
        #expect(matched.isEmpty)
    }

    @Test func emptyInputsYieldEmpty() {
        #expect(HostToolScan.matchedIDs(brewLeaves: [], presentCommands: []).isEmpty)
    }
}
