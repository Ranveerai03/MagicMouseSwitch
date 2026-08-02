@preconcurrency import AppKit
@preconcurrency import ApplicationServices
import DeviceSelectionCore
import Foundation

private let pairSystemSettingsBundleIdentifier = "com.apple.systempreferences"
private let pairPreflightTimeout: TimeInterval = 3
private let pairPreflightPollInterval: TimeInterval = 0.1
private let pairInitialSettlingDelay: TimeInterval = 0.75
private let pairRetrySettlingDelay: TimeInterval = 1
private let ownershipRecordLifetime: TimeInterval = 10 * 60

struct ForgetSettingsOwnershipSeed: Sendable {
    let settingsWasRunning: Bool
    let bluetoothWindowWasOpen: Bool
    let unrelatedSettingsWindowsPresent: Bool
    let previousSettingsPane: String?
}

private struct ForgetSettingsOwnershipRecord: Sendable {
    let seed: ForgetSettingsOwnershipSeed
    let bluetoothWindowOpenedByApp: Bool
    let recordedAt: Date
}

private final class SystemSettingsOwnershipStore: @unchecked Sendable {
    static let shared = SystemSettingsOwnershipStore()
    private let lock = NSLock()
    private var record: ForgetSettingsOwnershipRecord?

    func recordForgetNavigation(_ seed: ForgetSettingsOwnershipSeed) {
        lock.lock()
        record = ForgetSettingsOwnershipRecord(
            seed: seed,
            bluetoothWindowOpenedByApp: !seed.bluetoothWindowWasOpen,
            recordedAt: Date()
        )
        lock.unlock()
    }

    func recentRecord() -> ForgetSettingsOwnershipRecord? {
        lock.lock()
        defer { lock.unlock() }
        guard let record,
              Date().timeIntervalSince(record.recordedAt) <= ownershipRecordLifetime else {
            self.record = nil
            return nil
        }
        return record
    }
}

enum SystemSettingsOwnershipTracker {
    static func recordForgetNavigation(_ seed: ForgetSettingsOwnershipSeed) {
        SystemSettingsOwnershipStore.shared.recordForgetNavigation(seed)
    }
}

private struct PairSettingsAXNode {
    let element: AXUIElement
    let role: String
    let identifier: String?
    let title: String?
    let description: String?
    let value: String?
    let actions: [String]

    var labels: [String] {
        [title, description, value].compactMap { $0 }
    }

    func hasExactLabel(_ label: String) -> Bool {
        labels.contains(label)
    }
}

private struct PairSettingsWindowSnapshot {
    let processIdentifier: pid_t
    let window: AXUIElement
    let title: String?
    let nodes: [PairSettingsAXNode]
    let bluetoothContentActive: Bool
    let bluetoothSpinnerPresent: Bool
}

private struct PairSettingsSnapshot {
    let applications: [NSRunningApplication]
    let windows: [PairSettingsWindowSnapshot]
    let unreadableProcessIdentifiers: [pid_t]

    var bluetoothWindows: [PairSettingsWindowSnapshot] {
        windows.filter(\.bluetoothContentActive)
    }

    var unrelatedWindowTitles: [String] {
        windows.filter { !$0.bluetoothContentActive }.map { $0.title ?? "<untitled>" }
    }

    var bluetoothSpinnerPresent: Bool {
        bluetoothWindows.contains(where: \.bluetoothSpinnerPresent)
    }
}

final class PairSystemSettingsCoordinator: @unchecked Sendable {
    private let event: MagicMouseEventHandler
    private(set) var state: PairSettingsOperationState?

    init(event: @escaping MagicMouseEventHandler) {
        self.event = event
    }

    func updateState(_ operationState: PairSettingsOperationState) {
        state = operationState
    }

