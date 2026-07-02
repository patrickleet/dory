import Testing
@testable import Dory

struct KubeVersionCatalogTests {
    @Test func catalogIsNonEmptyNewestFirst() {
        #expect(!KubeVersionCatalog.all.isEmpty)
        #expect(KubeVersionCatalog.latest == KubeVersionCatalog.all[0])
    }

    @Test func tagsAreWellFormedK3sImages() {
        for version in KubeVersionCatalog.all {
            #expect(version.tag.hasPrefix("v"))
            #expect(version.tag.contains("-k3s"))
            #expect(version.image == "rancher/k3s:\(version.tag)")
        }
    }

    @Test func minorsAreDistinct() {
        let minors = KubeVersionCatalog.all.map(\.minor)
        #expect(Set(minors).count == minors.count)
    }

    @Test func versionForKnownTagResolves() {
        let known = KubeVersionCatalog.all[1]
        #expect(KubeVersionCatalog.version(forTag: known.tag) == known)
    }

    @Test func versionForNilFallsBackToLatest() {
        #expect(KubeVersionCatalog.version(forTag: nil) == KubeVersionCatalog.latest)
    }

    @Test func versionForUnknownTagFallsBackToLatest() {
        #expect(KubeVersionCatalog.version(forTag: "v0.0.0-nope") == KubeVersionCatalog.latest)
    }
}
