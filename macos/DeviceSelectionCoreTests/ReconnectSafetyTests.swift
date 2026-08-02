import XCTest
@testable import DeviceSelectionCore

final class ReconnectSafetyTests: XCTestCase {
    func testConfirmationAcceptsOnlyExactCaseSensitivePhrase() {
        XCTAssertTrue(
            ReconnectSafety.confirmationIsExact("RECONNECT MAGIC MOUSE")
        )
    }

    func testConfirmationDoesNotTrimOrNormalizeInput() {
        XCTAssertFalse(
            ReconnectSafety.confirmationIsExact("reconnect magic mouse")
        )
        XCTAssertFalse(
            ReconnectSafety.confirmationIsExact(" RECONNECT MAGIC MOUSE")
        )
        XCTAssertFalse(
            ReconnectSafety.confirmationIsExact("RECONNECT MAGIC MOUSE ")
        )
        XCTAssertFalse(
            ReconnectSafety.confirmationIsExact("RECONNECT  MAGIC MOUSE")
        )
    }

    func testEligibleSelectionRequiresEverySafetyCondition() throws {
        let expected = device()
        let selected = try ReconnectSafety.selectEligibleDevice(
            from: [
                device(name: "Magic Keyboard"),
                device(address: "aa-bb-cc-dd-ee-ff"),
                device(isPaired: false),
                device(classOfDevice: 0x002540),
                expected
            ],
            configuredAddress: "D0:C0:50:D5:10:77"
        )

        XCTAssertEqual(selected, expected)
    }

    func testSelectionRejectsInvalidConfiguredAddress() {
        XCTAssertThrowsError(
            try ReconnectSafety.selectEligibleDevice(
                from: [device()],
                configuredAddress: "invalid"
            )
        ) { error in
            XCTAssertEqual(
                error as? ReconnectSafetyError,
                .invalidConfiguredAddress("invalid")
            )
        }
    }

    func testSelectionRejectsEachMissingSafetyCondition() {
        let ineligibleDevices = [
            device(name: "Magic Keyboard"),
            device(address: "aa-bb-cc-dd-ee-ff"),
            device(isPaired: false),
            device(classOfDevice: 0x002540)
        ]

        for ineligibleDevice in ineligibleDevices {
            XCTAssertThrowsError(
                try ReconnectSafety.selectEligibleDevice(
                    from: [ineligibleDevice],
                    configuredAddress: "d0-c0-50-d5-10-77"
                )
            ) { error in
                XCTAssertEqual(
                    error as? ReconnectSafetyError,
                    .noEligibleDevice(configuredAddress: "d0-c0-50-d5-10-77")
                )
            }
        }
    }

    func testSelectionRejectsMultipleFullyEligibleRecords() {
        XCTAssertThrowsError(
            try ReconnectSafety.selectEligibleDevice(
                from: [device(), device(name: "Backup Magic Mouse")],
                configuredAddress: "d0c050d51077"
            )
        ) { error in
            XCTAssertEqual(
                error as? ReconnectSafetyError,
                .multipleEligibleDevices(
                    configuredAddress: "d0c050d51077",
                    matchCount: 2
                )
            )
        }
    }

    private func device(
        name: String = "Ranveer's Magic Mouse",
        address: String = "d0-c0-50-d5-10-77",
        isPaired: Bool = true,
        isConnected: Bool = false,
        classOfDevice: UInt32 = 0x002580
    ) -> PairedBluetoothDevice {
        PairedBluetoothDevice(
            name: name,
            address: address,
            isPaired: isPaired,
            isConnected: isConnected,
            classOfDevice: classOfDevice
        )
    }
}
