import Foundation

public enum BinfmtRegistration {
    public enum Architecture: String, Sendable {
        case arm64
        case amd64

        var handlerName: String {
            switch self {
            case .arm64: "qemu-aarch64"
            case .amd64: "FEX-x86_64"
            }
        }

        var interpreterPath: String {
            switch self {
            case .arm64: "/usr/bin/qemu-aarch64-static"
            case .amd64: BinfmtRegistration.fexX8664Path
            }
        }

        var elfMachine: String {
            switch self {
            case .arm64: #"\xb7\x00"#
            case .amd64: #"\x3e\x00"#
            }
        }
    }

    public static let fexBundlePath = "/usr/lib/dory/fex"
    public static let fexX8664Path = "\(fexBundlePath)/FEX"
    public static let fexServerPath = "\(fexBundlePath)/FEXServer"
    public static let doryRuncPath = "/usr/local/bin/dory-runc"
    public static let pinnedBinfmtImage = "tonistiigi/binfmt@sha256:400a4873b838d1b89194d982c45e5fb3cda4593fbfd7e08a02e76b03b21166f0"

    private static let elf64ExecutablePrefix = #"\x7fELF\x02\x01\x01\x00\x00\x00\x00\x00\x00\x00\x00\x00\x02\x00"#
    private static let elf64ExecutableMask = #"\xff\xff\xff\xff\xff\xff\xff\x00\xff\xff\xff\xff\xff\xff\xff\xff\xfe\xff\xff\xff"#

    public static var hostNativeArchitecture: Architecture {
        #if arch(arm64)
        .arm64
        #else
        .amd64
        #endif
    }

    public static var nonNativeHostArchitecture: Architecture {
        hostNativeArchitecture == .arm64 ? .amd64 : .arm64
    }

    public static var fexX8664RegisterLine: String {
        registerLine(for: .amd64)
    }

    public static func registerLine(for architecture: Architecture) -> String {
        let flags = architecture == .amd64 ? "POCF" : "F"
        return ":\(architecture.handlerName):M::\(elf64ExecutablePrefix)\(architecture.elfMachine):\(elf64ExecutableMask):\(architecture.interpreterPath):\(flags)"
    }

    public static func bootCommands(for architecture: Architecture = nonNativeHostArchitecture) -> [String] {
        let registerLine = registerLine(for: architecture)
        var commands = [
            "mkdir -p /proc/sys/fs/binfmt_misc",
            "mountpoint -q /proc/sys/fs/binfmt_misc || mount -t binfmt_misc binfmt_misc /proc/sys/fs/binfmt_misc",
        ]
        if architecture == .amd64 {
            commands += [
                "[ -x \(fexX8664Path) ] && [ -x \(fexServerPath) ] && [ -x \(doryRuncPath) ] || { echo 'DORY-FEX-RUNTIME-MISSING' >&2; exit 1; }",
                "[ -w /proc/sys/fs/binfmt_misc/register ] || { echo 'DORY-BINFMT-REGISTER-UNAVAILABLE' >&2; exit 1; }",
                "if [ -e /proc/sys/fs/binfmt_misc/qemu-x86_64 ]; then printf '%s' -1 > /proc/sys/fs/binfmt_misc/qemu-x86_64 || exit 1; fi",
                "if [ ! -e /proc/sys/fs/binfmt_misc/\(architecture.handlerName) ]; then printf '%s' '\(registerLine)' > /proc/sys/fs/binfmt_misc/register || exit 1; fi",
                "grep -qx enabled /proc/sys/fs/binfmt_misc/\(architecture.handlerName) && grep -qx 'interpreter \(fexX8664Path)' /proc/sys/fs/binfmt_misc/\(architecture.handlerName) && grep -qx 'flags: POCF' /proc/sys/fs/binfmt_misc/\(architecture.handlerName) || { echo 'DORY-FEX-BINFMT-INVALID' >&2; exit 1; }",
            ]
        } else {
            commands.append(
                "if [ -x \(architecture.interpreterPath) ] && [ -w /proc/sys/fs/binfmt_misc/register ] && [ ! -e /proc/sys/fs/binfmt_misc/\(architecture.handlerName) ]; then printf '%s' '\(registerLine)' > /proc/sys/fs/binfmt_misc/register || true; fi"
            )
        }
        return commands
    }

    public static func dockerFallbackCommand(
        for architecture: Architecture = nonNativeHostArchitecture,
        image: String = pinnedBinfmtImage
    ) -> String {
        guard architecture == .arm64 else {
            return "echo 'DORY-FEX-RUNTIME-MISSING-NO-QEMU-FALLBACK' >&2; false"
        }
        return "( [ ! -e /proc/sys/fs/binfmt_misc/\(architecture.handlerName) ] && command -v docker >/dev/null 2>&1 && for i in $(seq 1 30); do docker info >/dev/null 2>&1 && docker run --privileged --rm \(image) --install \(architecture.rawValue) >/var/log/dory-binfmt.log 2>&1 && break; sleep 1; done ) & true"
    }
}
