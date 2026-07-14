import Foundation

public enum DoryNetworkMTU {
    /// The IPv6 minimum link MTU is also the conservative default used by Apple's container
    /// networking. It keeps Dory below common corporate-VPN and packet-tunnel ceilings.
    public static let safeDefault = 1_280
    public static let maximum = 9_000
    public static let environmentKey = "DORY_NETWORK_MTU"

    public static func resolved(environment: [String: String] = ProcessInfo.processInfo.environment) -> Int {
        guard let raw = environment[environmentKey]?.trimmingCharacters(in: .whitespacesAndNewlines),
              let value = Int(raw),
              (safeDefault...maximum).contains(value) else {
            return safeDefault
        }
        return value
    }
}
