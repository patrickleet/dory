import CoreFoundation
import Foundation

enum DockerDiskUsageParserError: Error, Equatable {
    case invalidJSON
    case missingVolumeInventory
    case invalidVolumeUsage(String)
    case conflictingVolumeInventories
}

/// Strict compatibility decoder for Docker Engine `/system/df` responses.
///
/// API 1.40–1.51 use the top-level `Volumes` array. API 1.52 can return that array
/// together with `VolumeUsage.Items`, and API 1.53+ return only the type-specific usage object.
enum DockerDiskUsageParser {
    static func namedVolumeSizes(from data: Data) throws -> [String: Int64] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw DockerDiskUsageParserError.invalidJSON
        }

        var inventories: [[String: Int64]] = []
        if let legacy = try legacyInventory(root["Volumes"]) {
            inventories.append(legacy)
        }
        for key in ["VolumeUsage", "VolumesUsage"] {
            if let current = try currentInventory(root[key], key: key) {
                inventories.append(current)
            }
        }
        guard let first = inventories.first else {
            throw DockerDiskUsageParserError.missingVolumeInventory
        }
        guard inventories.dropFirst().allSatisfy({ $0 == first }) else {
            throw DockerDiskUsageParserError.conflictingVolumeInventories
        }
        return first
    }

    private static func legacyInventory(_ value: Any?) throws -> [String: Int64]? {
        guard let value else { return nil }
        if value is NSNull { return [:] }
        guard let items = value as? [Any] else {
            throw DockerDiskUsageParserError.invalidVolumeUsage("Volumes must be an array or null")
        }
        return try parse(items: items, field: "Volumes")
    }

    private static func currentInventory(_ value: Any?, key: String) throws -> [String: Int64]? {
        guard let value, !(value is NSNull) else { return nil }
        guard let usage = value as? [String: Any] else {
            throw DockerDiskUsageParserError.invalidVolumeUsage("\(key) must be an object")
        }
        guard let itemsValue = usage["Items"], !(itemsValue is NSNull) else { return nil }
        guard let items = itemsValue as? [Any] else {
            throw DockerDiskUsageParserError.invalidVolumeUsage("\(key).Items must be an array or null")
        }
        return try parse(items: items, field: "\(key).Items")
    }

    private static func parse(items: [Any], field: String) throws -> [String: Int64] {
        var result: [String: Int64] = [:]
        for (index, value) in items.enumerated() {
            guard let volume = value as? [String: Any],
                  let name = volume["Name"] as? String,
                  isValidVolumeName(name),
                  let usage = volume["UsageData"] as? [String: Any],
                  let size = exactNonnegativeInteger(usage["Size"]) else {
                throw DockerDiskUsageParserError.invalidVolumeUsage("invalid \(field)[\(index)]")
            }
            guard result.updateValue(size, forKey: name) == nil else {
                throw DockerDiskUsageParserError.invalidVolumeUsage("duplicate volume name \(name)")
            }
        }
        return result
    }

    private static func isValidVolumeName(_ value: String) -> Bool {
        !value.isEmpty
            && value.utf8.count <= 255
            && value == value.trimmingCharacters(in: .whitespacesAndNewlines)
            && value.unicodeScalars.allSatisfy { $0.value >= 0x20 && $0.value != 0x7f }
    }

    private static func exactNonnegativeInteger(_ value: Any?) -> Int64? {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID(),
              number.int64Value >= 0,
              let decimal = Decimal(string: number.stringValue, locale: Locale(identifier: "en_US_POSIX")),
              decimal == Decimal(number.int64Value) else { return nil }
        return number.int64Value
    }
}
