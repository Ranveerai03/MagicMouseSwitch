import Foundation

public enum SystemSettingsWindowRetryReason: String, Equatable, Sendable {
    case processNotFound = "System Settings process not found"
    case axApplicationUnavailable = "AX application unavailable"
    case windowsUnreadable = "System Settings windows unreadable"
    case noWindows = "System Settings has no windows"
    case bluetoothWindowNotFound = "Bluetooth window not found"
}

public struct SystemSettingsWindowObservation: Equatable, Sendable {
    public let processCount: Int
    public let axApplicationCount: Int
    public let readableProcessCount: Int
    public let windowCount: Int
    public let bluetoothWindowFound: Bool

    public init(
        processCount: Int,
        axApplicationCount: Int,
        readableProcessCount: Int,
        windowCount: Int,
        bluetoothWindowFound: Bool
    ) {
        self.processCount = processCount
        self.axApplicationCount = axApplicationCount
        self.readableProcessCount = readableProcessCount
        self.windowCount = windowCount
        self.bluetoothWindowFound = bluetoothWindowFound
    }
}

public enum SystemSettingsWindowDecision: Equatable, Sendable {
    case acquired
    case retry(reason: SystemSettingsWindowRetryReason)
    case foregroundAndNavigate(reason: SystemSettingsWindowRetryReason)
    case exhausted(reason: SystemSettingsWindowRetryReason)
}

public enum SystemSettingsWindowAcquisitionPolicy {
    public static func bluetoothWindowMatches(
        title: String?,
        hierarchyLabels: [String],
        selectedDeviceName: String
    ) -> Bool {
        if title?.caseInsensitiveCompare("Bluetooth") == .orderedSame {
            return true
        }

        let hasBluetoothLabel = hierarchyLabels.contains {
            $0.caseInsensitiveCompare("Bluetooth") == .orderedSame
        }
        let hasSelectedDevice = hierarchyLabels.contains(selectedDeviceName)
        let hasKnownDeviceControl = hierarchyLabels.contains("Show Detail")
            || hierarchyLabels.contains("Forget This Device…")

        return hasSelectedDevice && (hasBluetoothLabel || hasKnownDeviceControl)
    }

    public static func decision(
        for observation: SystemSettingsWindowObservation,
        additionalNavigationPerformed: Bool,
        deadlineReached: Bool
    ) -> SystemSettingsWindowDecision {
        if observation.bluetoothWindowFound {
            return .acquired
        }

        let reason = retryReason(for: observation)
        if deadlineReached {
            return .exhausted(reason: reason)
        }

        switch reason {
        case .windowsUnreadable, .noWindows, .bluetoothWindowNotFound:
            if !additionalNavigationPerformed {
                return .foregroundAndNavigate(reason: reason)
            }
        case .processNotFound, .axApplicationUnavailable:
            break
        }

        return .retry(reason: reason)
    }

    private static func retryReason(
        for observation: SystemSettingsWindowObservation
    ) -> SystemSettingsWindowRetryReason {
        if observation.processCount == 0 {
            return .processNotFound
        }
        if observation.axApplicationCount == 0 {
            return .axApplicationUnavailable
        }
        if observation.readableProcessCount == 0 {
            return .windowsUnreadable
        }
        if observation.windowCount == 0 {
            return .noWindows
        }
        return .bluetoothWindowNotFound
    }
}
