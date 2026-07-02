import Foundation
import Testing
@testable import Dory

@MainActor
struct AppStoreKubernetesVersionTests {
    @Test func defaultsToCatalogLatest() {
        let store = AppStore()
        #expect(store.kubernetesVersionTag == KubeVersionCatalog.latest.tag)
    }

    @Test func setVersionUpdatesTagAndResolves() {
        let store = AppStore()
        let target = KubeVersionCatalog.all[2]
        store.setKubernetesVersion(target)
        #expect(store.kubernetesVersionTag == target.tag)
        #expect(KubeVersionCatalog.version(forTag: store.kubernetesVersionTag) == target)
        #expect(KubeVersionCatalog.version(forTag: store.kubernetesVersionTag).image == target.image)
    }
}
