import XCTest
@testable import DeviceSelectionCore

final class DeviceSelectionCoreTests: XCTestCase {
    func testAddressNormalizationRemovesSupportedSeparatorsAndIgnoresCase() {
        XCTAssertEqual(
            BluetoothAddressNormalizer.normalize("D0-C0-50-D5-10-77"),
            "d0c050d51077"
        )
        XCTAssertEqual(
            BluetoothAddressNormalizer.normalize("d0:c0:50:d5:10:77"),
            "d0c050d51077"
        )
        XCTAssertEqual(
            BluetoothAddressNormalizer.normalize("d0c050d51077"),
            "d0c050d51077"
        )
    }

    func testAddressNormalizationRejectsMalformedAddresses() {
        XCTAssertNil(BluetoothAddressNormalizer.normalize("d0-c0-50-d5-10"))
        XCTAssertNil(BluetoothAddressNormalizer.normalize("d0-c0-50-d5-10-zz"))
        XCTAssertNil(BluetoothAddressNormalizer.normalize("d0.c0.50.d5.10.77"))
    }

    func testMagicMouseNameMatchIsCaseInsensitive() {
        XCTAssertTrue(DeviceSelector.nameContainsMagicMouse("Ranveer's MAGIC MOUSE"))
        XCTAssertTrue(DeviceSelector.nameContainsMagicMouse("magic mouse"))
        XCTAssertFalse(DeviceSelector.nameContainsMagicMouse("Magic Keyboard"))
    }

    func testSelectsOnlyThePinnedAddressAmongMagicMouseCandidates() throws {
        let expected = device(name: "Ranveer's Magic Mouse", address: "d0-c0-50-d5-10-77")
        let devices = [
            device(name: "Other Magic Mouse", address: "aa-bb-cc-dd-ee-ff"),
            expected,
            device(name: "Magic Keyboard", address: "11-22-33-44-55-66")
        ]

        let selected = try DeviceSelector.select(
            from: devices,
            configuredAddress: "D0:C0:50:D5:10:77"
        )

        XCTAssertEqual(selected, expected)
    }

    func testFailsWhenNoMagicMouseExists() {
        XCTAssertThrowsError(
            try DeviceSelector.select(
                from: [device(name: "Magic Keyboard", address: "d0-c0-50-d5-10-77")],
                configuredAddress: "d0-c0-50-d5-10-77"
            )
        ) { error in
            XCTAssertEqual(error as? DeviceSelectionError, .noMagicMouseDevices)
        }
    }

    func testFailsWhenPinnedAddressDoesNotMatch() {
        XCTAssertThrowsError(
            try DeviceSelector.select(
                from: [device(name: "Magic Mouse", address: "aa-bb-cc-dd-ee-ff")],
                configuredAddress: "d0-c0-50-d5-10-77"
            )
        ) { error in
            XCTAssertEqual(
                error as? DeviceSelectionError,
                .configuredAddressNotFound(
                    configuredAddress: "d0-c0-50-d5-10-77",
                    candidateCount: 1
                )
            )
        }
    }

    func testFailsWhenMoreThanOneRecordMatchesPinnedAddress() {
        let duplicateRecords = [
            device(name: "Magic Mouse", address: "d0-c0-50-d5-10-77"),
            device(name: "Backup Magic Mouse", address: "D0:C0:50:D5:10:77")
        ]

        XCTAssertThrowsError(
            try DeviceSelector.select(
                from: duplicateRecords,
                configuredAddress: "d0c050d51077"
            )
        ) { error in
            XCTAssertEqual(
                error as? DeviceSelectionError,
                .multipleMatches(
                    configuredAddress: "d0c050d51077",
                    matchCount: 2
                )
            )
        }
    }

    func testFailsWhenConfiguredAddressIsInvalid() {
        XCTAssertThrowsError(
            try DeviceSelector.select(from: [], configuredAddress: "not-an-address")
        ) { error in
            XCTAssertEqual(
                error as? DeviceSelectionError,
                .invalidConfiguredAddress("not-an-address")
            )
        }
    }

    private func device(name: String, address: String) -> PairedBluetoothDevice {
        PairedBluetoothDevice(
            name: name,
            address: address,
            isPaired: true,
            isConnected: false,
            classOfDevice: 0x002580
        )
    }
}
