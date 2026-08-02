import Darwin
import DeviceSelectionCore
import Foundation
import IOBluetooth

private func fail(_ message: String, exitCode: Int32) -> Never {
    let diagnostic = "DeviceSelector: \(message)\n"
    FileHandle.standardError.write(Data(diagnostic.utf8))
    exit(exitCode)
}

let arguments = Array(CommandLine.arguments.dropFirst())

guard arguments.count == 2, arguments[0] == "--address" else {
    fail("usage: DeviceSelector --address <Bluetooth address>", exitCode: 64)
}

let configuredAddress = arguments[1]
let pairedObjects = IOBluetoothDevice.pairedDevices() ?? []
let devices = pairedObjects.compactMap { object -> PairedBluetoothDevice? in
    guard let device = object as? IOBluetoothDevice else {
        return nil
    }

    return PairedBluetoothDevice(
        name: device.name ?? "<unknown>",
        address: device.addressString ?? "<unavailable>",
        isPaired: device.isPaired(),
        isConnected: device.isConnected(),
        classOfDevice: device.classOfDevice
    )
}

let selectedDevice: PairedBluetoothDevice

do {
    selectedDevice = try DeviceSelector.select(
        from: devices,
        configuredAddress: configuredAddress
    )
} catch let error as DeviceSelectionError {
    fail(error.description, exitCode: 2)
} catch {
    fail("unexpected selection failure: \(error)", exitCode: 1)
}

print("Selected device")
print("----------------")
print("Name: \(selectedDevice.name)")
print("Address: \(selectedDevice.address)")
print("Paired: \(selectedDevice.isPaired)")
print("Connected: \(selectedDevice.isConnected)")
print(String(format: "Device Class: 0x%06X", selectedDevice.classOfDevice))
