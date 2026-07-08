@testable import DorydKit
import XCTest

final class KubernetesServiceRouteProviderTests: XCTestCase {
    func testBuildsRoutesForClusterIPServices() {
        let routes = KubernetesServiceRouteProvider.routes(
            fromKubectlJSON: """
            {
              "items": [
                {
                  "metadata": {"name": "web", "namespace": "default"},
                  "spec": {"clusterIP": "10.43.1.7", "ports": [{"port": 80}]}
                },
                {
                  "metadata": {"name": "api", "namespace": "tools"},
                  "spec": {"clusterIP": "10.43.1.8", "ports": [{"port": 8080}]}
                },
                {
                  "metadata": {"name": "headless", "namespace": "default"},
                  "spec": {"clusterIP": "None", "ports": [{"port": 5432}]}
                }
              ]
            }
            """,
            proxyPort: 18_001,
            suffix: "Dory.Local."
        )

        XCTAssertEqual(routes, [
            DomainRoute(
                hostname: "api.tools.k8s.dory.local",
                address: "127.0.0.1",
                port: 18_001,
                pathPrefix: "/api/v1/namespaces/tools/services/api:8080/proxy"
            ),
            DomainRoute(
                hostname: "web.default.k8s.dory.local",
                address: "127.0.0.1",
                port: 18_001,
                pathPrefix: "/api/v1/namespaces/default/services/web:80/proxy"
            ),
        ])
    }

    func testInvalidKubectlJSONReturnsNoRoutes() {
        XCTAssertEqual(
            KubernetesServiceRouteProvider.routes(fromKubectlJSON: "not json", proxyPort: 18_001, suffix: "dory.local"),
            []
        )
    }
}
