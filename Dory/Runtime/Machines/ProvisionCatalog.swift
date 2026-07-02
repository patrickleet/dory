import Foundation

struct ProvisionItem: Identifiable, Hashable, Sendable {
    enum Section: String, Sendable, CaseIterable { case runtime, tool, package }
    let id: String
    let display: String
    let summary: String
    let section: Section
    let aptNames: [String]
    let custom: String?
    let brewNames: [String]
    let detectCommand: String?

    init(id: String, display: String, summary: String, section: Section,
         aptNames: [String] = [], custom: String? = nil,
         brewNames: [String] = [], detectCommand: String? = nil) {
        self.id = id
        self.display = display
        self.summary = summary
        self.section = section
        self.aptNames = aptNames
        self.custom = custom
        self.brewNames = brewNames
        self.detectCommand = detectCommand
    }
}

enum ProvisionCatalog {
    private static let dockerSnippet = "apt-get update && apt-get install -y --no-install-recommends ca-certificates curl && ARCH=$(dpkg --print-architecture) && DARCH=$([ \"$ARCH\" = arm64 ] && echo aarch64 || echo x86_64) && curl -fsSL https://download.docker.com/linux/static/stable/$DARCH/docker-27.5.1.tgz | tar -xz -C /tmp && install -m0755 /tmp/docker/docker /usr/local/bin/docker && rm -rf /var/lib/apt/lists/* /tmp/docker"
    private static let kubectlSnippet = "apt-get update && apt-get install -y --no-install-recommends ca-certificates curl && ARCH=$(dpkg --print-architecture) && curl -fsSL -o /usr/local/bin/kubectl https://dl.k8s.io/release/$(curl -fsSL https://dl.k8s.io/release/stable.txt)/bin/linux/$ARCH/kubectl && chmod +x /usr/local/bin/kubectl && rm -rf /var/lib/apt/lists/*"
    private static let ghSnippet = "apt-get update && apt-get install -y --no-install-recommends ca-certificates curl && curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg -o /usr/share/keyrings/githubcli-archive-keyring.gpg && chmod go+r /usr/share/keyrings/githubcli-archive-keyring.gpg && echo \"deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main\" > /etc/apt/sources.list.d/github-cli.list && apt-get update && apt-get install -y gh && rm -rf /var/lib/apt/lists/*"

    private static func runtime(_ recipeID: String, _ summary: String, brew: [String] = [], detect: String? = nil) -> ProvisionItem? {
        guard let recipe = DevRecipe.forID(recipeID) else { return nil }
        return ProvisionItem(id: recipe.id, display: recipe.display, summary: summary, section: .runtime,
                             custom: recipe.install, brewNames: brew, detectCommand: detect)
    }

    static let runtimes: [ProvisionItem] = [
        runtime("node", "Node.js LTS · npm, pnpm, corepack", brew: ["node"], detect: "node"),
        runtime("python", "Python 3 · pip, venv, pipx", brew: ["python", "python@3.12", "python@3.11"], detect: "python3"),
        runtime("go", "Go toolchain", brew: ["go"], detect: "go"),
        runtime("rust", "Rust · rustc + cargo", brew: ["rust"], detect: "rustc"),
        runtime("java", "OpenJDK + Maven", brew: ["openjdk", "maven"], detect: "javac"),
        runtime("ruby", "Ruby + bundler", brew: ["ruby"], detect: "ruby"),
    ].compactMap { $0 }

    static let tools: [ProvisionItem] = [
        ProvisionItem(id: "docker-cli", display: "Docker CLI", summary: "docker client (talks to Dory's engine)", section: .tool, custom: dockerSnippet, brewNames: ["docker"], detectCommand: "docker"),
        ProvisionItem(id: "kubectl", display: "kubectl", summary: "Kubernetes CLI", section: .tool, custom: kubectlSnippet, brewNames: ["kubernetes-cli", "kubectl"], detectCommand: "kubectl"),
        ProvisionItem(id: "gh", display: "GitHub CLI", summary: "gh — GitHub from the terminal", section: .tool, custom: ghSnippet, brewNames: ["gh"], detectCommand: "gh"),
        ProvisionItem(id: "git", display: "git", summary: "version control", section: .tool, aptNames: ["git"], brewNames: ["git"], detectCommand: "git"),
        ProvisionItem(id: "build-essential", display: "build-essential", summary: "gcc, g++, make", section: .tool, aptNames: ["build-essential"]),
        ProvisionItem(id: "cmake", display: "CMake", summary: "build system generator", section: .tool, aptNames: ["cmake"], brewNames: ["cmake"], detectCommand: "cmake"),
        ProvisionItem(id: "ripgrep", display: "ripgrep", summary: "fast recursive grep (rg)", section: .tool, aptNames: ["ripgrep"], brewNames: ["ripgrep"], detectCommand: "rg"),
        ProvisionItem(id: "fd", display: "fd", summary: "fast file finder (fdfind)", section: .tool, aptNames: ["fd-find"], brewNames: ["fd"], detectCommand: "fd"),
        ProvisionItem(id: "bat", display: "bat", summary: "cat with syntax highlighting", section: .tool, aptNames: ["bat"], brewNames: ["bat"], detectCommand: "bat"),
        ProvisionItem(id: "jq", display: "jq", summary: "JSON processor", section: .tool, aptNames: ["jq"], brewNames: ["jq"], detectCommand: "jq"),
        ProvisionItem(id: "fzf", display: "fzf", summary: "fuzzy finder", section: .tool, aptNames: ["fzf"], brewNames: ["fzf"], detectCommand: "fzf"),
        ProvisionItem(id: "tmux", display: "tmux", summary: "terminal multiplexer", section: .tool, aptNames: ["tmux"], brewNames: ["tmux"], detectCommand: "tmux"),
        ProvisionItem(id: "neovim", display: "Neovim", summary: "nvim editor", section: .tool, aptNames: ["neovim"], brewNames: ["neovim"], detectCommand: "nvim"),
        ProvisionItem(id: "htop", display: "htop", summary: "process viewer", section: .tool, aptNames: ["htop"], brewNames: ["htop"], detectCommand: "htop"),
        ProvisionItem(id: "direnv", display: "direnv", summary: "per-directory env", section: .tool, aptNames: ["direnv"], brewNames: ["direnv"], detectCommand: "direnv"),
        ProvisionItem(id: "shellcheck", display: "ShellCheck", summary: "shell script linter", section: .tool, aptNames: ["shellcheck"], brewNames: ["shellcheck"], detectCommand: "shellcheck"),
        ProvisionItem(id: "the-silver-searcher", display: "ag", summary: "the silver searcher", section: .tool, aptNames: ["silversearcher-ag"], brewNames: ["the_silver_searcher"], detectCommand: "ag"),
        ProvisionItem(id: "httpie", display: "HTTPie", summary: "friendly HTTP client", section: .tool, aptNames: ["httpie"], brewNames: ["httpie"], detectCommand: "http"),
    ]

