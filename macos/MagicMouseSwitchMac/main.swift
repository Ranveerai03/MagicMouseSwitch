@preconcurrency import AppKit
@preconcurrency import ApplicationServices
import Foundation
import MagicMouseSwitchServices

private enum RequestedOperation: String, Sendable {
    case pair
    case forget
    case toggle
}

private struct LiveStateSnapshot: Sendable {
    let accessibility: AccessibilityTrustSnapshot
    let bluetooth: BluetoothAuthorizationSnapshot
    let mouseStatus: MagicMouseStatus
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate, @unchecked Sendable {
    private let logger: AppLogger
    private let popup = StatusPopup()
    private let stateLock = NSLock()
    private var operationActive = false
    private var currentStatus = MagicMouseStatus.unavailable(reason: "Refreshing")
    private var accessibilityTrusted = false
    private var bluetoothAuthorization = BluetoothAuthorizationSnapshot(
        rawValue: 0,
        description: "notChecked",
        isAuthorized: false
    )
    private var didFinishLaunching = false
    private var hotKey: GlobalHotKey?
    private var statusItem: NSStatusItem!
    private var statusMenuItem: NSMenuItem!
    private var pairMenuItem: NSMenuItem!
    private var forgetMenuItem: NSMenuItem!
    private var toggleMenuItem: NSMenuItem!
    private var refreshMenuItem: NSMenuItem!

    override init() {
        do {
            logger = try AppLogger()
        } catch {
            fatalError("Could not create Magic Mouse Switch log: \(error)")
        }
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        guard enforceSingleInstance() else {
            NSApp.terminate(nil)
            return
        }
        configureMenuBar()
        let statusButtonAttached = statusItem.button?.window != nil
        let statusButtonHidden = statusItem.button?.isHidden ?? true
        logger.log(
            "menu-bar item configured; window attached \(statusButtonAttached); hidden \(statusButtonHidden); activation policy accessory; LSUIElement \(Bundle.main.object(forInfoDictionaryKey: "LSUIElement") ?? "missing")"
        )
        registerHotKey()
        logger.log("application launched")
        didFinishLaunching = true
        beginInitialPermissionAndStatusCheck()
        scheduleValidationRefreshIfRequested()
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        guard didFinishLaunching else { return }
        requestLiveRefresh(context: "application became active", showPopup: false)
    }

    func applicationWillTerminate(_ notification: Notification) {
        logger.log("application terminated")
    }

    func menuWillOpen(_ menu: NSMenu) {
        requestLiveRefresh(context: "menu opened", showPopup: false)
    }

    @objc private func pair(_ sender: Any?) { start(.pair) }
    @objc private func forget(_ sender: Any?) { start(.forget) }
    @objc private func toggle(_ sender: Any?) { start(.toggle) }

    @objc private func refreshStatus(_ sender: Any?) {
        requestLiveRefresh(context: "Refresh Status", showPopup: true)
    }

    private func requestLiveRefresh(context: String, showPopup: Bool) {
        guard !isOperationActive else { return }
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else { return }
            let snapshot = self.captureLiveState()
            self.logLiveState(context: context, snapshot: snapshot)
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.apply(snapshot: snapshot, context: context)
                if showPopup {
                    let result = self.refreshPopupResult(snapshot)
                    self.logger.log(
                        "refresh popup [\(context)]: \(result.message.replacingOccurrences(of: "\n", with: " | "))"
                    )
                    self.popup.show(result.message, dismissAfter: result.dismissAfter)
                }
            }
        }
    }

    @objc private func openLogs(_ sender: Any?) {
        NSWorkspace.shared.open(logger.directoryURL)
    }

    @objc private func quit(_ sender: Any?) {
        NSApp.terminate(nil)
    }

    private var isOperationActive: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return operationActive
    }

    private func setOperationActive(_ active: Bool) -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        if active && operationActive { return false }
        operationActive = active
        return true
    }

    private func start(_ requested: RequestedOperation) {
        guard setOperationActive(true) else {
            logger.log("ignored duplicate command: \(requested.rawValue)")
            return
        }
        updateMenuEnabledState()
        logger.log("operation start: \(requested.rawValue)")

        let eventHandler = operationEvent
        let operationLogger = logger
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            do {
                let snapshot = self.captureLiveState()
                self.logLiveState(context: "operation request \(requested.rawValue)", snapshot: snapshot)
                guard snapshot.bluetooth.isAuthorized else {
                    throw MagicMouseServiceError(
                        "Bluetooth permission required (\(snapshot.bluetooth.description))"
                    )
                }
                let branch: RequestedOperation
                switch requested {
                case .pair:
                    branch = .pair
                case .forget:
                    branch = .forget
                case .toggle:
                    switch MenuBarOperationPolicy.toggleBranch(for: snapshot.mouseStatus) {
                    case .forget:
                        branch = .forget
                    case .pair:
                        branch = .pair
                    case .unavailable:
                        throw MagicMouseServiceError("status unavailable")
                    }
                }
                operationLogger.log("state branch chosen: \(branch.rawValue)")
                if branch == .forget && !snapshot.accessibility.isTrusted {
                    throw MagicMouseServiceError("Accessibility permission required")
                }
                switch branch {
                case .pair:
                    Task { @MainActor [weak self] in
                        self?.popup.show("Searching for Magic Mouse…")
                    }
                    _ = try MagicMousePairService.run(event: eventHandler)
                    Task { @MainActor [weak self] in
                        self?.finishSuccess("Magic Mouse connected")
                    }
                case .forget:
                    Task { @MainActor [weak self] in
                        self?.popup.show("Forgetting Magic Mouse…")
                    }
                    _ = try MagicMouseForgetService.run(event: eventHandler)
                    Task { @MainActor [weak self] in
                        self?.finishSuccess("Magic Mouse forgotten")
                    }
                case .toggle:
                    throw MagicMouseServiceError("unresolved toggle branch")
                }
            } catch {
                operationLogger.log("operation failed: \(error)")
                let permissionFailure = String(describing: error).contains("Accessibility permission")
                let message = permissionFailure
                    ? "Accessibility permission required"
                    : "Operation failed\n\(error)"
                Task { @MainActor [weak self] in self?.finishFailure(message) }
            }
        }
    }

    private var operationEvent: MagicMouseEventHandler {
        { [weak self] message in
            guard let self else { return }
            self.logger.log(message)
            if message == "pairing started" {
                Task { @MainActor [weak self] in
                    self?.popup.show("Pairing Magic Mouse…")
                }
            }
        }
    }

    private func finishSuccess(_ message: String) {
        logger.log("operation end: success")
        popup.show(message, dismissAfter: 3)
        _ = setOperationActive(false)
        requestLiveRefresh(context: "operation completed", showPopup: false)
    }

    private func finishFailure(_ message: String) {
        logger.log("operation end: failure")
        popup.show(message, dismissAfter: 6)
        _ = setOperationActive(false)
        requestLiveRefresh(context: "operation failed", showPopup: false)
    }

    private func configureMenuBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(
            systemSymbolName: "computermouse",
            accessibilityDescription: "Magic Mouse Switch"
        )
        statusItem.button?.toolTip = "Magic Mouse Switch"

        let menu = NSMenu()
        menu.delegate = self
        let title = NSMenuItem(title: "Magic Mouse Switch", action: nil, keyEquivalent: "")
        title.isEnabled = false
        menu.addItem(title)
        menu.addItem(.separator())
        statusMenuItem = NSMenuItem(title: "Status: Unavailable", action: nil, keyEquivalent: "")
        statusMenuItem.isEnabled = false
        menu.addItem(statusMenuItem)
        pairMenuItem = item("Connect / Pair Magic Mouse", action: #selector(pair(_:)))
        forgetMenuItem = item("Forget Magic Mouse", action: #selector(forget(_:)))
        toggleMenuItem = item("Toggle Magic Mouse", action: #selector(toggle(_:)))
        refreshMenuItem = item("Refresh Status", action: #selector(refreshStatus(_:)))
        menu.addItem(pairMenuItem)
        menu.addItem(forgetMenuItem)
        menu.addItem(toggleMenuItem)
        menu.addItem(refreshMenuItem)
        menu.addItem(item("Open Logs", action: #selector(openLogs(_:))))
        menu.addItem(.separator())
        menu.addItem(item("Quit", action: #selector(quit(_:))))
        statusItem.menu = menu
        updateMenuEnabledState()
    }

    private func item(_ title: String, action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        return item
    }

    private func updateMenuEnabledState() {
        let active = isOperationActive
        let availability = MenuBarOperationPolicy.availability(
            status: currentStatus,
            accessibilityTrusted: accessibilityTrusted,
            bluetoothAuthorized: bluetoothAuthorization.isAuthorized,
            operationActive: active
        )
        statusMenuItem.title = active
            ? "Status: Operation in progress…"
            : "Status: \(currentStatus.displayName)"
        pairMenuItem.isEnabled = availability.pairEnabled
        forgetMenuItem.isEnabled = availability.forgetEnabled
        toggleMenuItem.isEnabled = availability.toggleEnabled
        refreshMenuItem.isEnabled = availability.refreshEnabled
    }

    private func apply(snapshot: LiveStateSnapshot, context: String) {
        currentStatus = snapshot.mouseStatus
        accessibilityTrusted = snapshot.accessibility.isTrusted
        bluetoothAuthorization = snapshot.bluetooth
        updateMenuEnabledState()
        let availability = MenuBarOperationPolicy.availability(
            status: currentStatus,
            accessibilityTrusted: accessibilityTrusted,
            bluetoothAuthorized: bluetoothAuthorization.isAuthorized,
            operationActive: isOperationActive
        )
        logger.log(
            "menu enablement [\(context)]: branch=\(availability.decision); "
                + "pair=\(availability.pairEnabled); forget=\(availability.forgetEnabled); "
                + "toggle=\(availability.toggleEnabled); refresh=\(availability.refreshEnabled)"
        )
    }

    private func registerHotKey() {
        hotKey = GlobalHotKey { [weak self] in
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                if self.isOperationActive {
                    self.logger.log("ignored repeated hotkey while operation active")
                    return
                }
                self.start(.toggle)
            }
        }
        let status = hotKey?.register() ?? OSStatus(paramErr)
        logger.log("global shortcut Control-Shift-M registration result: \(status)")
    }

    private func beginInitialPermissionAndStatusCheck() {
        let defaults = UserDefaults.standard
        let validationOnly = ProcessInfo.processInfo.environment[
            "MAGIC_MOUSE_SWITCH_VALIDATION"
        ] == "1"
        let firstLaunch = !validationOnly
            && !defaults.bool(forKey: "AccessibilityPromptShown")
        if !validationOnly {
            defaults.set(true, forKey: "AccessibilityPromptShown")
        }
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else { return }
            var snapshot = self.captureLiveState()
            self.logStartupDiagnostics(snapshot)
            if firstLaunch && !snapshot.accessibility.isTrusted {
                _ = MagicMouseAccessibilityService.isTrusted(prompt: true)
                snapshot = self.captureLiveState()
                self.logLiveState(context: "startup after permission prompt", snapshot: snapshot)
            }
            let finalSnapshot = snapshot
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.apply(snapshot: finalSnapshot, context: "startup")
                if firstLaunch && !finalSnapshot.accessibility.isTrusted {
                    self.showAccessibilityOnboarding()
                }
            }
        }
    }

    nonisolated private func captureLiveState() -> LiveStateSnapshot {
        let accessibility = MagicMouseAccessibilityService.currentTrust()
        let mouseStatus = MagicMouseStatusService.currentStatus()
        let bluetooth = MagicMouseBluetoothAuthorizationService.current()
        return LiveStateSnapshot(
            accessibility: accessibility,
            bluetooth: bluetooth,
            mouseStatus: mouseStatus
        )
    }

    nonisolated private func logStartupDiagnostics(_ snapshot: LiveStateSnapshot) {
        logger.log("startup diagnostic: PID=\(ProcessInfo.processInfo.processIdentifier)")
        logger.log(
            "startup diagnostic: executable=\(Bundle.main.executableURL?.path ?? ProcessInfo.processInfo.arguments[0])"
        )
        logger.log("startup diagnostic: bundle identifier=\(Bundle.main.bundleIdentifier ?? "missing")")
        logLiveState(context: "startup", snapshot: snapshot)
    }

    nonisolated private func logLiveState(context: String, snapshot: LiveStateSnapshot) {
        logger.log(
            "permission state [\(context)]: AXIsProcessTrusted=\(snapshot.accessibility.rawTrusted); "
                + "AXIsProcessTrustedWithOptions(prompt:false)=\(snapshot.accessibility.rawTrustedWithOptions)"
        )
        logger.log(
            "permission state [\(context)]: Bluetooth authorization raw=\(snapshot.bluetooth.rawValue); "
                + "state=\(snapshot.bluetooth.description); authorized=\(snapshot.bluetooth.isAuthorized)"
        )
        logger.log("mouse state [\(context)]: \(mouseStateDescription(snapshot.mouseStatus))")
    }

    nonisolated private func mouseStateDescription(_ status: MagicMouseStatus) -> String {
        switch status {
        case let .connected(device):
            return "paired=true; connected=true; address=\(device.address); name=\(device.name)"
        case let .pairedButDisconnected(device):
            return "paired=true; connected=false; address=\(device.address); name=\(device.name)"
        case .unpaired:
            return "paired=false; connected=false"
        case let .unavailable(reason):
            return "unavailable; reason=\(reason)"
        }
    }

    private func refreshPopupResult(
        _ snapshot: LiveStateSnapshot
    ) -> (message: String, dismissAfter: TimeInterval) {
        guard snapshot.bluetooth.isAuthorized else {
            return (
                "Bluetooth permission required\n\(snapshot.bluetooth.description)",
                6
            )
        }
        if snapshot.mouseStatus.isPaired && !snapshot.accessibility.isTrusted {
            return ("Accessibility permission required", 6)
        }
        switch snapshot.mouseStatus {
        case .connected:
            return ("Status: Connected", 3)
        case .pairedButDisconnected:
            return ("Status: Paired but disconnected", 3)
        case .unpaired:
            return ("Status: Unpaired", 3)
        case let .unavailable(reason):
            return ("Status unavailable\n\(reason)", 6)
        }
    }

    private func showAccessibilityOnboarding() {
        popup.show("Accessibility permission required", dismissAfter: 6)
        let alert = NSAlert()
        alert.messageText = "Accessibility Permission Required"
        alert.informativeText = "Magic Mouse Switch needs Accessibility permission only to verify and press the exact controls in System Settings when forgetting the pinned Magic Mouse. Pairing does not require this permission."
        alert.addButton(withTitle: "Open Accessibility Settings")
        alert.addButton(withTitle: "Later")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            _ = MagicMouseAccessibilityService.openAccessibilitySettings()
        }
    }

    private func scheduleValidationRefreshIfRequested() {
        guard ProcessInfo.processInfo.environment[
            "MAGIC_MOUSE_SWITCH_VALIDATE_REFRESH"
        ] == "1" else {
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            guard let self else { return }
            self.logger.log("validation: invoking Refresh Status menu action")
            _ = NSApp.sendAction(
                self.refreshMenuItem.action!,
                to: self.refreshMenuItem.target,
                from: self.refreshMenuItem
            )
        }
    }

    private func enforceSingleInstance() -> Bool {
        guard let identifier = Bundle.main.bundleIdentifier else { return true }
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: identifier)
            .filter { $0.processIdentifier != ownPID && !$0.isTerminated }
        if let existing = others.first {
            _ = existing.activate(options: [.activateIgnoringOtherApps])
            logger.log("second instance refused; activated PID \(existing.processIdentifier)")
            return false
        }
        return true
    }
}

let application = NSApplication.shared
let delegate = AppDelegate()
application.delegate = delegate
application.run()
