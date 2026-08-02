import Darwin
import DeviceSelectionCore
import Foundation
import IOBluetooth
import IOKit

private let pollingIntervalSeconds = 0.25
private let maximumPollCount = 60

private struct PairedDeviceRecord {
    let bluetoothDevice: IOBluetoothDevice
    let snapshot: PairedBluetoothDevice
}

private func fail(_ message: String, exitCode: Int32) -> Never {
    let diagnostic = "DeviceReconnect: \(message)\n"
    FileHandle.standardError.write(Data(diagnostic.utf8))
    exit(exitCode)
}

private func readPairedRecords() -> [PairedDeviceRecord] {
    let pairedObjects = IOBluetoothDevice.pairedDevices() ?? []

    return pairedObjects.compactMap { object in
        guard let device = object as? IOBluetoothDevice else {
            return nil
        }

        return PairedDeviceRecord(
            bluetoothDevice: device,
            snapshot: PairedBluetoothDevice(
                name: device.name ?? "<unknown>",
                address: device.addressString ?? "<unavailable>",
                isPaired: device.isPaired(),
                isConnected: device.isConnected(),
                classOfDevice: device.classOfDevice
            )
        )
    }
}

private func selectRecord(
    from records: [PairedDeviceRecord],
    configuredAddress: String
) throws -> PairedDeviceRecord {
    let selectedSnapshot = try ReconnectSafety.selectEligibleDevice(
        from: records.map(\.snapshot),
        configuredAddress: configuredAddress
    )

    guard let selectedRecord = records.first(where: { $0.snapshot == selectedSnapshot }) else {
        throw ReconnectSafetyError.noEligibleDevice(configuredAddress: configuredAddress)
    }

    return selectedRecord
}

private func printSelectedDevice(_ device: PairedBluetoothDevice) {
    print("Selected device")
    print("----------------")
    print("Name: \(device.name)")
    print("Address: \(device.address)")
    print("Paired: \(device.isPaired)")
    print("Connected: \(device.isConnected)")
    print(String(format: "Device Class: 0x%06X", device.classOfDevice))
}

private func selectOrFail(
    from records: [PairedDeviceRecord],
    configuredAddress: String,
    context: String
) -> PairedDeviceRecord {
    do {
        return try selectRecord(from: records, configuredAddress: configuredAddress)
    } catch let error as ReconnectSafetyError {
        fail("\(context): \(error.description)", exitCode: 2)
    } catch {
        fail("\(context): unexpected safety-check failure: \(error)", exitCode: 1)
    }
}

let arguments = Array(CommandLine.arguments.dropFirst())

guard arguments.count == 2, arguments[0] == "--address" else {
    fail("usage: DeviceReconnect --address <Bluetooth address>", exitCode: 64)
}

let configuredAddress = arguments[1]
private let initialSelection = selectOrFail(
    from: readPairedRecords(),
    configuredAddress: configuredAddress,
    context: "initial selection failed"
)

printSelectedDevice(initialSelection.snapshot)

guard !initialSelection.snapshot.isConnected else {
    print("Device is already connected; openConnection() was not called.")
    exit(0)
}

print("Type exactly: \(ReconnectSafety.confirmationPhrase)")

guard let enteredPhrase = readLine(strippingNewline: true),
      ReconnectSafety.confirmationIsExact(enteredPhrase) else {
    fail("confirmation did not exactly match \(ReconnectSafety.confirmationPhrase)", exitCode: 3)
}

private let revalidatedSelection = selectOrFail(
    from: readPairedRecords(),
    configuredAddress: configuredAddress,
    context: "final safety check failed"
)

guard !revalidatedSelection.bluetoothDevice.isConnected() else {
    print("Device became connected before the operation; openConnection() was not called.")
    exit(0)
}

let operationStart = ContinuousClock.now
let returnCode = revalidatedSelection.bluetoothDevice.openConnection()
let connectedImmediatelyAfterward = revalidatedSelection.bluetoothDevice.isConnected()

var connectedAfterPolling = connectedImmediatelyAfterward
var completedPollCount = 0

while !connectedAfterPolling && completedPollCount < maximumPollCount {
    Thread.sleep(forTimeInterval: pollingIntervalSeconds)
    completedPollCount += 1
    connectedAfterPolling = revalidatedSelection.bluetoothDevice.isConnected()
}

let elapsed = operationStart.duration(to: .now)
let elapsedSeconds = Double(elapsed.components.seconds)
    + Double(elapsed.components.attoseconds) / 1_000_000_000_000_000_000

print("openConnection() return code: \(returnCode)")
print(String(format: "Elapsed time: %.3f seconds", elapsedSeconds))
print("Connected immediately afterward: \(connectedImmediatelyAfterward)")
print("Connected after bounded polling: \(connectedAfterPolling)")

guard returnCode == kIOReturnSuccess else {
    fail("openConnection() returned error code \(returnCode)", exitCode: 4)
}

guard connectedAfterPolling else {
    fail("device remained disconnected after the 15-second polling window", exitCode: 5)
}
