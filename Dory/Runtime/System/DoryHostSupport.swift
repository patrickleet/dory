import Darwin
import Foundation

nonisolated struct MacHostPlatform: Equatable, Sendable {
    var major: Int
    var minor: Int
    var patch: Int
    var architecture: String

    var isAppleSilicon: Bool {
        architecture == "arm64" || architecture == "arm64e"
    }

    var isIntel: Bool {
        architecture == "x86_64"
    }

    static func current() -> MacHostPlatform {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        return MacHostPlatform(
            major: version.majorVersion,
            minor: version.minorVersion,
            patch: version.patchVersion,
            architecture: currentArchitecture()
        )
    }

    private static func currentArchitecture() -> String {
        var systemInfo = utsname()
        uname(&systemInfo)
        var machine = systemInfo.machine
        return withUnsafePointer(to: &machine) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: MemoryLayout.size(ofValue: systemInfo.machine)) {
                String(cString: $0)
            }
        }
    }
}

nonisolated struct RuntimeSupport: Equatable, Sendable {
    enum Issue: Equatable, Sendable {
        case none
        case osVersion
        case architecture
        case missingToolchain
        case hypervisor
    }

    var isSupported: Bool
    var reason: String
    var issue: Issue = .none

    static let supported = RuntimeSupport(isSupported: true, reason: "")

    static func unsupported(_ reason: String, issue: Issue = .none) -> RuntimeSupport {
        RuntimeSupport(isSupported: false, reason: reason, issue: issue)
    }
}

nonisolated enum EngineTier: Equatable, Sendable {
    case hvNative
    case vzShared
    case proxyOnly
}

nonisolated struct EngineSupportEvaluation: Equatable, Sendable {
    var tier: EngineTier
    var support: RuntimeSupport

    var hasBuiltInEngine: Bool {
        switch tier {
        case .hvNative, .vzShared: return support.isSupported
        case .proxyOnly: return false
        }
    }
}

enum EngineSupport {
    nonisolated static let minimumMajorVersion = 14
    nonisolated static let rawHVMinimumMajorVersion = 15

    nonisolated static func evaluate(
        platform: MacHostPlatform,
        hvNativeAvailable: Bool,
        vzSharedAvailable: Bool,
        hypervisorSupported: Bool
    ) -> EngineSupportEvaluation {
        guard platform.major >= minimumMajorVersion else {
            return EngineSupportEvaluation(
                tier: .proxyOnly,
                support: .unsupported("Dory's engine requires macOS 14 or later", issue: .osVersion)
            )
        }
        guard hypervisorSupported else {
            return EngineSupportEvaluation(
                tier: .proxyOnly,
                support: .unsupported("Hypervisor.framework is unavailable on this Mac", issue: .hypervisor)
            )
        }
        guard platform.isAppleSilicon || platform.isIntel else {
            return EngineSupportEvaluation(
                tier: .proxyOnly,
                support: .unsupported("Dory's engine does not support this Mac architecture", issue: .architecture)
            )
        }

        // Shipped dory-hv slices have LC_BUILD_VERSION minOS 15.0. Asset presence alone must never
        // make the app advertise or select that tier on Sonoma; the macOS 14 dory-vmm path remains
        // the built-in fallback on both supported architectures.
        if platform.major >= rawHVMinimumMajorVersion, hvNativeAvailable {
            return EngineSupportEvaluation(tier: .hvNative, support: .supported)
        }
        if vzSharedAvailable {
            return EngineSupportEvaluation(tier: .vzShared, support: .supported)
        }
        return EngineSupportEvaluation(
            tier: .proxyOnly,
            support: .unsupported(
                platform.isIntel
                    ? "Dory's Intel engine assets are unavailable on this install"
                    : "Dory's engine is unavailable on this install",
                issue: .missingToolchain
            )
        )
    }
}

/// Compatibility shim for call sites that still ask specifically about the native dory-hv tier.
enum DoryHVSupport {
    nonisolated static let minimumMajorVersion = EngineSupport.rawHVMinimumMajorVersion

    nonisolated static func evaluate(platform: MacHostPlatform) -> RuntimeSupport {
        guard platform.major >= minimumMajorVersion else {
            return .unsupported("Dory's raw-HV engine requires macOS 15 or later", issue: .osVersion)
        }
        guard platform.isAppleSilicon || platform.isIntel else {
            return .unsupported("Dory's engine does not support this Mac architecture", issue: .architecture)
        }
        return .supported
    }
}
