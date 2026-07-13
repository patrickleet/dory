@testable import DorydKit
import Foundation
import XCTest

final class MachineStatsTests: XCTestCase {
    private let valid = Data("""
    cpu_milli=12345
    memory_used_bytes=1073741824
    memory_total_bytes=2147483648
    network_receive_bytes=100
    network_transmit_bytes=200
    block_read_bytes=300
    block_write_bytes=400
    process_count=12
    uptime_millis=98765
    """.utf8)

    func testParsesExactGuestProcSnapshot() throws {
        XCTAssertEqual(
            try DoryMachineStats.parse(valid),
            DoryMachineStats(
                cpuPercent: 12.345,
                memoryUsedBytes: 1_073_741_824,
                memoryTotalBytes: 2_147_483_648,
                networkReceiveBytes: 100,
                networkTransmitBytes: 200,
                blockReadBytes: 300,
                blockWriteBytes: 400,
                processCount: 12,
                uptimeSeconds: 98.765
            )
        )
    }

    func testRejectsMissingDuplicateUnknownAndNonnumericFields() throws {
        for text in [
            String(decoding: valid, as: UTF8.self).replacingOccurrences(of: "process_count=12\n", with: ""),
            String(decoding: valid, as: UTF8.self) + "process_count=13\n",
            String(decoding: valid, as: UTF8.self) + "host_secret=1\n",
            String(decoding: valid, as: UTF8.self).replacingOccurrences(of: "cpu_milli=12345", with: "cpu_milli=nope"),
        ] {
            XCTAssertThrowsError(try DoryMachineStats.parse(Data(text.utf8)))
        }
    }

    func testRejectsImpossibleCpuAndMemoryRanges() throws {
        let text = String(decoding: valid, as: UTF8.self)
        XCTAssertThrowsError(try DoryMachineStats.parse(Data(text.replacingOccurrences(
            of: "cpu_milli=12345", with: "cpu_milli=100001"
        ).utf8)))
        XCTAssertThrowsError(try DoryMachineStats.parse(Data(text.replacingOccurrences(
            of: "memory_used_bytes=1073741824", with: "memory_used_bytes=3147483648"
        ).utf8)))
    }

    func testSamplerUsesBoundedProcOnlyContract() {
        XCTAssertTrue(DoryMachineStats.command.contains("/proc/stat"))
        XCTAssertTrue(DoryMachineStats.command.contains("/proc/meminfo"))
        XCTAssertTrue(DoryMachineStats.command.contains("/proc/net/dev"))
        XCTAssertTrue(DoryMachineStats.command.contains("/proc/diskstats"))
        XCTAssertTrue(DoryMachineStats.command.contains("NR > 2 && $2 != \"lo\""))
        XCTAssertTrue(DoryMachineStats.command.contains("printf \"%.0f %.0f\\n\""))
        XCTAssertFalse(DoryMachineStats.command.contains("apk "))
        XCTAssertFalse(DoryMachineStats.command.contains("curl "))
    }
}
