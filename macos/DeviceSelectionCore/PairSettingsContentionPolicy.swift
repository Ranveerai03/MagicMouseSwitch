import Foundation

public struct PairSettingsOperationState: Equatable, Sendable {
    public var settingsWasRunningBeforeOperation: Bool
    public var bluetoothWindowWasOpenBeforeOperation: Bool
    public var bluetoothWindowOpenedByApp: Bool
    public var unrelatedSettingsWindowsPresent: Bool
    public var bluetoothWindowClosedForPairing: Bool
    public var previousSettingsPane: String?
    public var inquiryAttemptNumber: Int
    public var bluetoothSettingsOpenRecently: Bool
    public var navigatedToNeutralPane: Bool

    public init(
        settingsWasRunningBeforeOperation: Bool,
        bluetoothWindowWasOpenBeforeOperation: Bool,
        bluetoothWindowOpenedByApp: Bool,
        unrelatedSettingsWindowsPresent: Bool,
        bluetoothWindowClosedForPairing: Bool = false,
        previousSettingsPane: String?,
        inquiryAttemptNumber: Int = 0,
        bluetoothSettingsOpenRecently: Bool,
        navigatedToNeutralPane: Bool = false
    ) {
        self.settingsWasRunningBeforeOperation = settingsWasRunningBeforeOperation
        self.bluetoothWindowWasOpenBeforeOperation = bluetoothWindowWasOpenBeforeOperation
        self.bluetoothWindowOpenedByApp = bluetoothWindowOpenedByApp
        self.unrelatedSettingsWindowsPresent = unrelatedSettingsWindowsPresent
        self.bluetoothWindowClosedForPairing = bluetoothWindowClosedForPairing
        self.previousSettingsPane = previousSettingsPane
        self.inquiryAttemptNumber = inquiryAttemptNumber
        self.bluetoothSettingsOpenRecently = bluetoothSettingsOpenRecently
        self.navigatedToNeutralPane = navigatedToNeutralPane
    }
}

public enum PairBluetoothSettingsMitigation: Equatable, Sendable {
    case none
    case closeAppCreatedBluetoothWindow
    case navigateToGeneral
}

public enum PairSettingsRestorationDecision: Equatable, Sendable {
    case none
    case preserveUnrelatedWindows
    case leaveOnGeneral
    case terminateAppOpenedSettings
}

public struct PairInquiryRetryObservation: Equatable, Sendable {
    public let attemptNumber: Int
    public let startReturnCode: Int32?
    public let deviceFoundCallbackCount: Int
    public let completionError: Int32?
    public let pinnedAddressFound: Bool
    public let bluetoothSettingsOpenRecently: Bool

    public init(
        attemptNumber: Int,
        startReturnCode: Int32?,
        deviceFoundCallbackCount: Int,
        completionError: Int32?,
        pinnedAddressFound: Bool,
        bluetoothSettingsOpenRecently: Bool
    ) {
        self.attemptNumber = attemptNumber
        self.startReturnCode = startReturnCode
        self.deviceFoundCallbackCount = deviceFoundCallbackCount
        self.completionError = completionError
        self.pinnedAddressFound = pinnedAddressFound
        self.bluetoothSettingsOpenRecently = bluetoothSettingsOpenRecently
    }
}

public struct PairOperationCompletionGate: Equatable, Sendable {
    public private(set) var completionCount = 0

    public init() {}

    public mutating func recordCompletion() -> Bool {
        completionCount += 1
        return completionCount == 1
    }
}

public enum PairSettingsContentionPolicy {
    public static func bluetoothContentActive(
        windowTitle: String?,
        hierarchyLabels: [String],
        hierarchyRoles: [String]
    ) -> Bool {
        if windowTitle?.caseInsensitiveCompare("Bluetooth") == .orderedSame {
            return true
        }
        let labels = hierarchyLabels.map { $0.lowercased() }
        let hasBluetoothLabel = labels.contains("bluetooth")
        let hasDeviceList = labels.contains("nearby devices")
            || labels.contains("my devices")
            || labels.contains("show detail")
        let hasSpinner = hierarchyRoles.contains("AXProgressIndicator")
        return hasBluetoothLabel && (hasDeviceList || hasSpinner)
    }

    public static func mitigation(
        bluetoothContentActive: Bool,
        state: PairSettingsOperationState
    ) -> PairBluetoothSettingsMitigation {
        guard bluetoothContentActive else { return .none }
        if state.bluetoothWindowOpenedByApp
            && (!state.settingsWasRunningBeforeOperation
                || state.unrelatedSettingsWindowsPresent) {
            return .closeAppCreatedBluetoothWindow
        }
        return .navigateToGeneral
    }

    public static func shouldRetry(_ observation: PairInquiryRetryObservation) -> Bool {
        observation.attemptNumber == 1
            && observation.startReturnCode == 0
            && observation.deviceFoundCallbackCount == 0
            && observation.completionError == 1
            && !observation.pinnedAddressFound
            && observation.bluetoothSettingsOpenRecently
    }

    public static func restorationDecision(
        for state: PairSettingsOperationState
    ) -> PairSettingsRestorationDecision {
        guard state.bluetoothWindowClosedForPairing || state.navigatedToNeutralPane else {
            return .none
        }
        if state.unrelatedSettingsWindowsPresent {
            return .preserveUnrelatedWindows
        }
        if state.settingsWasRunningBeforeOperation {
            return .leaveOnGeneral
        }
        if state.bluetoothWindowOpenedByApp
            && state.navigatedToNeutralPane
            && !state.bluetoothWindowClosedForPairing {
            return .terminateAppOpenedSettings
        }
        return .none
    }
}
