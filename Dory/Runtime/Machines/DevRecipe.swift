import Foundation

struct DevRecipe: Identifiable, Hashable, Sendable {
    let id: String
    let display: String
    let icon: String
    let install: String

    static let all: [DevRecipe] = [
        DevRecipe(id: "node", display: "Node.js", icon: "hexagon",
                  install: "curl -fsSL https://deb.nodesource.com/setup_lts.x | bash - && apt-get install -y nodejs && corepack enable"),
        DevRecipe(id: "python", display: "Python", icon: "chevron.left.forwardslash.chevron.right",
                  install: "apt-get update && apt-get install -y --no-install-recommends python3 python3-pip python3-venv pipx && rm -rf /var/lib/apt/lists/*"),
        DevRecipe(id: "go", display: "Go", icon: "g.circle",
                  install: "ARCH=$(dpkg --print-architecture); curl -fsSL https://go.dev/dl/go1.23.4.linux-${ARCH}.tar.gz | tar -C /usr/local -xz && echo 'export PATH=$PATH:/usr/local/go/bin' > /etc/profile.d/go.sh"),
        DevRecipe(id: "java", display: "Java", icon: "cup.and.saucer",
                  install: "apt-get update && apt-get install -y --no-install-recommends default-jdk maven && rm -rf /var/lib/apt/lists/*"),
        DevRecipe(id: "ruby", display: "Ruby", icon: "diamond",
                  install: "apt-get update && apt-get install -y --no-install-recommends ruby-full build-essential && gem install bundler && rm -rf /var/lib/apt/lists/*"),
        DevRecipe(id: "rust", display: "Rust", icon: "r.circle",
                  install: "apt-get update && apt-get install -y --no-install-recommends rustc cargo && rm -rf /var/lib/apt/lists/*"),
        DevRecipe(id: "devops", display: "DevOps", icon: "shippingbox",
                  install: "apt-get update && apt-get install -y --no-install-recommends ca-certificates curl && ARCH=$(dpkg --print-architecture) && DARCH=$([ \"$ARCH\" = arm64 ] && echo aarch64 || echo x86_64) && curl -fsSL https://download.docker.com/linux/static/stable/$DARCH/docker-27.5.1.tgz | tar -xz -C /tmp && install -m0755 /tmp/docker/docker /usr/local/bin/docker && curl -fsSL -o /usr/local/bin/kubectl https://dl.k8s.io/release/$(curl -fsSL https://dl.k8s.io/release/stable.txt)/bin/linux/$ARCH/kubectl && chmod +x /usr/local/bin/kubectl && rm -rf /var/lib/apt/lists/* /tmp/docker"),
    ]

    static func forID(_ id: String) -> DevRecipe? { all.first { $0.id == id } }
}
