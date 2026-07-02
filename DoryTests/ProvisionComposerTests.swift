import Foundation
import Testing
@testable import Dory

struct ProvisionComposerTests {
    @Test func emptySelectionYieldsNilRecipe() {
        #expect(ProvisionComposer.composedRecipe([]) == nil)
    }

    @Test func stableHashIsDeterministic() {
        #expect(ProvisionComposer.stableHash("git,jq,node") == ProvisionComposer.stableHash("git,jq,node"))
        #expect(ProvisionComposer.stableHash("a") != ProvisionComposer.stableHash("b"))
    }

    @Test func recipeIDIsOrderIndependent() {
        let git = ProvisionCatalog.item("git")!
        let jq = ProvisionCatalog.item("jq")!
        let node = ProvisionCatalog.item("node")!
        let a = ProvisionComposer.composedRecipe([git, jq, node])
        let b = ProvisionComposer.composedRecipe([node, git, jq])
        #expect(a?.id == b?.id)
        #expect(a?.id.hasPrefix("custom-") == true)
    }

    @Test func composedInstallContainsAptNamesAndCustomSnippets() {
        let git = ProvisionCatalog.item("git")!
        let jq = ProvisionCatalog.item("jq")!
        let docker = ProvisionCatalog.item("docker-cli")!
        let install = ProvisionComposer.composedInstall([git, jq, docker])
        #expect(install.contains("git"))
        #expect(install.contains("jq"))
        #expect(install.contains("apt-get install -y --no-install-recommends"))
        #expect(install.contains("/usr/local/bin/docker"))
    }

    @Test func composedInstallIsOrderIndependent() {
        let git = ProvisionCatalog.item("git")!
        let node = ProvisionCatalog.item("node")!
        let docker = ProvisionCatalog.item("docker-cli")!
        #expect(ProvisionComposer.composedInstall([git, node, docker]) == ProvisionComposer.composedInstall([docker, git, node]))
    }

    @Test func runtimeOnlySelectionUsesItsInstall() {
        let node = ProvisionCatalog.item("node")!
        let recipe = ProvisionComposer.composedRecipe([node])
        #expect(recipe != nil)
        #expect(recipe?.install.contains("nodejs") == true)
    }

    @Test func aptNamesAreDedupedAndSorted() {
        let git = ProvisionCatalog.item("git")!
        let install = ProvisionComposer.composedInstall([git, git])
        let occurrences = install.components(separatedBy: " git").count - 1
        #expect(occurrences == 1)
    }
}
