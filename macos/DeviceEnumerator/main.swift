import Foundation
import IOBluetooth

// Read-only feasibility probe. This program intentionally uses only the cached
// system pairing records. It performs no inquiry, connection, disconnection,
// pairing, unpairing, or UI automation.

let pairedObjects = IOBluetoothDevice.pairedDevices() ?? []
let devices = pairedObjects.compactMap { $0 as? IOBluetoothDevice }
    .sorted {
        ($0.addressString ?? "") < ($1.addressString ?? "")
    }

print("Paired Bluetooth devices: \(devices.count)")

for (index, device) in devices.enumerated() {
    let name = device.name ?? "<unknown>"
    let address = device.addressString ?? "<unavailable>"
    let classOfDevice = String(format: "0x%06X", device.classOfDevice)

    print("[\(index + 1)]")
    print("  name: \(name)")
    print("  bluetoothAddress: \(address)")
    print("  classOfDevice: \(classOfDevice)")
    print("  paired: \(device.isPaired())")
    print("  connected: \(device.isConnected())")
}