    func prepareBeforeInquiry() throws -> PairSettingsOperationState {
        let deadline = Date().addingTimeInterval(pairPreflightTimeout)
        let snapshot = try readableSnapshot(
            initial: snapshotSystemSettings(),
            deadline: deadline,
            context: "before Pair"
        )
        let recentOwnership = SystemSettingsOwnershipStore.shared.recentRecord()
        let bluetoothPresent = !snapshot.bluetoothWindows.isEmpty
        let appOpenedBluetooth = recentOwnership?.bluetoothWindowOpenedByApp == true
            && bluetoothPresent
        let previousPane = appOpenedBluetooth
            ? recentOwnership?.seed.previousSettingsPane
            : snapshot.bluetoothWindows.first?.title
        var operationState = PairSettingsOperationState(
            settingsWasRunningBeforeOperation: recentOwnership?.seed.settingsWasRunning
                ?? !snapshot.applications.isEmpty,
            bluetoothWindowWasOpenBeforeOperation: recentOwnership?.seed.bluetoothWindowWasOpen
                ?? bluetoothPresent,
            bluetoothWindowOpenedByApp: appOpenedBluetooth,
            unrelatedSettingsWindowsPresent: !snapshot.unrelatedWindowTitles.isEmpty,
            previousSettingsPane: previousPane,
            bluetoothSettingsOpenRecently: bluetoothPresent || appOpenedBluetooth
        )
        defer { state = operationState }
        logSnapshot(snapshot, context: "before Pair")
        event("System Settings running before Pair: \(!snapshot.applications.isEmpty)")
        event("Bluetooth window present before Pair: \(bluetoothPresent)")
        event("Bluetooth hierarchy/spinner detected: \(bluetoothPresent)/\(snapshot.bluetoothSpinnerPresent)")
        event(
            "Bluetooth window ownership: "
                + (appOpenedBluetooth ? "opened by Magic Mouse Switch" : "user-preexisting or unknown")
        )
        event("unrelated System Settings windows: \(snapshot.unrelatedWindowTitles)")
        event("previous Settings pane: \(previousPane ?? "<unknown>")")

        if bluetoothPresent {
            guard MagicMouseAccessibilityService.isTrusted(prompt: false) else {
                throw MagicMouseServiceError(
                    "Accessibility permission is required to clear Bluetooth Settings inquiry contention"
                )
            }
            try clearBluetoothContent(
                state: &operationState,
                initialSnapshot: snapshot,
                deadline: deadline
            )
            try settleAndVerify(
                delay: pairInitialSettlingDelay,
                deadline: deadline,
                context: "initial Pair preflight"
            )
        }
        return operationState
    }

    func prepareBeforeRetry(_ operationState: inout PairSettingsOperationState) throws {
        defer { state = operationState }
        let deadline = Date().addingTimeInterval(pairPreflightTimeout)
        let snapshot = try readableSnapshot(
            initial: snapshotSystemSettings(),
            deadline: deadline,
            context: "before inquiry retry"
        )
        logSnapshot(snapshot, context: "before inquiry retry")
        if !snapshot.bluetoothWindows.isEmpty {
            guard MagicMouseAccessibilityService.isTrusted(prompt: false) else {
                throw MagicMouseServiceError(
                    "Accessibility permission is required to clear recurring Bluetooth Settings contention"
                )
            }
            try clearBluetoothContent(
                state: &operationState,
                initialSnapshot: snapshot,
                deadline: deadline
            )
        }
        try settleAndVerify(
            delay: pairRetrySettlingDelay,
            deadline: deadline,
            context: "inquiry retry"
        )
        operationState.bluetoothSettingsOpenRecently = true
    }

    func restoreAfterPairing() {
        guard let state else {
            event("System Settings restoration result: no Pair preflight state")
            return
        }
        switch PairSettingsContentionPolicy.restorationDecision(for: state) {
        case .none:
            event("System Settings restoration result: no restoration required")
        case .preserveUnrelatedWindows:
            event(
                "System Settings restoration result: unrelated windows preserved; "
                    + "Bluetooth scanning was not reopened"
            )
        case .leaveOnGeneral:
            let previous = state.previousSettingsPane ?? "<unknown>"
            event(
                "System Settings restoration result: left open on General; previous pane \(previous) "
                    + "was not reopened because Bluetooth scanning must remain inactive"
            )
        case .terminateAppOpenedSettings:
            let snapshot = snapshotSystemSettings()
            guard snapshot.unreadableProcessIdentifiers.isEmpty,
                  snapshot.unrelatedWindowTitles.isEmpty,
                  snapshot.bluetoothWindows.isEmpty else {
                event(
                    "System Settings restoration result: termination refused because user state exists"
                )
                return
            }
            let results = snapshot.applications.map { application in
                (application.processIdentifier, application.terminate())
            }
            event(
                "System Settings restoration result: terminated app-opened Settings with no "
                    + "pre-existing or unrelated windows; results \(results)"
            )
        }
    }

    private func clearBluetoothContent(
        state: inout PairSettingsOperationState,
        initialSnapshot: PairSettingsSnapshot,
        deadline: Date
    ) throws {
        let action = PairSettingsContentionPolicy.mitigation(
            bluetoothContentActive: !initialSnapshot.bluetoothWindows.isEmpty,
            state: state
        )
        switch action {
        case .none:
            return
        case .closeAppCreatedBluetoothWindow:
            if initialSnapshot.bluetoothWindows.count == 1,
               closeFreshBluetoothWindow() {
                if waitForBluetoothContentToDisappear(deadline: deadline) {
                    state.bluetoothWindowClosedForPairing = true
                    event("verified disappearance of Bluetooth hierarchy after window close")
                    return
                }
                event("Bluetooth window close postcondition failed; navigating to General")
            } else {
                event(
                    "Bluetooth window close skipped because a unique app-created Bluetooth window "
                        + "could not be resolved; navigating to General"
                )
            }
            try navigateToGeneralAndVerify(state: &state, deadline: deadline)
        case .navigateToGeneral:
            try navigateToGeneralAndVerify(state: &state, deadline: deadline)
        }
    }