    static let packages: [ProvisionItem] = [
        pkg("curl", "curl", "transfer data over URLs"),
        pkg("wget", "wget", "network downloader"),
        pkg("vim", "vim", "vi improved editor"),
        pkg("nano", "nano", "simple editor"),
        pkg("zsh", "zsh", "Z shell"),
        pkg("fish", "fish", "friendly interactive shell"),
        pkg("rsync", "rsync", "fast file sync"),
        pkg("openssh-client", "openssh-client", "ssh/scp client"),
        pkg("net-tools", "net-tools", "ifconfig, netstat"),
        pkg("dnsutils", "dnsutils", "dig, nslookup"),
        pkg("iputils-ping", "iputils-ping", "ping"),
        pkg("less", "less", "pager"),
        pkg("tree", "tree", "directory tree"),
        pkg("ncdu", "ncdu", "disk usage TUI"),
        pkg("unzip", "unzip", "zip extractor"),
        pkg("zip", "zip", "zip archiver"),
        pkg("gnupg", "gnupg", "GnuPG"),
        pkg("ca-certificates", "ca-certificates", "CA trust store"),
        pkg("bash-completion", "bash-completion", "bash tab-completion"),
        pkg("sqlite3", "sqlite3", "SQLite CLI"),
        pkg("postgresql-client", "postgresql-client", "psql client"),
        pkg("default-mysql-client", "default-mysql-client", "mysql client"),
        pkg("redis-tools", "redis-tools", "redis-cli"),
        pkg("python3-pip", "python3-pip", "pip for Python 3"),
        pkg("python3-venv", "python3-venv", "Python venv"),
        pkg("make", "make", "GNU make"),
        pkg("gcc", "gcc", "GNU C compiler"),
        pkg("g++", "g++", "GNU C++ compiler"),
        pkg("clang", "clang", "LLVM C/C++ compiler"),
        pkg("llvm", "llvm", "LLVM toolchain"),
        pkg("gdb", "gdb", "GNU debugger"),
        pkg("valgrind", "valgrind", "memory debugger"),
        pkg("pkg-config", "pkg-config", "compile/link flags helper"),
        pkg("autoconf", "autoconf", "configure-script generator"),
        pkg("zlib1g-dev", "zlib1g-dev", "zlib headers"),
        pkg("libssl-dev", "libssl-dev", "OpenSSL headers"),
        pkg("libffi-dev", "libffi-dev", "libffi headers"),
        pkg("libpq-dev", "libpq-dev", "PostgreSQL headers"),
        pkg("graphviz", "graphviz", "graph visualization"),
        pkg("imagemagick", "imagemagick", "image manipulation"),
        pkg("ffmpeg", "ffmpeg", "audio/video toolkit"),
        pkg("pandoc", "pandoc", "document converter"),
        pkg("git-lfs", "git-lfs", "Git large file storage"),
        pkg("man-db", "man-db", "man pages"),
        pkg("locales", "locales", "locale data"),
        pkg("sudo", "sudo", "privilege escalation"),
        pkg("procps", "procps", "ps, top, kill"),
        pkg("lsof", "lsof", "list open files"),
        pkg("strace", "strace", "syscall tracer"),
        pkg("moreutils", "moreutils", "sponge, ts, etc."),
        pkg("xz-utils", "xz-utils", "xz compression"),
        pkg("zstd", "zstd", "zstd compression"),
    ]

    private static func pkg(_ id: String, _ apt: String, _ summary: String) -> ProvisionItem {
        ProvisionItem(id: id, display: apt, summary: summary, section: .package, aptNames: [apt])
    }

    static var all: [ProvisionItem] { runtimes + tools + packages }

    static func item(_ id: String) -> ProvisionItem? { all.first { $0.id == id } }
}
