import Foundation

struct MachineUseCase: Identifiable, Hashable, Sendable {
    let id: String
    let title: String
    let subtitle: String
    let icon: String
    let baseImage: String
    let recipeID: String?
    let cpus: Int
    let memoryGB: Int

    var distro: MachineDistro? { MachineDistro.forImage(baseImage) }
    var recipe: DevRecipe? { recipeID.flatMap(DevRecipe.forID) }

    struct Prefill: Equatable, Sendable {
        let family: MachineFamily
        let version: MachineDistro
        let arch: MachineArch
        let recipe: DevRecipe?
        let cpus: Int
        let memoryGB: Int
    }

    var prefill: Prefill? {
        guard let version = distro,
              let family = MachineDistro.families.first(where: { $0.id == version.family })
        else { return nil }
        return Prefill(family: family, version: version, arch: version.defaultArch(),
                       recipe: recipe, cpus: cpus, memoryGB: memoryGB)
    }

    static let all: [MachineUseCase] = [
        MachineUseCase(id: "web", title: "Web / Node.js", subtitle: "Node.js LTS · npm, pnpm & corepack",
                       icon: "globe", baseImage: "ubuntu:24.04", recipeID: "node", cpus: 2, memoryGB: 2),
        MachineUseCase(id: "python", title: "Python & ML", subtitle: "Python 3 · pip, venv & pipx",
                       icon: "brain", baseImage: "ubuntu:24.04", recipeID: "python", cpus: 2, memoryGB: 4),
        MachineUseCase(id: "go", title: "Go", subtitle: "Go toolchain",
                       icon: "g.circle", baseImage: "ubuntu:24.04", recipeID: "go", cpus: 2, memoryGB: 2),
        MachineUseCase(id: "rust", title: "Rust", subtitle: "rustc + cargo",
                       icon: "r.circle", baseImage: "ubuntu:24.04", recipeID: "rust", cpus: 2, memoryGB: 2),
        MachineUseCase(id: "jvm", title: "Java / JVM", subtitle: "JDK + Maven",
                       icon: "cup.and.saucer", baseImage: "ubuntu:24.04", recipeID: "java", cpus: 2, memoryGB: 4),
        MachineUseCase(id: "devops", title: "DevOps & CI", subtitle: "docker CLI + kubectl",
                       icon: "shippingbox", baseImage: "ubuntu:24.04", recipeID: "devops", cpus: 2, memoryGB: 2),
        MachineUseCase(id: "clean", title: "Just a clean Linux", subtitle: "Plain Ubuntu 24.04 LTS",
                       icon: "terminal", baseImage: "ubuntu:24.04", recipeID: nil, cpus: 2, memoryGB: 2),
    ]

    static func forID(_ id: String) -> MachineUseCase? { all.first { $0.id == id } }
}
