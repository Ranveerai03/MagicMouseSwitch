import AppKit
@preconcurrency import ApplicationServices
import DeviceSelectionCore
import Foundation

private let systemSettingsBundleIdentifier = "com.apple.systempreferences"
private let windowAcquisitionTimeoutSeconds: TimeInterval = 15
private let uiTransitionTimeoutSeconds: TimeInterval = 10
private let forgetCompletionTimeoutSeconds: TimeInterval = 20
private let pollingIntervalSeconds: TimeInterval = 0.25

private struct AXNode {
    let element: AXUIElement
    let path: String
    let role: String
    let title: String?
    let description: String?
    let value: String?
    let isEnabled: Bool?
    let actions: [String]

    func hasExactLabel(_ expected: String) -> Bool {
        [title, description, value].compactMap { $0 }.contains(expected)
    }
}

private struct AXWindowHierarchy {
    let nodes: [AXNode]
    let title: String?
}

private enum AXWindowEnumeration {
    case readable([AXWindowHierarchy])
    case unreadable(error: AXError)
}

private struct MagicMouseRow {
    let status: String
    let showDetailButton: AXNode
}

private struct DetailsState {
    let forgetButton: AXNode
}

private struct ConfirmationState {
    let forgetDeviceButton: AXNode
}

public enum MagicMouseAccessibilityService {
    public static func currentTrust() -> AccessibilityTrustSnapshot {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        return AccessibilityTrustSnapshot(
            rawTrusted: AXIsProcessTrusted(),
            rawTrustedWithOptions: AXIsProcessTrustedWithOptions(
                [key: false] as CFDictionary
            )
        )
    }

    public static func isTrusted(prompt: Bool) -> Bool {
        if !prompt {
            return currentTrust().isTrusted
        }
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        return AXIsProcessTrustedWithOptions([key: prompt] as CFDictionary)
    }

    public static func openAccessibilitySettings() -> Bool {
        guard let url = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
        ) else {
            return false
        }
        return NSWorkspace.shared.open(url)
    }
}

private final class ForgetRuntime {
    let configuredAddress: String
    let event: MagicMouseEventHandler

    init(configuredAddress: String, event: @escaping MagicMouseEventHandler) {
        self.configuredAddress = configuredAddress
        self.event = event
    }

