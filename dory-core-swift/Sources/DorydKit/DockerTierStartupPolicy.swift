import Foundation

public enum DockerTierStartupPolicy {
    public static func shouldAutostartDockerTier(
        environment: [String: String],
        persistedRuntimeMode: @autoclosure () -> String
    ) -> Bool {
        if isTruthy(environment["DORYD_FORCE_AUTOSTART_DOCKER_TIER"]) {
            return true
        }
        return persistedRuntimeMode() == "always-on"
    }

    private static func isTruthy(_ value: String?) -> Bool {
        guard let value else { return false }
        switch value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "1", "true", "yes", "on":
            return true
        default:
            return false
        }
    }
}
