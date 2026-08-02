import DeviceSelectionCore
import CoreBluetooth
import Foundation
import IOBluetooth

public let magicMousePinnedAddress = "d0-c0-50-d5-10-77"

public struct MagicMouseServiceError: Error, CustomStringConvertible, Sendable {
    public let message: String

    public init(_ message: String) {
        self.message = message
    }

    public var description: String { message }
}

public enum MagicMouseStatus: Equatable, Sendable {
    case connected(device: PairedBluetoothDevice)
    case pairedButDisconnected(device: PairedBluetoothDevice)
    case unpaired
    case unavailable(reason: String)

    public var displayName: String {
        switch self {
        case .connected:
            return "Connected"
        case .pairedButDisconnected:
            return "Paired but disconnected"
        case .unpaired:
            return "Unpaired"
        case .unavailable:
            return "Unavailable"
        }
    }

    public var isPaired: Bool {
        switch self {
        case .connected, .pairedButDisconnected:
            return true
        case .unpaired, .unavailable:
            return false
        }
    }
}

public struct PairOperationResult: Equatable, Sendable {
    public let inquiryDuration: TimeInterval
    public let pairingDuration: TimeInterval
    public let pairingResultCode: Int32
    public let device: PairedBluetoothDevice
}

public struct ForgetOperationResult: Equatable, Sendable {
    public let finalAXPressResult: Int32
}

public typealias MagicMouseEventHandler = @Sendable (String) -> Void

public struct AccessibilityTrustSnapshot: Equatable, Sendable {
    public let rawTrusted: Bool
    public let rawTrustedWithOptions: Bool

    public init(rawTrusted: Bool, rawTrustedWithOptions: Bool) {
        self.rawTrusted = rawTrusted
        self.rawTrustedWithOptions = rawTrustedWithOptions
    }

    public var isTrusted: Bool {
        rawTrusted || rawTrustedWithOptions
    }
}

public struct BluetoothAuthorizationSnapshot: Equatable, Sendable {
    public let rawValue: Int
    public let description: String
    public let isAuthorized: Bool

    public init(rawValue: Int, description: String, isAuthorized: Bool) {
        self.rawValue = rawValue
        self.description = description
        self.isAuthorized = isAuthorized
    }
}

public enum MagicMouseBluetoothAuthorizationService {
    public static func current() -> BluetoothAuthorizationSnapshot {
        let authorization = CBManager.authorization
        let description: String
        switch authorization {
        case .notDetermined:
            description = "notDetermined"
        case .restricted:
            description = "restricted"
        case .denied:
            description = "denied"
        case .allowedAlways:
            description = "allowedAlways"
        @unknown default:
            description = "unknown(\(authorization.rawValue))"
        }
        return BluetoothAuthorizationSnapshot(
            rawValue: authorization.rawValue,
            description: description,
            isAuthorized: authorization == .allowedAlways
        )
    }
}

public enum MagicMouseStatusService {
    public static func currentStatus(
        configuredAddress: String = magicMousePinnedAddress
    ) -> MagicMouseStatus {
        do {
            let devices = try readPairedDevices()
            let normalizedAddress = try PairSafety.normalizedConfiguredAddress(configuredAddress)
            let count = PairSafety.pairedAddressMatchCount(
                in: devices,
                normalizedConfiguredAddress: normalizedAddress
            )
            guard count > 0 else { return .unpaired }
            let device = try PairSafety.selectVerifiedPairedDevice(
                from: devices,
                configuredAddress: configuredAddress
            )
            return device.isConnected
                ? .connected(device: device)
                : .pairedButDisconnected(device: device)
        } catch {
            return .unavailable(reason: String(describing: error))
        }
    }
}

func bluetoothSnapshot(_ device: IOBluetoothDevice) -> PairedBluetoothDevice {
    PairedBluetoothDevice(
        name: device.name ?? "<unknown>",
        address: device.addressString ?? "<unavailable>",
        isPaired: device.isPaired(),
        isConnected: device.isConnected(),
        classOfDevice: device.classOfDevice
    )
}

func readPairedDevices() throws -> [PairedBluetoothDevice] {
    guard let objects = IOBluetoothDevice.pairedDevices() else {
        throw MagicMouseServiceError("IOBluetoothDevice.pairedDevices() returned nil")
    }
    return objects.compactMap { object in
        guard let device = object as? IOBluetoothDevice else { return nil }
        return bluetoothSnapshot(device)
    }
}

func elapsedSeconds(since start: ContinuousClock.Instant) -> TimeInterval {
    let elapsed = start.duration(to: .now)
    return Double(elapsed.components.seconds)
        + Double(elapsed.components.attoseconds) / 1_000_000_000_000_000_000
}

func serviceError(_ context: String, _ error: Error) -> MagicMouseServiceError {
    MagicMouseServiceError("\(context): \(error)")
}