    func run() throws -> ForgetOperationResult {
        let initialSelection = try selectEligible(context: "initial selection failed")
        event(
            String(
                format: "selected device: %@, %@, class 0x%06X",
                initialSelection.name,
                initialSelection.address,
                initialSelection.classOfDevice
            )
        )
        guard MagicMouseAccessibilityService.isTrusted(prompt: false) else {
            throw MagicMouseServiceError("Accessibility permission is required")
        }
        try revalidate(initialSelection, context: "pre-System Settings validation failed")

        guard let bluetoothURL = URL(
            string: "x-apple.systempreferences:com.apple.BluetoothSettings"
        ) else {
            throw MagicMouseServiceError("could not construct Bluetooth settings URL")
        }
        let settingsOwnership = snapshotExistingSystemSettings(
            selectedDeviceName: initialSelection.name
        )
        let existing = runningSystemSettingsApplications()
        if !existing.isEmpty {
            let activated = foreground(existing)
            event("pre-existing System Settings foreground result: \(activated)")
        }
        let acquisitionDeadline = Date().addingTimeInterval(
            windowAcquisitionTimeoutSeconds
        )
        guard NSWorkspace.shared.open(bluetoothURL) else {
            throw MagicMouseServiceError("could not open Bluetooth settings URL")
        }
        SystemSettingsOwnershipTracker.recordForgetNavigation(settingsOwnership)
        event("Bluetooth settings URL opened")
        let processIdentifier = try acquireBluetoothWindowProcess(
            bluetoothURL: bluetoothURL,
            selectedDeviceName: initialSelection.name,
            deadline: acquisitionDeadline
        )

        guard waitForBluetoothHierarchy(
            processIdentifier: processIdentifier,
            selectedDeviceName: initialSelection.name,
            timeout: uiTransitionTimeoutSeconds,
            predicate: { nodes in
                nodes.contains {
                    $0.role == kAXStaticTextRole && $0.value == initialSelection.name
                } && !nodes.contains { $0.role == kAXSheetRole }
            }
        ) != nil else {
            throw MagicMouseServiceError(
                "Bluetooth page did not reach the expected base state within 10 seconds"
            )
        }

        try revalidate(initialSelection, context: "pre-Show Detail validation failed")
        let row = try resolveMagicMouseRow(
            in: try freshBluetoothHierarchy(
                processIdentifier: processIdentifier,
                selectedDeviceName: initialSelection.name
            ),
            selectedName: initialSelection.name
        )
        event("Bluetooth UI status: \(row.status)")
        _ = try pressVerifiedButton(
            row.showDetailButton,
            description: "verified Show Detail button"
        )

        guard waitForBluetoothHierarchy(
            processIdentifier: processIdentifier,
            selectedDeviceName: initialSelection.name,
            timeout: uiTransitionTimeoutSeconds,
            predicate: { nodes in
                nodes.contains {
                    $0.role == kAXButtonRole && $0.description == "Forget This Device…"
                }
            }
        ) != nil else {
            throw MagicMouseServiceError("details sheet did not appear within 10 seconds")
        }

        try revalidate(initialSelection, context: "pre-Forget This Device validation failed")
        let details = try resolveDetailsState(
            in: try freshBluetoothHierarchy(
                processIdentifier: processIdentifier,
                selectedDeviceName: initialSelection.name
            ),
            selectedName: initialSelection.name
        )
        _ = try pressVerifiedButton(
            details.forgetButton,
            description: "verified Forget This Device… button"
        )

        guard waitForBluetoothHierarchy(
            processIdentifier: processIdentifier,
            selectedDeviceName: initialSelection.name,
            timeout: uiTransitionTimeoutSeconds,
            predicate: { nodes in
                nodes.contains {
                    $0.role == kAXStaticTextRole
                        && ($0.value?.contains("Are you sure you want to forget") ?? false)
                        && ($0.value?.contains(initialSelection.name) ?? false)
                }
            }
        ) != nil else {
            throw MagicMouseServiceError("exact-name Forget confirmation did not appear")
        }

        try revalidate(initialSelection, context: "pre-final-Forget validation failed")
        let confirmation = try resolveConfirmationState(
            in: try freshBluetoothHierarchy(
                processIdentifier: processIdentifier,
                selectedDeviceName: initialSelection.name
            ),
            selectedName: initialSelection.name
        )
        let finalPressResult = try pressVerifiedButton(
            confirmation.forgetDeviceButton,
            description: "verified final Forget Device button"
        )

        let completionDeadline = Date().addingTimeInterval(forgetCompletionTimeoutSeconds)
        var completed = try !pairedDevicesContainAddress()
        while !completed {
            let remaining = completionDeadline.timeIntervalSinceNow
            guard remaining > 0 else { break }
            Thread.sleep(forTimeInterval: min(pollingIntervalSeconds, remaining))
            completed = try !pairedDevicesContainAddress()
        }
        event(
            "Forget postcondition: address removed \(completed); final AX result \(finalPressResult.rawValue)"
        )
        guard completed else {
            throw MagicMouseServiceError(
                "configured address remained paired after 20 seconds; final AXPress result was \(finalPressResult.rawValue)"
            )
        }
        return ForgetOperationResult(finalAXPressResult: finalPressResult.rawValue)
    }

    private func selectEligible(context: String) throws -> PairedBluetoothDevice {
        do {
            return try ForgetSafety.selectEligibleDevice(
                from: readPairedDevices(),
                configuredAddress: configuredAddress
            )
        } catch {
            throw serviceError(context, error)
        }
    }

    private func revalidate(
        _ expected: PairedBluetoothDevice,
        context: String
    ) throws {
        let current = try selectEligible(context: context)
        guard current == expected else {
            throw MagicMouseServiceError(
                "\(context): selected device changed; expected \(expected), observed \(current)"
            )
        }
    }

