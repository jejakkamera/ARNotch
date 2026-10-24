import Foundation
import IOKit
import IOBluetooth

/// Reads existing connections only. Never pairs, connects, or performs a Bluetooth discovery scan.
enum ConnectivityScanner {
    private struct RegistryDevice {
        let id: String
        let name: String
        let address: String
        let transport: String
        let symbol: String
        let batteries: [ConnectionBattery]
    }

    static func scan(includeBluetooth: Bool) -> ConnectivitySnapshot {
        var result = ConnectivitySnapshot()
        result.audio = ConnectivityAudio.scan()
        let records = registryDevices()
        var usedRecords = Set<String>()
        var audioNames = Set(result.audio.map { normalized($0.name) })
        var peripherals: [ConnectedPeripheral] = []

        for index in result.audio.indices {
            let audio = result.audio[index]
            if let record = records.first(where: {
                normalized($0.name) == normalized(audio.name)
                    || (!$0.address.isEmpty && normalized(audio.uid).contains($0.address))
            }) {
                result.audio[index].batteries = record.batteries
                usedRecords.insert(record.id)
            }
        }

        if includeBluetooth {
            for device in (IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice] ?? []) where device.isConnected() {
                let name = device.nameOrAddress ?? "Bluetooth device"
                let address = normalized(device.addressString ?? "")
                let record = records.first { (!$0.address.isEmpty && $0.address == address) || normalized($0.name) == normalized(name) }
                if let record { usedRecords.insert(record.id) }
                let majorClass = (device.classOfDevice >> 8) & 0x1f
                if let index = result.audio.firstIndex(where: {
                    normalized($0.name) == normalized(name)
                        || (!address.isEmpty && normalized($0.uid).contains(address))
                }) {
                    if let record { result.audio[index].batteries = record.batteries }
                    audioNames.insert(normalized(name))
                    continue
                }
                // Connected audio endpoints that Core Audio hasn't published yet remain visible as peripherals.
                let symbol = majorClass == 4 ? "headphones" : (record?.symbol ?? bluetoothSymbol(device.classOfDevice))
                peripherals.append(ConnectedPeripheral(id: "bt-" + address, name: name, transport: "Bluetooth",
                                                       symbol: symbol, batteries: record?.batteries ?? []))
            }
        }

