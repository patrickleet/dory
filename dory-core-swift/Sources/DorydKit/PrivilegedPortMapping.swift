import DoryCore
import Foundation

public enum PrivilegedPortMapping {
    public static let targetBase: UInt16 = 60_000
    public static let proxyReservedListenPorts: Set<UInt16> = [80, 443]

    public static func targetPort(forListenPort listenPort: UInt16) -> UInt16? {
        guard listenPort > 0, listenPort < 1024 else { return nil }
        return targetBase + listenPort
    }

    public static func effectiveBackendPort(forPublishedPort publishedPort: UInt16) -> UInt16 {
        targetPort(forListenPort: publishedPort) ?? publishedPort
    }

    public static func forwards(from publishedPorts: [DoryListenPort]) -> [PrivilegedTCPForward] {
        var forwards: [UInt16: PrivilegedTCPForward] = [:]
        for port in publishedPorts {
            let proto = port.protocol.lowercased()
            guard proto == "tcp" || proto == "tcp6",
                  let listenPort = UInt16(exactly: port.port),
                  !proxyReservedListenPorts.contains(listenPort),
                  let targetPort = targetPort(forListenPort: listenPort) else {
                continue
            }
            forwards[listenPort] = PrivilegedTCPForward(listenPort: listenPort, targetPort: targetPort)
        }
        return forwards.values.sorted { $0.listenPort < $1.listenPort }
    }
}
