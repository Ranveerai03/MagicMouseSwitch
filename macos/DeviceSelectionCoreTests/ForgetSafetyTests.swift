import XCTest
@testable import DeviceSelectionCore

final class ForgetSafetyTests: XCTestCase {
    func testConfirmationAcceptsOnlyExactCaseSensitivePhrase() {
        XCTAssertTrue(ForgetSafety.confirmationIsExact("FORGET MAGIC MOUSE"))
    }

    func testConfirmationDoesNotTrimOrNormalizeInput() {
        XCTAssertFalse(ForgetSafety.confirmationIsExact("forget magic mouse"))
        XCTAssertFalse(ForgetSafety.confirmationIsExact(" FORGET MAGIC MOUSE"))
        XCTAssertFalse(ForgetSafety.confirmationIsExact("FORGET MAGIC MOUSE "))
        XCTAssertFalse(ForgetSafety.confirmationIsExact("FORGET  MAGIC MOUSE"))
    }

    func testEligibleSelectionRequiresEverySafetyCondition() throws {
        let expected = device()
        let selected = try ForgetSafety.selectEligibleDevice(
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
            try ForgetSafety.selectEligibleDevice(
                from: [device()],
                configuredAddress: "invalid"
            )
        ) { error in
            XCTAssertEqual(
                error as? ForgetSafetyError,
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
                try ForgetSafety.selectEligibleDevice(
                    from: [ineligibleDevice],
                    configuredAddress: "d0-c0-50-d5-10-77"
                )
            ) { error in
                XCTAssertEqual(
                    error as? ForgetSafetyError,
                    .noEligibleDevice(configuredAddress: "d0-c0-50-d5-10-77")
                )
            }
        }
    }

    func testSelectionRejectsMultipleFullyEligibleRecords() {
        XCTAssertThrowsError(
            try ForgetSafety.selectEligibleDevice(
                from: [device(), device(name: "Backup Magic Mouse")],
                configuredAddress: "d0c050d51077"
            )
        ) { error in
            XCTAssertEqual(
                error as? ForgetSafetyError,
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
        isConnected: Bool = true,
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