        let bluetoothNames = Set(peripherals.filter { $0.transport == "Bluetooth" }.map { normalized($0.name) })
        for record in records where !usedRecords.contains(record.id) && !audioNames.contains(normalized(record.name)) {
            if record.transport == "Bluetooth", bluetoothNames.contains(normalized(record.name)) { continue }
            peripherals.append(ConnectedPeripheral(id: record.id, name: record.name, transport: record.transport,
                                                   symbol: record.symbol, batteries: record.batteries))
        }
        result.peripherals = peripherals.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        return result
    }

    private static func registryDevices() -> [RegistryDevice] {
        // Reading registry metadata does not open HID devices or request Input Monitoring access.
        let classes = ["AppleDeviceManagementHIDEventService", "AppleBluetoothHIDDriver", "IOBluetoothDevice", "IOHIDDevice", "IOUSBHostDevice"]
        var byIdentity: [String: RegistryDevice] = [:]
        for className in classes {
            var iterator: io_iterator_t = 0
            guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching(className), &iterator) == KERN_SUCCESS else { continue }
            defer { IOObjectRelease(iterator) }
            while true {
                let service = IOIteratorNext(iterator)
                guard service != 0 else { break }
                defer { IOObjectRelease(service) }
                var properties: Unmanaged<CFMutableDictionary>?
                guard IORegistryEntryCreateCFProperties(service, &properties, kCFAllocatorDefault, 0) == KERN_SUCCESS,
                      let data = properties?.takeRetainedValue() as? [String: Any] else { continue }
                if (data["Built-In"] as? NSNumber)?.boolValue == true { continue }
                if (data["Connected"] as? NSNumber)?.boolValue == false { continue }
                if className == "IOBluetoothDevice", (data["Connected"] as? NSNumber)?.boolValue != true { continue }
                let name = (data["Product"] as? String) ?? (data["USB Product Name"] as? String)
                    ?? (data["ProductName"] as? String) ?? (data["Name"] as? String)
                guard let name, !name.isEmpty else { continue }
                let lower = name.lowercased()
                guard !lower.contains("internal"), !lower.contains("apple embedded"), !lower.contains("virtual") else { continue }
                let rawTransport = data["Transport"] as? String ?? (className == "IOUSBHostDevice" ? "USB" : "")
                let transport: String
                if rawTransport.lowercased().contains("bluetooth") || className.contains("Bluetooth") { transport = "Bluetooth" }
                else if rawTransport == "USB" { transport = "USB" }
                else { continue }
                let address = normalized((data["DeviceAddress"] as? String) ?? (data["BluetoothDeviceAddress"] as? String) ?? "")
                let location = (data["LocationID"] as? NSNumber)?.stringValue ?? (data["locationID"] as? NSNumber)?.stringValue ?? ""
                let identity = address.isEmpty ? normalized(name) + "|" + transport + "|" + location : address
                let batteries = batteryValues(data)
                let record = RegistryDevice(id: "peripheral-" + identity, name: name, address: address, transport: transport,
                                            symbol: peripheralSymbol(name: name, usage: (data["PrimaryUsage"] as? NSNumber)?.intValue),
                                            batteries: batteries)
                if let previous = byIdentity[identity], previous.batteries.count >= batteries.count { continue }
                byIdentity[identity] = record
            }
        }
        return Array(byIdentity.values).sorted { $0.id < $1.id }
    }

    /// Vendor metadata is optional. Invalid/sentinel values are omitted, never converted to 0%.
    private static func batteryValues(_ data: [String: Any]) -> [ConnectionBattery] {
        func percent(_ keys: [String]) -> Int? {
            for key in keys {
                guard let value = data[key] as? NSNumber else { continue }
                let number = value.doubleValue
                if number.isFinite, number >= 0, number <= 100 { return Int(number.rounded()) }
            }
            return nil
        }
        var parts: [ConnectionBattery] = []
        for (label, keys) in [("L", ["BatteryPercentLeft", "BatteryLevelLeft"]),
                              ("R", ["BatteryPercentRight", "BatteryLevelRight"]),
                              ("Case", ["BatteryPercentCase", "BatteryLevelCase"])] {
            if let value = percent(keys) { parts.append(ConnectionBattery(label: label, percent: value)) }
        }
        if parts.isEmpty, let value = percent(["BatteryPercent", "BatteryLevel", "BatteryPercentSingle"]) {
            parts.append(ConnectionBattery(label: "Battery", percent: value))
        }
        return parts
    }

    private static func normalized(_ text: String) -> String {
        text.lowercased().filter { $0.isLetter || $0.isNumber }
    }

    private static func peripheralSymbol(name: String, usage: Int?) -> String {
        let name = name.lowercased()
        if name.contains("trackpad") { return "rectangle.and.hand.point.up.left.fill" }
        if name.contains("mouse") || usage == 2 { return "computermouse.fill" }
        if name.contains("keyboard") || usage == 6 { return "keyboard.fill" }
        if name.contains("controller") || usage == 4 || usage == 5 { return "gamecontroller.fill" }
        if name.contains("hub") || name.contains("dock") { return "externaldrive.connected.to.line.below" }
        if name.contains("camera") || name.contains("webcam") { return "web.camera.fill" }
        return "cable.connector"
    }

    private static func bluetoothSymbol(_ deviceClass: BluetoothClassOfDevice) -> String {
        let major = (deviceClass >> 8) & 0x1f
        if major == 2 { return "iphone" }
        if major == 5 {
            let minor = (deviceClass >> 2) & 0x3f
            if minor & 0x20 != 0 { return "computermouse.fill" }
            if minor & 0x10 != 0 { return "keyboard.fill" }
            return "gamecontroller.fill"
        }
        return "antenna.radiowaves.left.and.right"
    }
}
