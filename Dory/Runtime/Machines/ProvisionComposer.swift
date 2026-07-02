import Foundation

enum ProvisionComposer {
    static func stableHash(_ string: String) -> String {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in string.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x100000001b3
        }
        return String(hash, radix: 16)
    }

    static func composedInstall(_ items: [ProvisionItem]) -> String {
        let ids = Set(items.map(\.id))
        let ordered = ProvisionCatalog.all.filter { ids.contains($0.id) }
        var parts = ordered.compactMap(\.custom)
        let apt = Array(Set(ordered.flatMap(\.aptNames))).sorted()
        if !apt.isEmpty {
            parts.append("apt-get update && apt-get install -y --no-install-recommends \(apt.joined(separator: " ")) && rm -rf /var/lib/apt/lists/*")
        }
        return parts.joined(separator: " && ")
    }

    static func composedRecipe(_ items: [ProvisionItem]) -> DevRecipe? {
        guard !items.isEmpty else { return nil }
        let ids = items.map(\.id).sorted()
        let hash = stableHash(ids.joined(separator: ","))
        return DevRecipe(id: "custom-\(hash)", display: "Custom · \(ids.count) selected",
                         icon: "wrench.and.screwdriver", install: composedInstall(items))
    }
}
