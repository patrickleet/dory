import DoryCore
import Foundation

public enum DoryMachineStatsError: Error, Sendable, Equatable, CustomStringConvertible {
    case commandFailed(String)
    case malformed(String)

    public var description: String {
        switch self {
        case .commandFailed(let message): "machine stats command failed: \(message)"
        case .malformed(let field): "machine stats output is malformed: \(field)"
        }
    }
}

public struct DoryMachineStats: Sendable, Equatable {
    public var cpuPercent: Double
    public var memoryUsedBytes: UInt64
    public var memoryTotalBytes: UInt64
    public var networkReceiveBytes: UInt64
    public var networkTransmitBytes: UInt64
    public var blockReadBytes: UInt64
    public var blockWriteBytes: UInt64
    public var processCount: UInt64
    public var uptimeSeconds: Double

    static let command = #"""
set -eu
cpu() { awk '/^cpu / { total=0; for (i=2;i<=NF;i++) total+=$i; printf "%.0f %.0f\n", total, $5+$6; exit }' /proc/stat; }
set -- $(cpu); total1=$1; idle1=$2
sleep 1
set -- $(cpu); total2=$1; idle2=$2
dt=$((total2-total1)); didle=$((idle2-idle1))
[ "$dt" -gt 0 ] || exit 70
cpu_milli=$((100000*(dt-didle)/dt))
set -- $(awk '/^MemTotal:/ {t=$2} /^MemAvailable:/ {a=$2} END {printf "%.0f %.0f\n", (t-a)*1024, t*1024}' /proc/meminfo)
memory_used=$1; memory_total=$2
set -- $(awk -F '[: ]+' 'NR > 2 && $2 != "lo" && NF >= 11 {rx+=$3; tx+=$11} END {printf "%.0f %.0f\n", rx+0, tx+0}' /proc/net/dev)
network_rx=$1; network_tx=$2
set -- $(awk '$3 ~ /^(vd[a-z]|sd[a-z]|nvme[0-9]+n[0-9]+)$/ {r+=$6*512; w+=$10*512} END {printf "%.0f %.0f\n", r+0, w+0}' /proc/diskstats)
block_read=$1; block_write=$2
processes=$(find /proc -mindepth 1 -maxdepth 1 -type d -name '[0-9]*' 2>/dev/null | wc -l | tr -d ' ')
uptime_millis=$(awk '{printf "%.0f", $1*1000}' /proc/uptime)
printf 'cpu_milli=%s\nmemory_used_bytes=%s\nmemory_total_bytes=%s\nnetwork_receive_bytes=%s\nnetwork_transmit_bytes=%s\nblock_read_bytes=%s\nblock_write_bytes=%s\nprocess_count=%s\nuptime_millis=%s\n' "$cpu_milli" "$memory_used" "$memory_total" "$network_rx" "$network_tx" "$block_read" "$block_write" "$processes" "$uptime_millis"
"""#

    static func parse(_ data: Data) throws -> DoryMachineStats {
        guard let text = String(data: data, encoding: .utf8) else { throw DoryMachineStatsError.malformed("utf8") }
        var values: [String: UInt64] = [:]
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            let parts = line.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2, values[String(parts[0])] == nil, let value = UInt64(parts[1]) else {
                throw DoryMachineStatsError.malformed(String(line))
            }
            values[String(parts[0])] = value
        }
        let expected = Set([
            "cpu_milli", "memory_used_bytes", "memory_total_bytes", "network_receive_bytes",
            "network_transmit_bytes", "block_read_bytes", "block_write_bytes", "process_count", "uptime_millis",
        ])
        guard Set(values.keys) == expected else { throw DoryMachineStatsError.malformed("fields") }
        guard let cpu = values["cpu_milli"], cpu <= 100_000,
              let used = values["memory_used_bytes"], let total = values["memory_total_bytes"], used <= total,
              let receive = values["network_receive_bytes"], let transmit = values["network_transmit_bytes"],
              let read = values["block_read_bytes"], let write = values["block_write_bytes"],
              let processes = values["process_count"], let uptime = values["uptime_millis"] else {
            throw DoryMachineStatsError.malformed("range")
        }
        return DoryMachineStats(
            cpuPercent: Double(cpu) / 1_000,
            memoryUsedBytes: used,
            memoryTotalBytes: total,
            networkReceiveBytes: receive,
            networkTransmitBytes: transmit,
            blockReadBytes: read,
            blockWriteBytes: write,
            processCount: processes,
            uptimeSeconds: Double(uptime) / 1_000
        )
    }
}

extension MachineManager {
    public func stats(id: String) throws -> DoryMachineStats {
        let result = try exec(
            id: id,
            argv: ["/bin/sh", "-c", DoryMachineStats.command],
            timeoutMs: 5_000,
            outputLimitBytes: 16 * 1_024
        )
        guard result.exitCode == 0, !result.timedOut, !result.stdoutTruncated, !result.stderrTruncated else {
            let stderr = String(decoding: result.stderr.prefix(512), as: UTF8.self)
            throw DoryMachineStatsError.commandFailed(stderr.isEmpty ? "exit \(result.exitCode)" : stderr)
        }
        return try DoryMachineStats.parse(result.stdout)
    }
}