    private func closeFreshBluetoothWindow() -> Bool {
        let snapshot = snapshotSystemSettings()
        guard snapshot.bluetoothWindows.count == 1,
              let bluetoothWindow = snapshot.bluetoothWindows.first else {
            return false
        }
        var closeValue: CFTypeRef?
        let copyResult = AXUIElementCopyAttributeValue(
            bluetoothWindow.window,
            kAXCloseButtonAttribute as CFString,
            &closeValue
        )
        guard copyResult == .success,
              let closeValue,
              CFGetTypeID(closeValue) == AXUIElementGetTypeID() else {
            event("close Bluetooth window AX close-button result: \(copyResult.rawValue)")
            return false
        }
        let result = AXUIElementPerformAction(
            closeValue as! AXUIElement,
            kAXPressAction as CFString
        )
        event("close Bluetooth window AXPress result: \(result.rawValue)")
        return true
    }

    private func navigateToGeneralAndVerify(
        state: inout PairSettingsOperationState,
        deadline: Date
    ) throws {
        let snapshot = snapshotSystemSettings()
        let generalButtons = snapshot.bluetoothWindows.flatMap(\.nodes).filter {
            $0.role == kAXButtonRole
                && ($0.identifier == "com.apple.settings.general" || $0.hasExactLabel("General"))
                && $0.actions.contains(kAXPressAction)
        }
        if generalButtons.count == 1 {
            let result = AXUIElementPerformAction(
                generalButtons[0].element,
                kAXPressAction as CFString
            )
            event("navigate away from Bluetooth to General AXPress result: \(result.rawValue)")
        } else {
            guard let url = URL(
                string: "x-apple.systempreferences:com.apple.systempreferences.GeneralSettings"
            ) else {
                throw MagicMouseServiceError("could not construct General Settings URL")
            }
            let opened = NSWorkspace.shared.open(url)
            event("navigate away from Bluetooth using General Settings URL result: \(opened)")
            guard opened else {
                throw MagicMouseServiceError("could not navigate System Settings away from Bluetooth")
            }
        }
        guard waitForBluetoothContentToDisappear(deadline: deadline) else {
            throw MagicMouseServiceError(
                "Bluetooth Settings hierarchy remained active after navigating to General"
            )
        }
        state.navigatedToNeutralPane = true
        event("verified disappearance of Bluetooth hierarchy after navigating to General")
    }

    private func settleAndVerify(
        delay: TimeInterval,
        deadline: Date,
        context: String
    ) throws {
        let remaining = deadline.timeIntervalSinceNow
        guard remaining >= delay else {
            throw MagicMouseServiceError("\(context) exceeded bounded preflight time")
        }
        event(String(format: "%@ contention settling delay %.3f seconds", context, delay))
        Thread.sleep(forTimeInterval: delay)
        let snapshot = snapshotSystemSettings()
        logSnapshot(snapshot, context: "after \(context) settling delay")
        guard snapshot.unreadableProcessIdentifiers.isEmpty,
              snapshot.bluetoothWindows.isEmpty else {
            throw MagicMouseServiceError(
                "Bluetooth Settings hierarchy reappeared after \(context) settling delay"
            )
        }
        event("verified Bluetooth hierarchy absent after \(context) settling delay")
    }

    private func waitForBluetoothContentToDisappear(deadline: Date) -> Bool {
        repeat {
            let snapshot = snapshotSystemSettings()
            if snapshot.unreadableProcessIdentifiers.isEmpty,
               snapshot.bluetoothWindows.isEmpty { return true }
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0 else { break }
            Thread.sleep(forTimeInterval: min(pairPreflightPollInterval, remaining))
        } while Date() < deadline
        return false
    }

