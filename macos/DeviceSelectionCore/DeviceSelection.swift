import Foundation

public struct PairedBluetoothDevice: Equatable, Sendable {
    public let name: String
    public let address: String
    public let isPaired: Bool
    public let isConnected: Bool
    public let classOfDevice: UInt32

    public init(
        name: String,
        address: String,
        isPaired: Bool,
        isConnected: Bool,
        classOfDevice: UInt32
    ) {
        self.name = name
        self.address = address
        self.isPaired = isPaired
        self.isConnected = isConnected
        self.classOfDevice = classOfDevice
    }
}

public enum DeviceSelectionError: Error, Equatable, CustomStringConvertible {
    case invalidConfiguredAddress(String)
    case noMagicMouseDevices
    case configuredAddressNotFound(configuredAddress: String, candidateCount: Int)
    case multipleMatches(configuredAddress: String, matchCount: Int)

    public var description: String {
        switch self {
        case .invalidConfiguredAddress(let address):
            return "Configured Bluetooth address is invalid: \(address)"
        case .noMagicMouseDevices:
            return "No paired device has a name containing \"Magic Mouse\"."
        case .configuredAddressNotFound(let address, let candidateCount):
            return "Configured Bluetooth address \(address) did not match any of the \(candidateCount) paired Magic Mouse device(s)."
        case .multipleMatches(let address, let matchCount):
            return "Configured Bluetooth address \(address) matched \(matchCount) paired Magic Mouse records; exactly one is required."
        }
    }
}

public enum DeviceSelector {
    public static func nameContainsMagicMouse(_ name: String) -> Bool {
        name.range(of: "Magic Mouse", options: [.caseInsensitive]) != nil
    }

    public static func select(
        from devices: [PairedBluetoothDevice],
        configuredAddress: String
    ) throws -> PairedBluetoothDevice {
        guard let normalizedConfiguredAddress = BluetoothAddressNormalizer.normalize(configuredAddress) else {
            throw DeviceSelectionError.invalidConfiguredAddress(configuredAddress)
        }

        let candidates = devices.filter { device in
            nameContainsMagicMouse(device.name)
        }

        guard !candidates.isEmpty else {
            throw DeviceSelectionError.noMagicMouseDevices
        }

        let matches = candidates.filter { device in
            BluetoothAddressNormalizer.normalize(device.address) == normalizedConfiguredAddress
        }

        guard !matches.isEmpty else {
            throw DeviceSelectionError.configuredAddressNotFound(
                configuredAddress: configuredAddress,
                candidateCount: candidates.count
            )
        }

        guard matches.count == 1 else {
            throw DeviceSelectionError.multipleMatches(
                configuredAddress: configuredAddress,
                matchCount: matches.count
            )
        }

        return matches[0]
    }
}
