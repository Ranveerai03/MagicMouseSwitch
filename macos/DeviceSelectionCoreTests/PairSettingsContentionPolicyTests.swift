import XCTest
@testable import DeviceSelectionCore
@testable import MagicMouseSwitchServices

final class PairSettingsContentionPolicyTests: XCTestCase {
    func testBluetoothWindowOpenedByAppClosesBeforeInquiry() {
        XCTAssertEqual(
            PairSettingsContentionPolicy.mitigation(
                bluetoothContentActive: true,
                state: state(
                    settingsWasRunning: false,
                    bluetoothWasOpen: false,
                    openedByApp: true
                )
            ),
            .closeAppCreatedBluetoothWindow
        )
    }

    func testPreexistingBluetoothWindowNavigatesAway() {
        XCTAssertEqual(
            PairSettingsContentionPolicy.mitigation(
                bluetoothContentActive: true,
                state: state(
                    settingsWasRunning: true,
                    bluetoothWasOpen: true,
                    openedByApp: false
                )
            ),
            .navigateToGeneral
        )
    }

    func testAppOpenedBluetoothInReusedMainWindowNavigatesInsteadOfClosing() {
        XCTAssertEqual(
            PairSettingsContentionPolicy.mitigation(
                bluetoothContentActive: true,
                state: state(
                    settingsWasRunning: true,
                    bluetoothWasOpen: false,
                    openedByApp: true,
                    unrelatedWindows: false,
                    previousPane: "General"
                )
            ),
            .navigateToGeneral
        )
    }

    func testAppOpenedSeparateBluetoothWindowClosesAndPreservesUnrelatedWindow() {
        XCTAssertEqual(
            PairSettingsContentionPolicy.mitigation(
                bluetoothContentActive: true,
                state: state(
                    settingsWasRunning: true,
                    bluetoothWasOpen: false,
                    openedByApp: true,
                    unrelatedWindows: true,
                    previousPane: "General"
                )
            ),
            .closeAppCreatedBluetoothWindow
        )
    }

    func testUnrelatedSettingsWindowIsPreserved() {
        XCTAssertEqual(
            PairSettingsContentionPolicy.restorationDecision(
                for: state(
                    settingsWasRunning: true,
                    bluetoothWasOpen: false,
                    openedByApp: true,
                    unrelatedWindows: true,
                    navigatedToGeneral: true
                )
            ),
            .preserveUnrelatedWindows
        )
    }

    func testZeroCallbacksErrorOneAndRecentBluetoothRetriesOnce() {
        XCTAssertTrue(
            PairSettingsContentionPolicy.shouldRetry(
                retryObservation(attempt: 1)
            )
        )
        XCTAssertFalse(
            PairSettingsContentionPolicy.shouldRetry(
                retryObservation(attempt: 2)
            )
        )
    }

    func testPinnedDeviceOnFirstAttemptDoesNotRetry() {
        XCTAssertFalse(
            PairSettingsContentionPolicy.shouldRetry(
                retryObservation(attempt: 1, callbacks: 1, pinnedFound: true)
            )
        )
    }

    func testPinnedDeviceOnSecondAttemptCanCompleteInquiry() {
        var first = InquiryLifecycleState()
        XCTAssertTrue(first.recordCompletion(error: 1, aborted: false))
        XCTAssertEqual(first.terminalDecision, .failed(error: 1, aborted: false))

        var second = InquiryLifecycleState()
        XCTAssertTrue(second.recordDeviceFound(matchesPinned: true))
        XCTAssertTrue(second.recordCompletion(error: 0, aborted: true))
        XCTAssertEqual(second.terminalDecision, .succeededAfterPinnedMatch)
    }

    func testErrorAfterPinnedMatchAndStopStillContinues() {
        var inquiry = InquiryLifecycleState()
        XCTAssertTrue(inquiry.recordDeviceFound(matchesPinned: true))
        XCTAssertTrue(inquiry.recordCompletion(error: 1, aborted: true))
        XCTAssertEqual(inquiry.terminalDecision, .succeededAfterPinnedMatch)
    }

    func testRestorationNeverReopensBluetoothScanning() {
        let decision = PairSettingsContentionPolicy.restorationDecision(
            for: state(
                settingsWasRunning: true,
                bluetoothWasOpen: true,
                openedByApp: false,
                previousPane: "Bluetooth",
                navigatedToGeneral: true
            )
        )
        XCTAssertEqual(decision, .leaveOnGeneral)
    }

    func testRestorationDoesNothingWhenPreflightDidNotChangeSettings() {
        XCTAssertEqual(
            PairSettingsContentionPolicy.restorationDecision(
                for: state(
                    settingsWasRunning: true,
                    bluetoothWasOpen: false,
                    openedByApp: false,
                    previousPane: "Appearance"
                )
            ),
            .none
        )
    }

    func testOperationCompletionIsAcceptedExactlyOnce() {
        var gate = PairOperationCompletionGate()
        XCTAssertTrue(gate.recordCompletion())
        XCTAssertFalse(gate.recordCompletion())
        XCTAssertEqual(gate.completionCount, 2)
    }

    func testBluetoothHierarchyDetectsNearbyDevicesOrSpinner() {
        XCTAssertTrue(
            PairSettingsContentionPolicy.bluetoothContentActive(
                windowTitle: "System Settings",
                hierarchyLabels: ["Bluetooth", "Nearby Devices"],
                hierarchyRoles: []
            )
        )
        XCTAssertTrue(
            PairSettingsContentionPolicy.bluetoothContentActive(
                windowTitle: "System Settings",
                hierarchyLabels: ["Bluetooth"],
                hierarchyRoles: ["AXProgressIndicator"]
            )
        )
        XCTAssertFalse(
            PairSettingsContentionPolicy.bluetoothContentActive(
                windowTitle: "General",
                hierarchyLabels: ["General"],
                hierarchyRoles: []
            )
        )
    }

    private func state(
        settingsWasRunning: Bool,
        bluetoothWasOpen: Bool,
        openedByApp: Bool,
        unrelatedWindows: Bool = false,
        previousPane: String? = nil,
        navigatedToGeneral: Bool = false
    ) -> PairSettingsOperationState {
        PairSettingsOperationState(
            settingsWasRunningBeforeOperation: settingsWasRunning,
            bluetoothWindowWasOpenBeforeOperation: bluetoothWasOpen,
            bluetoothWindowOpenedByApp: openedByApp,
            unrelatedSettingsWindowsPresent: unrelatedWindows,
            previousSettingsPane: previousPane,
            bluetoothSettingsOpenRecently: bluetoothWasOpen || openedByApp,
            navigatedToNeutralPane: navigatedToGeneral
        )
    }

    private func retryObservation(
        attempt: Int,
        callbacks: Int = 0,
        pinnedFound: Bool = false
    ) -> PairInquiryRetryObservation {
        PairInquiryRetryObservation(
            attemptNumber: attempt,
            startReturnCode: 0,
            deviceFoundCallbackCount: callbacks,
            completionError: 1,
            pinnedAddressFound: pinnedFound,
            bluetoothSettingsOpenRecently: true
        )
    }
}
