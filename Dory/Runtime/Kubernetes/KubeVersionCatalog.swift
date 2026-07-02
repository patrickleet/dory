import Foundation

struct KubeVersion: Identifiable, Hashable, Sendable {
    let minor: String
    let tag: String
    var id: String { tag }
    var image: String { "rancher/k3s:\(tag)" }
}

enum KubeVersionCatalog {
    static let all: [KubeVersion] = [
        KubeVersion(minor: "v1.36", tag: "v1.36.2-k3s1"),
        KubeVersion(minor: "v1.35", tag: "v1.35.6-k3s1"),
        KubeVersion(minor: "v1.34", tag: "v1.34.9-k3s1"),
    ]

    static var latest: KubeVersion { all[0] }

    static func version(forTag tag: String?) -> KubeVersion {
        guard let tag, let match = all.first(where: { $0.tag == tag }) else { return latest }
        return match
    }
}
