import DeviceSelectionCore
import MagicMouseSwitchServices
import XCTest

final class MenuBarOperationPolicyTests: XCTestCase {
    func testAccessibilitySnapshotTrustsEitherPublicAPIResult() {
        XCTAssertFalse(
            AccessibilityTrustSnapshot(
                rawTrusted: false,
                rawTrustedWithOptions: false
            ).isTrusted
        )
        XCTAssertTrue(
            AccessibilityTrustSnapshot(
                rawTrusted: true,
                rawTrustedWithOptions: false
            ).isTrusted
        )
        XCTAssertTrue(
            AccessibilityTrustSnapshot(
                rawTrusted: false,
                rawTrustedWithOptions: true
            ).isTrusted
        )
    }

    func testToggleBranchUsesPairedStateOnly() {
        XCTAssertEqual(MenuBarOperationPolicy.toggleBranch(for: .unpaired), .pair)
        XCTAssertEqual(
            MenuBarOperationPolicy.toggleBranch(for: .connected(device: device(connected: true))),
            .forget
        )
        XCTAssertEqual(
            MenuBarOperationPolicy.toggleBranch(
                for: .pairedButDisconnected(device: device(connected: false))
            ),
            .forget
        )
        XCTAssertEqual(
            MenuBarOperationPolicy.toggleBranch(for: .unavailable(reason: "test")),
            .unavailable
        )
    }

    func testAccessibilityDisablesForgetAndToggleButNotPair() {
        let paired = MenuBarOperationPolicy.availability(
            status: .connected(device: device(connected: true)),
            accessibilityTrusted: false,
            operationActive: false
        )
        XCTAssertFalse(paired.pairEnabled)
        XCTAssertFalse(paired.forgetEnabled)
        XCTAssertFalse(paired.toggleEnabled)
        XCTAssertTrue(paired.refreshEnabled)

        let unpaired = MenuBarOperationPolicy.availability(
            status: .unpaired,
            accessibilityTrusted: false,
            operationActive: false
        )
        XCTAssertTrue(unpaired.pairEnabled)
        XCTAssertFalse(unpaired.forgetEnabled)
        XCTAssertTrue(unpaired.toggleEnabled)
        XCTAssertEqual(unpaired.decision, "unpaired-accessibility-not-required")

        let unavailable = MenuBarOperationPolicy.availability(
            status: .unavailable(reason: "test"),
            accessibilityTrusted: true,
            operationActive: false
        )
        XCTAssertFalse(unavailable.pairEnabled)
        XCTAssertFalse(unavailable.forgetEnabled)
    }

    func testTrustedPairedAndUnpairedMenuRules() {
        let paired = MenuBarOperationPolicy.availability(
            status: .pairedButDisconnected(device: device(connected: false)),
            accessibilityTrusted: true,
            operationActive: false
        )
        XCTAssertFalse(paired.pairEnabled)
        XCTAssertTrue(paired.forgetEnabled)
        XCTAssertTrue(paired.toggleEnabled)
        XCTAssertTrue(paired.refreshEnabled)
        XCTAssertEqual(paired.decision, "paired-accessibility-trusted")

        let unpaired = MenuBarOperationPolicy.availability(
            status: .unpaired,
            accessibilityTrusted: true,
            operationActive: false
        )
        XCTAssertTrue(unpaired.pairEnabled)
        XCTAssertFalse(unpaired.forgetEnabled)
        XCTAssertTrue(unpaired.toggleEnabled)
        XCTAssertTrue(unpaired.refreshEnabled)
        XCTAssertEqual(unpaired.decision, "unpaired-accessibility-trusted")
    }

    func testBluetoothBlockDisablesOperationsButKeepsRefreshEnabled() {
        let availability = MenuBarOperationPolicy.availability(
            status: .connected(device: device(connected: true)),
            accessibilityTrusted: true,
            bluetoothAuthorized: false,
            operationActive: false
        )
        XCTAssertFalse(availability.pairEnabled)
        XCTAssertFalse(availability.forgetEnabled)
        XCTAssertFalse(availability.toggleEnabled)
        XCTAssertTrue(availability.refreshEnabled)
        XCTAssertEqual(availability.decision, "bluetooth-not-authorized")
    }

    func testActiveOperationDisablesAllCommands() {
        let availability = MenuBarOperationPolicy.availability(
            status: .unpaired,
            accessibilityTrusted: true,
            operationActive: true
        )
        XCTAssertFalse(availability.pairEnabled)
        XCTAssertFalse(availability.forgetEnabled)
        XCTAssertFalse(availability.toggleEnabled)
        XCTAssertFalse(availability.refreshEnabled)
    }

    private func device(connected: Bool) -> PairedBluetoothDevice {
        PairedBluetoothDevice(
            name: "Ranveer's Magic Mouse",
            address: magicMousePinnedAddress,
            isPaired: true,
            isConnected: connected,
            classOfDevice: 0x002580
        )
    }
}
