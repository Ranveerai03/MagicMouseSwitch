public enum ToggleStateBranch: Equatable, Sendable {
    case pair
    case forget
    case unavailable
}

public struct MenuCommandAvailability: Equatable, Sendable {
    public let pairEnabled: Bool
    public let forgetEnabled: Bool
    public let toggleEnabled: Bool
    public let refreshEnabled: Bool
    public let decision: String
}

public enum MenuBarOperationPolicy {
    public static func toggleBranch(for status: MagicMouseStatus) -> ToggleStateBranch {
        switch status {
        case .connected, .pairedButDisconnected:
            return .forget
        case .unpaired:
            return .pair
        case .unavailable:
            return .unavailable
        }
    }

    public static func availability(
        status: MagicMouseStatus,
        accessibilityTrusted: Bool,
        bluetoothAuthorized: Bool = true,
        operationActive: Bool
    ) -> MenuCommandAvailability {
        guard !operationActive else {
            return MenuCommandAvailability(
                pairEnabled: false,
                forgetEnabled: false,
                toggleEnabled: false,
                refreshEnabled: false,
                decision: "operation-active"
            )
        }
        guard bluetoothAuthorized else {
            return MenuCommandAvailability(
                pairEnabled: false,
                forgetEnabled: false,
                toggleEnabled: false,
                refreshEnabled: true,
                decision: "bluetooth-not-authorized"
            )
        }
        switch status {
        case .connected, .pairedButDisconnected:
            return MenuCommandAvailability(
                pairEnabled: false,
                forgetEnabled: accessibilityTrusted,
                toggleEnabled: accessibilityTrusted,
                refreshEnabled: true,
                decision: accessibilityTrusted
                    ? "paired-accessibility-trusted"
                    : "paired-accessibility-untrusted"
            )
        case .unpaired:
            return MenuCommandAvailability(
                pairEnabled: true,
                forgetEnabled: false,
                toggleEnabled: true,
                refreshEnabled: true,
                decision: accessibilityTrusted
                    ? "unpaired-accessibility-trusted"
                    : "unpaired-accessibility-not-required"
            )
        case .unavailable:
            return MenuCommandAvailability(
                pairEnabled: false,
                forgetEnabled: false,
                toggleEnabled: false,
                refreshEnabled: true,
                decision: "mouse-status-unavailable"
            )
        }
    }
}