    private func pairedDevicesContainAddress() throws -> Bool {
        guard let normalized = BluetoothAddressNormalizer.normalize(configuredAddress) else {
            throw MagicMouseServiceError("configured Bluetooth address became invalid")
        }
        return try readPairedDevices().contains {
            BluetoothAddressNormalizer.normalize($0.address) == normalized
        }
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

    private func boolAttribute(_ element: AXUIElement, _ name: String) -> Bool? {
        guard let value = copiedAttribute(element, name),
              CFGetTypeID(value) == CFBooleanGetTypeID() else { return nil }
        return CFBooleanGetValue((value as! CFBoolean))
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

    private func hierarchy(from window: AXUIElement, index: Int) -> [AXNode]? {
        var nodes: [AXNode] = []
        func visit(_ element: AXUIElement, path: String, depth: Int) -> Bool {
            guard depth <= 32 else { return false }
            nodes.append(
                AXNode(
                    element: element,
                    path: path,
                    role: stringAttribute(element, kAXRoleAttribute) ?? "<missing role>",
                    title: stringAttribute(element, kAXTitleAttribute),
                    description: stringAttribute(element, kAXDescriptionAttribute),
                    value: stringAttribute(element, kAXValueAttribute),
                    isEnabled: boolAttribute(element, kAXEnabledAttribute),
                    actions: actions(of: element)
                )
            )
            for (childIndex, child) in children(of: element).enumerated() {
                guard visit(
                    child,
                    path: "\(path)/child[\(childIndex)]",
                    depth: depth + 1
                ) else { return false }
            }
            return true
        }
        guard visit(window, path: "window[\(index)]", depth: 0) else { return nil }
        return nodes
    }

    private func enumerateWindows(from application: AXUIElement) -> AXWindowEnumeration {
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(
            application,
            kAXWindowsAttribute as CFString,
            &value
        )
        guard error == .success, let windows = value as? [AXUIElement] else {
            return .unreadable(error: error == .success ? .failure : error)
        }
        var result: [AXWindowHierarchy] = []
        for (index, window) in windows.enumerated() {
            guard let nodes = hierarchy(from: window, index: index) else {
                return .unreadable(error: .failure)
            }
            result.append(
                AXWindowHierarchy(
                    nodes: nodes,
                    title: stringAttribute(window, kAXTitleAttribute)
                )
            )
        }
        return .readable(result)
    }

    private func labels(_ hierarchy: AXWindowHierarchy) -> [String] {
        hierarchy.nodes.flatMap {
            [$0.title, $0.description, $0.value].compactMap { $0 }
        }
    }

    private func bluetoothHierarchy(
        in hierarchies: [AXWindowHierarchy],
        selectedDeviceName: String
    ) -> AXWindowHierarchy? {
        hierarchies.first {
            SystemSettingsWindowAcquisitionPolicy.bluetoothWindowMatches(
                title: $0.title,
                hierarchyLabels: labels($0),
                selectedDeviceName: selectedDeviceName
            )
        }
    }

    private func runningSystemSettingsApplications() -> [NSRunningApplication] {
        NSRunningApplication.runningApplications(
            withBundleIdentifier: systemSettingsBundleIdentifier
        )
        .filter { !$0.isTerminated }
        .sorted { $0.processIdentifier < $1.processIdentifier }
    }

    private func foreground(_ applications: [NSRunningApplication]) -> Bool {
        applications.reduce(true) { result, application in
            application.activate(options: [.activateIgnoringOtherApps]) && result
        }
    }

    private func snapshotExistingSystemSettings(
        selectedDeviceName: String
    ) -> ForgetSettingsOwnershipSeed {
        let applications = runningSystemSettingsApplications()
        var windowDescriptions: [String] = []
        var unrelatedWindowTitles: [String] = []
        var bluetoothOpen = false
        for application in applications {
            let axApplication = AXUIElementCreateApplication(application.processIdentifier)
            switch enumerateWindows(from: axApplication) {
            case .unreadable(let error):
                windowDescriptions.append(
                    "PID \(application.processIdentifier): unreadable \(error.rawValue)"
                )
            case .readable(let hierarchies):
                windowDescriptions += hierarchies.map {
                    "PID \(application.processIdentifier): \($0.title ?? "<untitled>")"
                }
                for hierarchy in hierarchies {
                    if bluetoothHierarchy(
                        in: [hierarchy],
                        selectedDeviceName: selectedDeviceName
                    ) != nil {
                        bluetoothOpen = true
                    } else {
                        unrelatedWindowTitles.append(hierarchy.title ?? "<untitled>")
                    }
                }
            }
        }
        event("System Settings pre-launch PIDs: \(applications.map(\.processIdentifier))")
        event("System Settings pre-launch windows: \(windowDescriptions)")
        event("Bluetooth settings already open: \(bluetoothOpen)")
        return ForgetSettingsOwnershipSeed(
            settingsWasRunning: !applications.isEmpty,
            bluetoothWindowWasOpen: bluetoothOpen,
            unrelatedSettingsWindowsPresent: !unrelatedWindowTitles.isEmpty,
            previousSettingsPane: unrelatedWindowTitles.count == 1
                ? unrelatedWindowTitles[0]
                : (bluetoothOpen ? "Bluetooth" : nil)
        )
    }

    private func acquireBluetoothWindowProcess(
        bluetoothURL: URL,
        selectedDeviceName: String,
        deadline: Date
    ) throws -> pid_t {
        var additionalNavigationPerformed = false
        while true {
            let applications = runningSystemSettingsApplications()
            var readableCount = 0
            var windowCount = 0
            for application in applications {
                event("System Settings process found: PID \(application.processIdentifier)")
                let axApplication = AXUIElementCreateApplication(application.processIdentifier)
                event("AX application acquired: PID \(application.processIdentifier)")
                switch enumerateWindows(from: axApplication) {
                case .unreadable(let error):
                    event("System Settings windows unreadable: AX error \(error.rawValue)")
                case .readable(let hierarchies):
                    readableCount += 1
                    windowCount += hierarchies.count
                    event("windows enumerated: \(hierarchies.count)")
                    if bluetoothHierarchy(
                        in: hierarchies,
                        selectedDeviceName: selectedDeviceName
                    ) != nil {
                        event("Bluetooth window found: PID \(application.processIdentifier)")
                        return application.processIdentifier
                    }
                }
            }
            let observation = SystemSettingsWindowObservation(
                processCount: applications.count,
                axApplicationCount: applications.count,
                readableProcessCount: readableCount,
                windowCount: windowCount,
                bluetoothWindowFound: false
            )
            let decision = SystemSettingsWindowAcquisitionPolicy.decision(
                for: observation,
                additionalNavigationPerformed: additionalNavigationPerformed,
                deadlineReached: Date() >= deadline
            )
            switch decision {
            case .acquired:
                throw MagicMouseServiceError("inconsistent acquisition state")
            case .exhausted(let reason):
                throw MagicMouseServiceError(
                    "Bluetooth window not acquired within 15 seconds: \(reason.rawValue)"
                )
            case .foregroundAndNavigate(let reason):
                event("System Settings acquisition retry: \(reason.rawValue)")
                _ = foreground(applications)
                additionalNavigationPerformed = true
                guard NSWorkspace.shared.open(bluetoothURL) else {
                    event("additional Bluetooth navigation failed")
                    break
                }
                event("Bluetooth settings URL opened for additional navigation")
            case .retry(let reason):
                event("System Settings acquisition retry: \(reason.rawValue)")
            }
            let remaining = deadline.timeIntervalSinceNow
            if remaining > 0 {
                Thread.sleep(forTimeInterval: min(pollingIntervalSeconds, remaining))
            }
        }
    }

    private func freshBluetoothHierarchy(
        processIdentifier: pid_t,
        selectedDeviceName: String
    ) throws -> [AXNode] {
        guard runningSystemSettingsApplications().contains(where: {
            $0.processIdentifier == processIdentifier
        }) else {
            throw MagicMouseServiceError("System Settings process disappeared")
        }
        let application = AXUIElementCreateApplication(processIdentifier)
        guard case .readable(let hierarchies) = enumerateWindows(from: application),
              let hierarchy = bluetoothHierarchy(
                  in: hierarchies,
                  selectedDeviceName: selectedDeviceName
              ) else {
            throw MagicMouseServiceError("could not read a fresh Bluetooth hierarchy")
        }
        return hierarchy.nodes
    }

    private func waitForBluetoothHierarchy(
        processIdentifier: pid_t,
        selectedDeviceName: String,
        timeout: TimeInterval,
        predicate: ([AXNode]) -> Bool
    ) -> [AXNode]? {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if let nodes = try? freshBluetoothHierarchy(
                processIdentifier: processIdentifier,
                selectedDeviceName: selectedDeviceName
            ), predicate(nodes) {
                return nodes
            }
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0 else { break }
            Thread.sleep(forTimeInterval: min(pollingIntervalSeconds, remaining))
        } while Date() < deadline
        return nil
    }

    private func descendants(of node: AXNode, in nodes: [AXNode]) -> [AXNode] {
        nodes.filter { $0.path == node.path || $0.path.hasPrefix(node.path + "/") }
    }

    private func resolveMagicMouseRow(
        in nodes: [AXNode],
        selectedName: String
    ) throws -> MagicMouseRow {
        guard !nodes.contains(where: { $0.role == kAXSheetRole }) else {
            throw MagicMouseServiceError("unexpected sheet on Bluetooth base page")
        }
        let names = nodes.filter {
            $0.role == kAXStaticTextRole && $0.value == selectedName
        }
        guard names.count == 1 else {
            throw MagicMouseServiceError("expected exactly one exact-name device row")
        }
        let name = names[0]
        guard let parentValue = copiedAttribute(name.element, kAXParentAttribute),
              CFGetTypeID(parentValue) == AXUIElementGetTypeID() else {
            throw MagicMouseServiceError("selected device name has no AX parent")
        }
        let siblings = children(of: parentValue as! AXUIElement)
        guard let index = siblings.firstIndex(where: { CFEqual($0, name.element) }),
              siblings.indices.contains(index + 2) else {
            throw MagicMouseServiceError("selected device adjacency changed")
        }
        let statusElement = siblings[index + 1]
        let detailElement = siblings[index + 2]
        guard stringAttribute(statusElement, kAXRoleAttribute) == kAXStaticTextRole,
              let status = stringAttribute(statusElement, kAXValueAttribute),
              !status.isEmpty else {
            throw MagicMouseServiceError("adjacent device status is invalid")
        }
        guard stringAttribute(detailElement, kAXRoleAttribute) == kAXButtonRole,
              stringAttribute(detailElement, kAXDescriptionAttribute) == "Show Detail" else {
            throw MagicMouseServiceError("adjacent Show Detail button is invalid")
        }
        let localButtons = siblings[index...(index + 2)].filter {
            stringAttribute($0, kAXRoleAttribute) == kAXButtonRole
                && stringAttribute($0, kAXDescriptionAttribute) == "Show Detail"
        }
        guard localButtons.count == 1 else {
            throw MagicMouseServiceError("device row does not have exactly one Show Detail")
        }
        return MagicMouseRow(
            status: status,
            showDetailButton: AXNode(
                element: detailElement,
                path: name.path + "/following-details",
                role: kAXButtonRole,
                title: stringAttribute(detailElement, kAXTitleAttribute),
                description: stringAttribute(detailElement, kAXDescriptionAttribute),
                value: stringAttribute(detailElement, kAXValueAttribute),
                isEnabled: boolAttribute(detailElement, kAXEnabledAttribute),
                actions: actions(of: detailElement)
            )
        )
    }

    private func resolveDetailsState(
        in nodes: [AXNode],
        selectedName: String
    ) throws -> DetailsState {
        let sheets = nodes.filter { sheet in
            guard sheet.role == kAXSheetRole else { return false }
            let subtree = descendants(of: sheet, in: nodes)
            return subtree.filter { $0.value == selectedName }.count == 1
                && subtree.filter {
                    $0.role == kAXButtonRole && $0.description == "Forget This Device…"
                }.count == 1
        }
        guard sheets.count == 1 else {
            throw MagicMouseServiceError("expected exactly one exact-name details sheet")
        }
        let buttons = descendants(of: sheets[0], in: nodes).filter {
            $0.role == kAXButtonRole && $0.description == "Forget This Device…"
        }
        guard buttons.count == 1 else {
            throw MagicMouseServiceError("details sheet Forget button count changed")
        }
        return DetailsState(forgetButton: buttons[0])
    }

    private func resolveConfirmationState(
        in nodes: [AXNode],
        selectedName: String
    ) throws -> ConfirmationState {
        let texts = nodes.filter {
            $0.role == kAXStaticTextRole
                && ($0.value?.contains("Are you sure you want to forget") ?? false)
                && ($0.value?.contains(selectedName) ?? false)
        }
        guard texts.count == 1 else {
            throw MagicMouseServiceError("expected exactly one exact-name confirmation text")
        }
        let sheets = nodes.filter {
            $0.role == kAXSheetRole && texts[0].path.hasPrefix($0.path + "/")
        }.sorted { $0.path.count > $1.path.count }
        guard let sheet = sheets.first else {
            throw MagicMouseServiceError("confirmation text is not inside an AXSheet")
        }
        let subtree = descendants(of: sheet, in: nodes)
        let cancel = subtree.filter {
            $0.role == kAXButtonRole && $0.hasExactLabel("Cancel")
        }
        let forget = subtree.filter {
            $0.role == kAXButtonRole && $0.hasExactLabel("Forget Device")
        }
        guard cancel.count == 1, forget.count == 1 else {
            throw MagicMouseServiceError("confirmation button counts changed")
        }
        return ConfirmationState(forgetDeviceButton: forget[0])
    }

    private func pressVerifiedButton(
        _ node: AXNode,
        description: String
    ) throws -> AXError {
        guard node.role == kAXButtonRole,
              node.isEnabled == true,
              node.actions.contains(kAXPressAction) else {
            throw MagicMouseServiceError(
                "\(description) is not an enabled AXButton advertising AXPress"
            )
        }
        let result = AXUIElementPerformAction(node.element, kAXPressAction as CFString)
        event("\(description) AXPress result: \(result.rawValue)")
        return result
    }
}

public enum MagicMouseForgetService {
    public static func run(
        configuredAddress: String = magicMousePinnedAddress,
        event: @escaping MagicMouseEventHandler = { _ in }
    ) throws -> ForgetOperationResult {
        try ForgetRuntime(configuredAddress: configuredAddress, event: event).run()
    }
}
