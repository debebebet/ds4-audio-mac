// hidprobe — снятие живого HID report descriptor с DS4 и инвентаризация репортов.
//
// Использование:
//   swiftc -O DumpDescriptor.swift -o hidprobe
//   ./hidprobe [--out DIR]
//
// Сохраняет:
//   <out>/descriptor_<serial>.bin   — сырые байты HID report descriptor
//   <out>/descriptor_<serial>.hex   — hexdump + SHA-256 (для диффа между прогонами)
//   <out>/devices.json              — свойства устройства + раскладка репортов

import Foundation
import IOKit
import IOKit.hid
import CryptoKit

// MARK: - Свойства устройства

private func propString(_ device: IOHIDDevice, _ key: String) -> String? {
    guard let raw = IOHIDDeviceGetProperty(device, key as CFString) else { return nil }
    guard CFGetTypeID(raw as CFTypeRef) == CFStringGetTypeID() else { return nil }
    return (raw as! CFString) as String
}

private func propInt(_ device: IOHIDDevice, _ key: String) -> Int? {
    guard let raw = IOHIDDeviceGetProperty(device, key as CFString) else { return nil }
    guard CFGetTypeID(raw as CFTypeRef) == CFNumberGetTypeID() else { return nil }
    var v: Int32 = 0
    guard CFNumberGetValue(raw as! CFNumber, .sInt32Type, &v) else { return nil }
    return Int(v)
}

private func propData(_ device: IOHIDDevice, _ key: String) -> Data? {
    guard let raw = IOHIDDeviceGetProperty(device, key as CFString) else { return nil }
    guard CFGetTypeID(raw as CFTypeRef) == CFDataGetTypeID() else { return nil }
    return (raw as! CFData) as Data
}

private let interestingKeys = [
    "Transport",
    "Product",
    "Manufacturer",
    "VendorID",
    "ProductID",
    "Version",
    "SerialNumber",
    "DeviceAddress",
    "PrimaryUsage",
    "PrimaryUsagePage",
    "MaxInputReportSize",
    "MaxOutputReportSize",
    "MaxFeatureReportSize",
]

// MARK: - HID report descriptor parser

/// Короткий item дескриптора: размер данных + тип + тег + значение.
private struct Item {
    var size: Int       // 0, 1, 2, 4
    var type: Int       // 0 = Main, 1 = Global, 2 = Local
    var tag: Int
    var value: Int
}

/// Теги HID 1.11 (short item).
private enum HidTag {
    // Main
    static let input = 0x08
    static let output = 0x09
    static let feature = 0x0B
    static let collection = 0x0A
    static let endCollection = 0x0C
    static let mainReportSize = 0x27
    static let mainReportCount = 0x28
    static let mainReportID = 0x29
    // Global
    static let globalUsagePage = 0x00
    static let globalReportSize = 0x07
    static let globalReportID = 0x08
    static let globalReportCount = 0x09
    static let featureReportData = 0x0D
    // Local
    static let localUsage = 0x0A
}

private func parseItems(_ data: Data) -> [Item] {
    var items: [Item] = []
    let bytes = [UInt8](data)
    var i = 0
    while i < bytes.count {
        let prefix = bytes[i]
        i += 1
        if prefix == 0xFE {          // long item — пропускаем целиком
            guard i < bytes.count else { break }
            let longSize = Int(bytes[i]); i += 1
            i += min(longSize, bytes.count - i)
            continue
        }
        let size = Int(prefix & 0x03)
        let type = Int((prefix >> 2) & 0x03)
        let tag = Int((prefix >> 4) & 0x0F)
        var value = 0
        switch size {
        case 1: guard i < bytes.count else { return items }; value = Int(bytes[i]); i += 1
        case 2: guard i + 1 < bytes.count else { return items }
                value = Int(bytes[i]) | (Int(bytes[i + 1]) << 8); i += 2
        case 4: guard i + 3 < bytes.count else { return items }
                value = Int(UInt32(bytes[i]) | (UInt32(bytes[i+1]) << 8) | (UInt32(bytes[i+2]) << 16) | (UInt32(bytes[i+3]) << 24)); i += 4
        default: break
        }
        items.append(Item(size: size, type: type, tag: tag, value: value))
    }
    return items
}

/// Сводка по одному Report ID.
private struct ReportSummary {
    var id: Int
    var inputBytes = 0
    var outputBytes = 0
    var featureBytes = 0
    var inputItems = 0
    var outputItems = 0
    var featureItems = 0
    var usagePage = 0
    var usages: [Int] = []
    var isVendorPage = false
    /// Детализация: (направление, размер в битах, количество, байт)
    var detail: [(dir: String, sizeBits: Int, count: Int, bytes: Int)] = []
}

