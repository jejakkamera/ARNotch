import CoreBluetooth
import Foundation

/// Reads the standard GATT Battery Level (service 180F, characteristic 2A19) of Bluetooth LE
/// accessories that are already connected to the Mac. It never scans or pairs; it only attaches
/// to links the system already has, and lets go of them when the Connectivity tab closes.
@MainActor
final class BLEBatteryReader: NSObject, CBPeripheralDelegate {
    struct Reading: Equatable {
        let name: String
        let percent: Int
    }

    private static let batteryService = CBUUID(string: "180F")
    private static let batteryLevel = CBUUID(string: "2A19")

    /// Latest level per peripheral, keyed by the CoreBluetooth identifier.
    private(set) var readings: [UUID: Reading] = [:]
    var onChange: (() -> Void)?

    private var peripherals: [UUID: CBPeripheral] = [:]
    private var lastRead = Date.distantPast

    /// Re-reads at most once a minute; the level changes slowly.
    func refreshIfDue(using central: CBCentralManager) {
        guard central.state == .poweredOn, Date().timeIntervalSince(lastRead) >= 60 else { return }
        lastRead = Date()
        let connected = central.retrieveConnectedPeripherals(withServices: [Self.batteryService])
        let ids = Set(connected.map(\.identifier))
        for id in readings.keys where !ids.contains(id) { readings[id] = nil }
        for peripheral in connected {
            peripherals[peripheral.identifier] = peripheral
            peripheral.delegate = self
            if peripheral.state == .connected {
                peripheral.discoverServices([Self.batteryService])
            } else {
                central.connect(peripheral)
            }
        }
        onChange?()
    }

    func didConnect(_ peripheral: CBPeripheral) {
        guard peripherals[peripheral.identifier] != nil else { return }
        peripheral.discoverServices([Self.batteryService])
    }

    /// Drops this app's use of the links; the system keeps the devices connected.
    func stop(using central: CBCentralManager?) {
        for peripheral in peripherals.values {
            peripheral.delegate = nil
            central?.cancelPeripheralConnection(peripheral)
        }
        peripherals.removeAll()
        lastRead = .distantPast
    }

    // MARK: CBPeripheralDelegate (delivered on the main queue the central was created with)

    nonisolated func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        MainActor.assumeIsolated {
            guard let service = peripheral.services?.first(where: { $0.uuid == Self.batteryService }) else { return }
            peripheral.discoverCharacteristics([Self.batteryLevel], for: service)
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        MainActor.assumeIsolated {
            guard let level = service.characteristics?.first(where: { $0.uuid == Self.batteryLevel }) else { return }
            peripheral.readValue(for: level)
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        MainActor.assumeIsolated {
            guard error == nil, characteristic.uuid == Self.batteryLevel,
                  let byte = characteristic.value?.first, byte <= 100 else { return }
            let reading = Reading(name: peripheral.name ?? "Bluetooth accessory", percent: Int(byte))
            if readings[peripheral.identifier] != reading {
                readings[peripheral.identifier] = reading
                onChange?()
            }
        }
    }
}
