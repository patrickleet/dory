import Foundation
import Testing
@testable import Dory

struct KubernetesProvisionerImageTests {
    @Test func defaultImageIsCatalogLatest() {
        #expect(KubernetesProvisioner.defaultImage == KubeVersionCatalog.latest.image)
    }

    @Test func createJSONInterpolatesTheGivenImage() {
        let image = KubeVersionCatalog.all[2].image
        let json = KubernetesProvisioner.createJSON(image: image)
        #expect(json.contains("\"Image\":\"\(image)\""))
        #expect(json.contains("\"server\""))
        #expect(json.contains("--disable=traefik"))
        #expect(json.contains("PortBindings"))
    }
}
