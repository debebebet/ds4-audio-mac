import Foundation
import IOKit
import IOKit.hid

/// Подключённый DualShock 4, найденный через IOHIDManager.
struct DS4DeviceInfo: Identifiable, Equatable {
    let id: String
    let product: String
    let transport: String
    let vendorID: Int
    let productID: Int
    let serial: String?

    var isBluetooth: Bool {
        transport.lowercased().contains("bluetooth")
    }

    var vidPID: String {
        String(format: "%04X:%04X", vendorID, productID)
    }
}

/// Периодический поиск DualShock 4 (v1/v2).
///
/// Сканирование идёт раз в 5 секунд, как просили. На каждый тик устройства
/// перечисляются заново через свежий `IOHIDManager`, чтобы геймпад,
/// подключённый уже после запуска приложения, подхватывался автоматически.
/// Колбэк всегда приходит на главном потоке.
final class ControllerScanner {
    static let vendorID = 0x054C
    static let productIDs: Set<Int> = [0x05C4, 0x09CC]

    private let queue = DispatchQueue(label: "com.ds4audio.gui.controller-scan")
    private var timer: DispatchSourceTimer?
    private var scanning = false

    /// Вызывается на главном потоке после каждого скана.
    var onUpdate: (([DS4DeviceInfo]) -> Void)?

    func start(interval: TimeInterval = 5.0) {
        stop()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: interval, leeway: .milliseconds(100))
        timer.setEventHandler { [weak self] in self?.scan() }
        timer.resume()
        self.timer = timer
    }

    func stop() {
        timer?.cancel()
        timer = nil
    }

    func scanNow() {
        queue.async { [weak self] in self?.scan() }
    }

    deinit {
        stop()
    }

    // MARK: - Скан

    private func scan() {
        guard !scanning else { return }
        scanning = true
        defer { scanning = false }

        let found = enumerateDevices()
        publish(found)
    }

    /// Перечисляем HID-устройства через свежий `IOHIDManager`.
    ///
    /// Постоянный менеджер здесь не годится: без `IOHIDManagerScheduleWithRunLoop`
    /// он не получает уведомления о подключении, и набор устройств замораживается
    /// в момент открытия. Геймпад, включённый уже после запуска приложения, тогда
    /// не виден никогда. Поэтому на каждый скан менеджер создаётся заново —
    /// так же, как это делает диагностика в `ds4probe --list`.
    private func enumerateDevices() -> [DS4DeviceInfo] {
        let manager = IOHIDManagerCreate(kCFAllocatorDefault,
                                         IOOptionBits(kIOHIDOptionsTypeNone))
        let matching: [String: Any] = ["VendorID": Self.vendorID]
        IOHIDManagerSetDeviceMatching(manager, matching as CFDictionary)

        let openResult = IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        guard openResult == kIOReturnSuccess else {
            NSLog("DS4Audio: IOHIDManagerOpen failed: \(openResult)")
            IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
            return []
        }
        defer { IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone)) }

        let set = (IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice>) ?? []
        var found: [DS4DeviceInfo] = []
        var seen = Set<String>()

        for device in set {
            let vid = intProperty(device, "VendorID")
            let pid = intProperty(device, "ProductID")
            guard vid == Self.vendorID, Self.productIDs.contains(pid) else { continue }

            let product = stringProperty(device, "Product") ?? "DualShock 4"
            let transport = stringProperty(device, "Transport") ?? "?"
            let serial = stringProperty(device, "SerialNumber")
            let uniqueID = (IOHIDDeviceGetProperty(device, kIOHIDUniqueIDKey as CFString) as? NSNumber)
                .map { String($0.uint64Value) }
            let id = uniqueID ?? "\(pid)-\(serial ?? product)"
            guard seen.insert(id).inserted else { continue }

            found.append(DS4DeviceInfo(id: id,
                                       product: product,
                                       transport: transport,
                                       vendorID: vid,
                                       productID: pid,
                                       serial: serial))
        }

        // Bluetooth-подключение приоритетнее: только по нему звук идёт
        // во встроенный динамик.
        found.sort { lhs, rhs in
            if lhs.isBluetooth != rhs.isBluetooth { return lhs.isBluetooth }
            return lhs.product < rhs.product
        }
        return found
    }

    private func publish(_ devices: [DS4DeviceInfo]) {
        DispatchQueue.main.async { [weak self] in
            self?.onUpdate?(devices)
        }
    }

    private func intProperty(_ device: IOHIDDevice, _ key: String) -> Int {
        (IOHIDDeviceGetProperty(device, key as CFString) as? NSNumber)?.intValue ?? 0
    }

    private func stringProperty(_ device: IOHIDDevice, _ key: String) -> String? {
        guard let raw = IOHIDDeviceGetProperty(device, key as CFString),
              CFGetTypeID(raw as CFTypeRef) == CFStringGetTypeID() else { return nil }
        return (raw as! CFString) as String
    }
}
