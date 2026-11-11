// l2cap-probe — прямая запись HID output-отчётов в L2CAP-канал DS4.
//
// Зачем: IOHIDDeviceSetReport на Bluetooth идёт через HIDP control-канал и
// упирается в ~11 отчётов/с (90 мс на отчёт). Эталонная реализация на Windows
// пишет output-отчёты через WriteFile, то есть по interrupt-каналу (PSM 0x13).
// Этот инструмент открывает L2CAP-канал напрямую и проверяет, можно ли
// получить нужную пропускную способность в обход стека macOS.
//
// Использование:
//   l2cap-probe --address AA:BB:CC:DD:EE:FF --psm 0x13 --count 50 --size 462
//   l2cap-probe ... --dry          (только открыть канал и закрыть)

import Foundation
import IOBluetooth
import L2CAPShim

/// Человекочитаемое имя для IOReturn.
func IOReturnName(_ code: IOReturn) -> String {
    switch code {
    case kIOReturnSuccess: return "kIOReturnSuccess"
    case kIOReturnError: return "kIOReturnError"
    case kIOReturnNoMemory: return "kIOReturnNoMemory"
    case kIOReturnNoDevice: return "kIOReturnNoDevice"
    case kIOReturnExclusiveAccess: return "kIOReturnExclusiveAccess"
    case kIOReturnNotOpen: return "kIOReturnNotOpen"
    case kIOReturnBusy: return "kIOReturnBusy"
    case kIOReturnUnsupported: return "kIOReturnUnsupported"
    case kIOReturnBadArgument: return "kIOReturnBadArgument"
    default: return "IOReturn(\(code))"
    }
}

/// Ключи, требующие значения; остальные флаги — булевы.
private let valueKeys: Set<String> = ["address", "psm", "count", "size", "report-id"]

func parseOptions() -> [String: String] {
    var result: [String: String] = [:]
    var args = Array(CommandLine.arguments.dropFirst())
    while !args.isEmpty {
        let key = args.removeFirst()
        guard key.hasPrefix("--") else { continue }
        let name = String(key.dropFirst(2))
        if valueKeys.contains(name), !args.isEmpty {
            result[name] = args.removeFirst()
        } else {
            result[name] = "1"
        }
    }
    return result
}

let options = parseOptions()
let address = options["address"] ?? "AA:BB:CC:DD:EE:FF"
let psm = UInt16(options["psm"] ?? "0x13", radix: 16) ?? 0x13
let count = Int(options["count"] ?? "50") ?? 50
let size = Int(options["size"] ?? "462") ?? 462
let reportID = UInt8(options["report-id"] ?? "0x17", radix: 16) ?? 0x17
let dry = options["dry"] != nil
let findExisting = options["find-existing"] != nil

print("=== l2cap-probe ===")
print("Устройство: \(address), PSM: 0x\(String(format: "%04X", psm)), отчётов: \(count), размер: \(size) B" +
      (findExisting ? " [режим: поиск существующего канала]" : ""))

// Собираем BD_ADDR из строки вида "AA:BB:CC:DD:EE:FF"
let octets = address.split(separator: ":").compactMap { UInt8($0, radix: 16) }
guard octets.count == 6 else {
    print("ОШИБКА: неверный MAC-адрес: \(address)")
    exit(1)
}
var deviceAddress = BluetoothDeviceAddress()
withUnsafeMutableBytes(of: &deviceAddress) { raw in
    for (index, value) in octets.enumerated() { raw[index] = value }
}
let device = withUnsafePointer(to: &deviceAddress) { pointer in
    IOBluetoothDevice(address: pointer)
}
guard let device else {
    print("ОШИБКА: устройство \(address) не найдено")
    exit(1)
}
print("Device: \(device.name ?? "?")  isConnected=\(device.isConnected())  classOfDevice=\(device.deviceClassMajor)")

var channel: IOBluetoothL2CAPChannel?
var openResult: IOReturn
if findExisting {
    // Устаревший, но единственный способ добраться до канала, уже открытого
    // стеком macOS (HIDP держит оба канала: control 0x11 и interrupt 0x13).
    openResult = L2CAPFindExistingChannel(device, psm, &channel)
} else {
    openResult = device.openL2CAPChannelSync(&channel, withPSM: psm, delegate: nil)
}
print((findExisting ? "L2CAPFindExistingChannel" : "openL2CAPChannelSync") +
      " → \(openResult) (\(IOReturnName(openResult)))")

guard openResult == kIOReturnSuccess, let channel else {
    print("ОШИБКА: канал не открыт. Возможные причины: сервис HID уже занят стеком macOS,")
    print("        либо контроллер не принимает второй канал к PSM 0x13.")
    exit(2)
}
print("Канал открыт: localCID=\(channel.localChannelID) remoteCID=\(channel.remoteChannelID) " +
      "incomingMTU=\(channel.incomingMTU) outgoingMTU=\(channel.outgoingMTU)")

if dry {
    print("Режим --dry: канал открыт, запись не выполнялась.")
    exit(0)
}

// Полезная нагрузка: [Report ID][данные]. Формат как у PoC на Windows —
// в буфере первым идёт Report ID.
var payload = [UInt8](repeating: 0, count: size)
payload[0] = reportID
for i in 1 ..< size { payload[i] = UInt8(i & 0xFF) }

var latencies: [Double] = []
var failures = 0
for i in 0 ..< count {
    let start = Date()
    let result = payload.withUnsafeBufferPointer { buf -> IOReturn in
        guard let base = buf.baseAddress else { return kIOReturnBadArgument }
        return channel.writeSync(UnsafeMutableRawPointer(mutating: base), length: UInt16(buf.count))
    }
    let dt = Date().timeIntervalSince(start) * 1000
    if result == kIOReturnSuccess {
        latencies.append(dt)
    } else {
        failures += 1
        if failures == 1 { print("первая ошибка записи: \(result) (\(IOReturnName(result)))") }
    }
    if i == 9 {
        print("первые 10 записей: \(latencies.count) успешных, " +
              "средняя \(String(format: "%.2f", latencies.reduce(0,+) / Double(max(latencies.count,1)))) мс")
    }
}

if latencies.isEmpty {
    print("ОШИБКА: ни одной успешной записи (ошибок: \(failures))")
    exit(3)
}
let sorted = latencies.sorted()
let avg = latencies.reduce(0, +) / Double(latencies.count)
print("Записей: \(latencies.count), ошибок: \(failures)")
print("Задержка записи: avg \(String(format: "%.2f", avg)) мс, " +
      "min \(String(format: "%.2f", sorted.first ?? 0)) мс, " +
      "p50 \(String(format: "%.2f", sorted[sorted.count / 2])) мс, " +
      "max \(String(format: "%.2f", sorted.last ?? 0)) мс")
let rate = 1000.0 / avg
print("Потолок по последней записи: ~\(String(format: "%.0f", rate)) отчётов/с")