/// Разбор дескриптора в раскладку Report ID → размеры в байтах.
private func summarizeReports(_ data: Data) -> [ReportSummary] {
    let items = parseItems(data)
    var order: [Int] = []
    var map: [Int: ReportSummary] = [:]

    var reportID = 0
    var usagePage = 0
    var reportSize = 0
    var reportCount = 0

    func ensure(_ id: Int) {
        if map[id] == nil {
            var s = ReportSummary(id: id)
            s.usagePage = usagePage
            map[id] = s
            order.append(id)
        }
    }

    for item in items {
        switch item.type {
        case 0: // Main
            switch item.tag {
            case HidTag.mainReportSize: reportSize = item.value
            case HidTag.mainReportCount: reportCount = item.value
            case HidTag.mainReportID:
                reportID = item.value
                ensure(reportID)
                map[reportID]?.usagePage = usagePage
            case HidTag.input:
                ensure(reportID)
                var s = map[reportID]!
                let bytes = reportSize * reportCount / 8
                s.inputBytes += bytes
                s.inputItems += 1
                s.detail.append(("in", reportSize, reportCount, bytes))
                map[reportID] = s
            case HidTag.output:
                ensure(reportID)
                var s = map[reportID]!
                let bytes = reportSize * reportCount / 8
                s.outputBytes += bytes
                s.outputItems += 1
                s.detail.append(("out", reportSize, reportCount, bytes))
                map[reportID] = s
            case HidTag.feature:
                ensure(reportID)
                var s = map[reportID]!
                let bytes = reportSize * reportCount / 8
                s.featureBytes += bytes
                s.featureItems += 1
                s.detail.append(("feat", reportSize, reportCount, bytes))
                map[reportID] = s
            case HidTag.collection, HidTag.endCollection:
                break
            default:
                break
            }
        case 1: // Global
            switch item.tag {
            case HidTag.globalUsagePage:
                usagePage = item.value
                map[reportID]?.usagePage = usagePage
                map[reportID]?.isVendorPage = (usagePage & 0xFF00) != 0
            case HidTag.globalReportSize: reportSize = item.value
            case HidTag.globalReportCount: reportCount = item.value
            case HidTag.globalReportID:
                reportID = item.value
                ensure(reportID)
                map[reportID]?.usagePage = usagePage
                map[reportID]?.isVendorPage = (usagePage & 0xFF00) != 0
            case HidTag.featureReportData:
                // Feature Report Data: следующий Feature-Item использует текущие
                // Report Size/Count — они и так уже актуальны в переменных.
                break
            default:
                break
            }
        case 2: // Local
            if item.tag == HidTag.localUsage {
                ensure(reportID)
                map[reportID]?.usages.append(item.value)
            }
        default:
            break
        }
    }

    return order.compactMap { map[$0] }
}

// MARK: - Утилиты

private func sha256Hex(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

private func hexdump(_ data: Data) -> String {
    let bytes = [UInt8](data)
    var lines: [String] = []
    for offset in stride(from: 0, to: bytes.count, by: 16) {
        let chunk = Array(bytes[offset ..< min(offset + 16, bytes.count)])
        let hex = chunk.map { String(format: "%02X", $0) }.joined(separator: " ")
        let padded = hex + String(repeating: " ", count: max(0, 47 - hex.count))
        let ascii = String(chunk.map { b -> Character in
            (b >= 0x20 && b < 0x7F) ? Character(UnicodeScalar(b)) : "."
        })
        lines.append(String(format: "%04X  %@  |%@|", offset, padded, ascii))
    }
    return lines.joined(separator: "\n")
}

// MARK: - main

let args = CommandLine.arguments
var outDir = "./artifacts"
if let idx = args.firstIndex(of: "--out"), idx + 1 < args.count {
    outDir = args[idx + 1]
}
try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)

let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))

// Матчим по VID: PS4-пульт (054C:05C4) и DS4 v2 (054C:09CC), плюс DualSense.
let matching: CFDictionary = ["VendorID": 0x054C] as CFDictionary
IOHIDManagerSetDeviceMatching(manager, matching)

let openResult = IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
guard openResult == kIOReturnSuccess else {
    FileHandle.standardError.write("ERROR: IOHIDManagerOpen failed: \(openResult)\n".data(using: .utf8)!)
    exit(2)
}

