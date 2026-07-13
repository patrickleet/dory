import Foundation

/// One shutdown budget shared by doryd and dory-hv.
///
/// The guest first asks dockerd to stop its containers and commit containerd metadata. The VMM
/// watchdog may force its own exit only after that grace expires, and doryd may SIGKILL the VMM
/// only after the watchdog has had time to run. Keeping the three deadlines here prevents a short
/// host timeout from cutting through a still-clean guest shutdown and leaving Docker metadata that
/// references a snapshot containerd had not committed.
public enum DoryEngineShutdownTiming {
    public static let dockerdGraceSeconds: TimeInterval = 20
    public static let helperWatchdogSeconds: TimeInterval = 25
    public static let hostTerminationSeconds: TimeInterval = 30

    public static let pollIntervalSeconds: TimeInterval = 0.25

    public static var dockerdPollAttempts: Int {
        Int(dockerdGraceSeconds / pollIntervalSeconds)
    }
}
