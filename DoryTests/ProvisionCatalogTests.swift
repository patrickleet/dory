import Testing
@testable import Dory

struct ProvisionCatalogTests {
    @Test func idsAreUniqueAcrossSections() {
        let ids = ProvisionCatalog.all.map(\.id)
        #expect(Set(ids).count == ids.count)
    }

    @Test func everyItemHasDisplayAndExactlyOneInstallMethod() {
        for item in ProvisionCatalog.all {
            #expect(!item.display.isEmpty, "\(item.id) display")
            let hasApt = !item.aptNames.isEmpty
            let hasCustom = (item.custom?.isEmpty == false)
            #expect(hasApt != hasCustom, "\(item.id) must be apt XOR custom")
        }
    }

    @Test func runtimesResolveDevRecipes() {
        #expect(ProvisionCatalog.runtimes.count == 6)
        for runtime in ProvisionCatalog.runtimes {
            #expect(DevRecipe.forID(runtime.id) != nil, "\(runtime.id) recipe")
            #expect(runtime.section == .runtime)
        }
    }

    @Test func itemLookupRoundTrips() {
        for item in ProvisionCatalog.all {
            #expect(ProvisionCatalog.item(item.id)?.id == item.id)
        }
    }

    @Test func toolsIncludeDockerAndKubectl() {
        #expect(ProvisionCatalog.item("docker-cli") != nil)
        #expect(ProvisionCatalog.item("kubectl") != nil)
    }

    @Test func packageSectionIsSearchableApt() {
        #expect(ProvisionCatalog.packages.count >= 40)
        for pkg in ProvisionCatalog.packages {
            #expect(pkg.section == .package)
            #expect(!pkg.aptNames.isEmpty)
        }
    }
}