guard let deviceSet = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice>,
      !deviceSet.isEmpty else {
    FileHandle.standardError.write("ERROR: no HID devices matched VendorID 0x054C\n".data(using: .utf8)!)
    exit(3)
}

var devicesJSON: [[String: Any]] = []
var withDescriptor = 0

for device in deviceSet.sorted(by: { (propString($0, "SerialNumber") ?? "") < (propString($1, "SerialNumber") ?? "") }) {
    var props: [String: Any] = [:]
    for key in interestingKeys {
        if let s = propString(device, key) { props[key] = s }
        else if let n = propInt(device, key) { props[key] = n }
    }
    let vid = propInt(device, "VendorID") ?? 0
    let pid = propInt(device, "ProductID") ?? 0
    props["VendorIDHex"] = String(format: "0x%04X", vid)
    props["ProductIDHex"] = String(format: "0x%04X", pid)

    print("=== HID device: \(props["Product"] as? String ?? "?") ===")
    print("  Serial    : \(propString(device, "SerialNumber") ?? "-")")
    print("  Transport : \(propString(device, "Transport") ?? "-")")
    print("  VID:PID   : \(String(format: "0x%04X", vid)):\(String(format: "0x%04X", pid))")

    guard let descriptor = propData(device, "ReportDescriptor") else {
        print("  ReportDescriptor: НЕДОСТУПЕН")
        print("")
        devicesJSON.append(props)
        continue
    }
    withDescriptor += 1

    let serial = (propString(device, "SerialNumber") ?? String(format: "pid_%04X", pid))
        .replacingOccurrences(of: "/", with: "_")
    let binPath = "\(outDir)/descriptor_\(serial).bin"
    let hexPath = "\(outDir)/descriptor_\(serial).hex"
    try? descriptor.write(to: URL(fileURLWithPath: binPath))

    var hexText = hexdump(descriptor)
    hexText += "\n\n// SHA-256: \(sha256Hex(descriptor))\n"
    try? hexText.write(toFile: hexPath, atomically: true, encoding: .utf8)

    let reports = summarizeReports(descriptor)
    props["descriptorLength"] = descriptor.count
    props["descriptorSHA256"] = sha256Hex(descriptor)
    props["descriptorPath"] = binPath
    props["reports"] = reports.map { r -> [String: Any] in
        var d: [String: Any] = ["id": r.id, "idHex": String(format: "0x%02X", r.id)]
        if r.inputBytes > 0 { d["inputBytes"] = r.inputBytes }
        if r.outputBytes > 0 { d["outputBytes"] = r.outputBytes }
        if r.featureBytes > 0 { d["featureBytes"] = r.featureBytes }
        if r.outputBytes > 0 { d["outputTotalWithID"] = r.outputBytes + 1 }
        if r.inputItems > 0 { d["inputItems"] = r.inputItems }
        if r.outputItems > 0 { d["outputItems"] = r.outputItems }
        if r.featureItems > 0 { d["featureItems"] = r.featureItems }
        if !r.usages.isEmpty { d["usages"] = r.usages }
        if r.usagePage != 0 { d["usagePage"] = String(format: "0x%04X", r.usagePage) }
        if !r.detail.isEmpty {
            d["layout"] = r.detail.map { item -> [String: Any] in
                ["dir": item.dir, "sizeBits": item.sizeBits, "count": item.count, "bytes": item.bytes]
            }
        }
        return d
    }

    devicesJSON.append(props)

    print("  Descriptor: \(descriptor.count) B  sha256=\(sha256Hex(descriptor))")
    print("  Saved     : \(binPath)")
    print("  Reports:")
    for r in reports {
        var line = "    ID \(String(format: "0x%02X", r.id))  "
        if r.inputBytes > 0 { line += "in=\(r.inputBytes)B " }
        if r.outputBytes > 0 { line += "out=\(r.outputBytes)B (с ID: \(r.outputBytes + 1))" }
        if r.featureBytes > 0 { line += "feat=\(r.featureBytes)B " }
        if r.usagePage != 0 { line += "page=\(String(format: "0x%04X", r.usagePage)) " }
        print(line)
        for item in r.detail where item.dir == "out" {
            print("        out: sizeBits=\(item.sizeBits) count=\(item.count) → \(item.bytes) B")
        }
    }
    print("")
}

let json: [String: Any] = [
    "capturedAt": ISO8601DateFormatter().string(from: Date()),
    "devices": devicesJSON,
]
let jsonData = try! JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys])
try! jsonData.write(to: URL(fileURLWithPath: "\(outDir)/devices.json"))

print("devices.json записан; устройств с дескриптором: \(withDescriptor)")