    private func readableSnapshot(
        initial: PairSettingsSnapshot,
        deadline: Date,
        context: String
    ) throws -> PairSettingsSnapshot {
        var snapshot = initial
        while !snapshot.applications.isEmpty
            && !snapshot.unreadableProcessIdentifiers.isEmpty {
            guard MagicMouseAccessibilityService.isTrusted(prompt: false) else {
                throw MagicMouseServiceError(
                    "Accessibility permission is required to inspect System Settings during \(context)"
                )
            }
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0 else {
                throw MagicMouseServiceError(
                    "System Settings windows remained unreadable during bounded Pair preflight"
                )
            }
            event(
                "System Settings snapshot retry [\(context)]: unreadable PIDs "
                    + "\(snapshot.unreadableProcessIdentifiers)"
            )
            Thread.sleep(forTimeInterval: min(pairPreflightPollInterval, remaining))
            snapshot = snapshotSystemSettings()
        }
        return snapshot
    }

    private func logSnapshot(_ snapshot: PairSettingsSnapshot, context: String) {
        event(
            "System Settings snapshot [\(context)]: PIDs "
                + "\(snapshot.applications.map(\.processIdentifier)); readable windows "
                + "\(snapshot.windows.map { $0.title ?? "<untitled>" }); unreadable PIDs "
                + "\(snapshot.unreadableProcessIdentifiers)"
        )
        event(
            "Bluetooth snapshot [\(context)]: windows \(snapshot.bluetoothWindows.count); "
                + "hierarchy active \(!snapshot.bluetoothWindows.isEmpty); "
                + "spinner present \(snapshot.bluetoothSpinnerPresent)"
        )
    }

    private func snapshotSystemSettings() -> PairSettingsSnapshot {
        let applications = NSRunningApplication.runningApplications(
            withBundleIdentifier: pairSystemSettingsBundleIdentifier
        )
        .filter { !$0.isTerminated }
        .sorted { $0.processIdentifier < $1.processIdentifier }
        var windows: [PairSettingsWindowSnapshot] = []
        var unreadable: [pid_t] = []
        for application in applications {
            let axApplication = AXUIElementCreateApplication(application.processIdentifier)
            var value: CFTypeRef?
            let result = AXUIElementCopyAttributeValue(
                axApplication,
                kAXWindowsAttribute as CFString,
                &value
            )
            guard result == .success, let axWindows = value as? [AXUIElement] else {
                unreadable.append(application.processIdentifier)
                continue
            }
            for window in axWindows {
                guard let nodes = hierarchy(from: window) else {
                    unreadable.append(application.processIdentifier)
                    continue
                }
                let title = stringAttribute(window, kAXTitleAttribute)
                let labels = nodes.flatMap(\.labels)
                let roles = nodes.map(\.role)
                let active = PairSettingsContentionPolicy.bluetoothContentActive(
                    windowTitle: title,
                    hierarchyLabels: labels,
                    hierarchyRoles: roles
                )
                windows.append(
                    PairSettingsWindowSnapshot(
                        processIdentifier: application.processIdentifier,
                        window: window,
                        title: title,
                        nodes: nodes,
                        bluetoothContentActive: active,
                        bluetoothSpinnerPresent: active
                            && roles.contains(kAXProgressIndicatorRole)
                    )
                )
            }
        }
        return PairSettingsSnapshot(
            applications: applications,
            windows: windows,
            unreadableProcessIdentifiers: Array(Set(unreadable)).sorted()
        )
    }

    private func hierarchy(from window: AXUIElement) -> [PairSettingsAXNode]? {
        var nodes: [PairSettingsAXNode] = []
        func visit(_ element: AXUIElement, depth: Int) -> Bool {
            guard depth <= 32 else { return false }
            nodes.append(
                PairSettingsAXNode(
                    element: element,
                    role: stringAttribute(element, kAXRoleAttribute) ?? "<missing role>",
                    identifier: stringAttribute(element, kAXIdentifierAttribute),
                    title: stringAttribute(element, kAXTitleAttribute),
                    description: stringAttribute(element, kAXDescriptionAttribute),
                    value: stringAttribute(element, kAXValueAttribute),
                    actions: actions(of: element)
                )
            )
            for child in children(of: element) {
                guard visit(child, depth: depth + 1) else { return false }
            }
            return true
        }
        return visit(window, depth: 0) ? nodes : nil
    }

    private func copiedAttribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(element, name as CFString, &value)
        return error == .success ? value : nil
    }

    private func stringAttribute(_ element: AXUIElement, _ name: String) -> String? {
        guard let value = copiedAttribute(element, name),
              CFGetTypeID(value) == CFStringGetTypeID() else { return nil }
        return value as? String
    }

    private func children(of element: AXUIElement) -> [AXUIElement] {
        copiedAttribute(element, kAXChildrenAttribute) as? [AXUIElement] ?? []
    }

    private func actions(of element: AXUIElement) -> [String] {
        var value: CFArray?
        guard AXUIElementCopyActionNames(element, &value) == .success,
              let value else { return [] }
        return value as? [String] ?? []
    }
}
