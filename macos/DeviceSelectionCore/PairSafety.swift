import Foundation

public enum PairSafetyError: Error, Equatable, CustomStringConvertible {
    case invalidConfiguredAddress(String)
    case configuredAddressAlreadyPaired(address: String, matchCount: Int)
    case pinnedDeviceNotDiscovered(address: String)
    case multiplePinnedDevices(address: String, matchCount: Int)
    case pinnedDeviceNameMismatch(name: String)
    case pinnedDeviceClassMismatch(actual: UInt32)
    case pinnedDeviceIsAlreadyPaired
    case pairedDeviceIsNotPaired
    case pairedVerificationFailed(address: String, matchCount: Int)

    public var description: String {
        switch self {
        case .invalidConfiguredAddress(let address):
            return "Configured Bluetooth address is invalid: \(address)"
        case .configuredAddressAlreadyPaired(let address, let matchCount):
            return "Configured Bluetooth address \(address) already has \(matchCount) paired record(s)."
        case .pinnedDeviceNotDiscovered(let address):
            return "Inquiry did not discover the pinned Bluetooth address \(address)."
        case .multiplePinnedDevices(let address, let matchCount):
            return "Inquiry produced \(matchCount) records for pinned Bluetooth address \(address); exactly one is required."
        case .pinnedDeviceNameMismatch(let name):
            return "Pinned device name does not contain Magic Mouse: \(name)"
        case .pinnedDeviceClassMismatch(let actual):
            return String(format: "Pinned device class is 0x%06X; expected 0x002580.", actual)
        case .pinnedDeviceIsAlreadyPaired:
            return "Pinned device is already paired."
        case .pairedDeviceIsNotPaired:
            return "Pinned device is not paired after pairing completed."
        case .pairedVerificationFailed(let address, let matchCount):
            return "Post-pair verification found \(matchCount) eligible paired records for \(address); exactly one is required."
        }
    }
}

public enum PairingCallbackKind: Equatable, Sendable {
    case pairingStarted
    case connecting
    case connected
    case pinCodeRequest
    case userConfirmationRequest(numericValue: UInt32)
    case passkeyNotification(passkey: UInt32)
    case simplePairingComplete(status: UInt8)
    case pairingFinished(resultCode: Int32)
}

public enum PairingCallbackDecision: Equatable, Sendable {
    case continueWaiting
    case stopAndReport
    case completed(resultCode: Int32)
}

public enum PairSafety {
    public static let confirmationPhrase = "PAIR MAGIC MOUSE"
    public static let expectedPointingDeviceClass: UInt32 = 0x002580

    public static func confirmationIsExact(_ enteredPhrase: String) -> Bool {
        enteredPhrase == confirmationPhrase
    }

    public static func normalizedConfiguredAddress(_ configuredAddress: String) throws -> String {
        guard let normalized = BluetoothAddressNormalizer.normalize(configuredAddress) else {
            throw PairSafetyError.invalidConfiguredAddress(configuredAddress)
        }
        return normalized
    }

    public static func pairedAddressMatchCount(
        in pairedDevices: [PairedBluetoothDevice],
        normalizedConfiguredAddress: String
    ) -> Int {
        pairedDevices.filter {
            BluetoothAddressNormalizer.normalize($0.address) == normalizedConfiguredAddress
        }.count
    }

    public static func requireAddressIsUnpaired(
        in pairedDevices: [PairedBluetoothDevice],
        configuredAddress: String
    ) throws {
        let normalized = try normalizedConfiguredAddress(configuredAddress)
        let matchCount = pairedAddressMatchCount(
            in: pairedDevices,
            normalizedConfiguredAddress: normalized
        )
        guard matchCount == 0 else {
            throw PairSafetyError.configuredAddressAlreadyPaired(
                address: configuredAddress,
                matchCount: matchCount
            )
        }
    }

    public static func selectDiscoveredDevice(
        from devices: [PairedBluetoothDevice],
        configuredAddress: String
    ) throws -> PairedBluetoothDevice {
        let normalized = try normalizedConfiguredAddress(configuredAddress)
        let pinned = devices.filter {
            BluetoothAddressNormalizer.normalize($0.address) == normalized
        }

        guard !pinned.isEmpty else {
            throw PairSafetyError.pinnedDeviceNotDiscovered(address: configuredAddress)
        }
        guard pinned.count == 1 else {
            throw PairSafetyError.multiplePinnedDevices(
                address: configuredAddress,
                matchCount: pinned.count
            )
        }

        try validateUnpairedCandidate(pinned[0], configuredAddress: configuredAddress)
        return pinned[0]
    }

    public static func validateUnpairedCandidate(
        _ device: PairedBluetoothDevice,
        configuredAddress: String
    ) throws {
        let normalized = try normalizedConfiguredAddress(configuredAddress)
        guard BluetoothAddressNormalizer.normalize(device.address) == normalized else {
            throw PairSafetyError.pinnedDeviceNotDiscovered(address: configuredAddress)
        }
        guard DeviceSelector.nameContainsMagicMouse(device.name) else {
            throw PairSafetyError.pinnedDeviceNameMismatch(name: device.name)
        }
        guard device.classOfDevice == expectedPointingDeviceClass else {
            throw PairSafetyError.pinnedDeviceClassMismatch(actual: device.classOfDevice)
        }
        guard !device.isPaired else {
            throw PairSafetyError.pinnedDeviceIsAlreadyPaired
        }
    }

    public static func selectVerifiedPairedDevice(
        from pairedDevices: [PairedBluetoothDevice],
        configuredAddress: String
    ) throws -> PairedBluetoothDevice {
        let normalized = try normalizedConfiguredAddress(configuredAddress)
        let pinned = pairedDevices.filter {
            BluetoothAddressNormalizer.normalize($0.address) == normalized
        }
        guard pinned.count == 1 else {
            throw PairSafetyError.pairedVerificationFailed(
                address: configuredAddress,
                matchCount: pinned.count
            )
        }
        guard pinned[0].isPaired else {
            throw PairSafetyError.pairedDeviceIsNotPaired
        }
        guard DeviceSelector.nameContainsMagicMouse(pinned[0].name) else {
            throw PairSafetyError.pinnedDeviceNameMismatch(name: pinned[0].name)
        }
        guard pinned[0].classOfDevice == expectedPointingDeviceClass else {
            throw PairSafetyError.pinnedDeviceClassMismatch(actual: pinned[0].classOfDevice)
        }
        return pinned[0]
    }

    public static func decision(for callback: PairingCallbackKind) -> PairingCallbackDecision {
        switch callback {
        case .pinCodeRequest, .userConfirmationRequest, .passkeyNotification:
            return .stopAndReport
        case .pairingFinished(let resultCode):
            return .completed(resultCode: resultCode)
        case .pairingStarted, .connecting, .connected, .simplePairingComplete:
            return .continueWaiting
        }
    }
}
