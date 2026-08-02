public enum GuardedMagicMouseSelectionError: Error, Equatable, CustomStringConvertible {
    case invalidConfiguredAddress(String)
    case noEligibleDevice(configuredAddress: String)
    case multipleEligibleDevices(configuredAddress: String, matchCount: Int)

    public var description: String {
        switch self {
        case .invalidConfiguredAddress(let address):
            return "Configured Bluetooth address is invalid: \(address)"
        case .noEligibleDevice(let address):
            return "No paired Magic Mouse with Bluetooth address \(address) and device class 0x002580 passed every safety check."
        case .multipleEligibleDevices(let address, let matchCount):
            return "Bluetooth address \(address) matched \(matchCount) eligible Magic Mouse records; exactly one is required."
        }
    }
}

public enum GuardedMagicMouseSelection {
    public static let expectedPointingDeviceClass: UInt32 = 0x002580

    public static func selectEligibleDevice(
        from pairedDevices: [PairedBluetoothDevice],
        configuredAddress: String
    ) throws -> PairedBluetoothDevice {
        guard let normalizedConfiguredAddress = BluetoothAddressNormalizer.normalize(configuredAddress) else {
            throw GuardedMagicMouseSelectionError.invalidConfiguredAddress(configuredAddress)
        }

        let matches = pairedDevices.filter { device in
            device.isPaired
                && device.classOfDevice == expectedPointingDeviceClass
                && DeviceSelector.nameContainsMagicMouse(device.name)
                && BluetoothAddressNormalizer.normalize(device.address) == normalizedConfiguredAddress
        }

        guard !matches.isEmpty else {
            throw GuardedMagicMouseSelectionError.noEligibleDevice(
                configuredAddress: configuredAddress
            )
        }

        guard matches.count == 1 else {
            throw GuardedMagicMouseSelectionError.multipleEligibleDevices(
                configuredAddress: configuredAddress,
                matchCount: matches.count
            )
        }

        return matches[0]
    }
}
