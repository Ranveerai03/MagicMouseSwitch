import XCTest
@testable import DeviceSelectionCore

final class SystemSettingsWindowAcquisitionTests: XCTestCase {
    func testBluetoothWindowMatchesExactTitleIgnoringCase() {
        XCTAssertTrue(
            SystemSettingsWindowAcquisitionPolicy.bluetoothWindowMatches(
                title: "bluetooth",
                hierarchyLabels: [],
                selectedDeviceName: "Ranveer's Magic Mouse"
            )
        )
    }

    func testBluetoothWindowMatchesKnownHierarchyWithoutTitle() {
        XCTAssertTrue(
            SystemSettingsWindowAcquisitionPolicy.bluetoothWindowMatches(
                title: "System Settings",
                hierarchyLabels: ["Bluetooth", "Ranveer's Magic Mouse"],
                selectedDeviceName: "Ranveer's Magic Mouse"
            )
        )
        XCTAssertTrue(
            SystemSettingsWindowAcquisitionPolicy.bluetoothWindowMatches(
                title: nil,
                hierarchyLabels: ["Ranveer's Magic Mouse", "Show Detail"],
                selectedDeviceName: "Ranveer's Magic Mouse"
            )
        )
    }

    func testBluetoothWindowDoesNotMatchNameOrBluetoothLabelAlone() {
        XCTAssertFalse(
            SystemSettingsWindowAcquisitionPolicy.bluetoothWindowMatches(
                title: "System Settings",
                hierarchyLabels: ["Bluetooth"],
                selectedDeviceName: "Ranveer's Magic Mouse"
            )
        )
        XCTAssertFalse(
            SystemSettingsWindowAcquisitionPolicy.bluetoothWindowMatches(
                title: "System Settings",
                hierarchyLabels: ["Ranveer's Magic Mouse"],
                selectedDeviceName: "Ranveer's Magic Mouse"
            )
        )
    }

    func testAcquiredWindowWinsEvenAtDeadline() {
        XCTAssertEqual(
            decision(observation(bluetoothWindowFound: true), deadlineReached: true),
            .acquired
        )
    }

    func testMissingProcessAndAXApplicationRetryWithoutNavigation() {
        XCTAssertEqual(
            decision(observation(processCount: 0, axApplicationCount: 0)),
            .retry(reason: .processNotFound)
        )
        XCTAssertEqual(
            decision(observation(processCount: 1, axApplicationCount: 0)),
            .retry(reason: .axApplicationUnavailable)
        )
    }

    func testUnreadableOrEmptyWindowsTriggerOnlyOneAdditionalNavigation() {
        let unreadable = observation(readableProcessCount: 0, windowCount: 0)
        XCTAssertEqual(
            decision(unreadable),
            .foregroundAndNavigate(reason: .windowsUnreadable)
        )
        XCTAssertEqual(
            decision(unreadable, additionalNavigationPerformed: true),
            .retry(reason: .windowsUnreadable)
        )

        let empty = observation(windowCount: 0)
        XCTAssertEqual(
            decision(empty),
            .foregroundAndNavigate(reason: .noWindows)
        )
        XCTAssertEqual(
            decision(empty, additionalNavigationPerformed: true),
            .retry(reason: .noWindows)
        )
    }

    func testWrongWindowTriggersOneNavigationThenRetry() {
        XCTAssertEqual(
            decision(observation()),
            .foregroundAndNavigate(reason: .bluetoothWindowNotFound)
        )
        XCTAssertEqual(
            decision(observation(), additionalNavigationPerformed: true),
            .retry(reason: .bluetoothWindowNotFound)
        )
    }

    func testDeadlineExhaustsWithMostSpecificReason() {
        XCTAssertEqual(
            decision(observation(), deadlineReached: true),
            .exhausted(reason: .bluetoothWindowNotFound)
        )
        XCTAssertEqual(
            decision(
                observation(readableProcessCount: 0, windowCount: 0),
                deadlineReached: true
            ),
            .exhausted(reason: .windowsUnreadable)
        )
    }

    private func decision(
        _ observation: SystemSettingsWindowObservation,
        additionalNavigationPerformed: Bool = false,
        deadlineReached: Bool = false
    ) -> SystemSettingsWindowDecision {
        SystemSettingsWindowAcquisitionPolicy.decision(
            for: observation,
            additionalNavigationPerformed: additionalNavigationPerformed,
            deadlineReached: deadlineReached
        )
    }

    private func observation(
        processCount: Int = 1,
        axApplicationCount: Int = 1,
        readableProcessCount: Int = 1,
        windowCount: Int = 1,
        bluetoothWindowFound: Bool = false
    ) -> SystemSettingsWindowObservation {
        SystemSettingsWindowObservation(
            processCount: processCount,
            axApplicationCount: axApplicationCount,
            readableProcessCount: readableProcessCount,
            windowCount: windowCount,
            bluetoothWindowFound: bluetoothWindowFound
        )
    }
}
