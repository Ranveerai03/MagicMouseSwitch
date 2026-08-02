import XCTest
@testable import DeviceSelectionCore

final class PairSafetyTests: XCTestCase {
    func testConfirmationAcceptsOnlyExactCaseSensitivePhrase() {
        XCTAssertTrue(PairSafety.confirmationIsExact("PAIR MAGIC MOUSE"))
        XCTAssertFalse(PairSafety.confirmationIsExact("pair magic mouse"))
        XCTAssertFalse(PairSafety.confirmationIsExact(" PAIR MAGIC MOUSE"))
        XCTAssertFalse(PairSafety.confirmationIsExact("PAIR MAGIC MOUSE "))
    }

    func testConfiguredAddressNormalizationAndUnpairedPrecondition() throws {
        XCTAssertEqual(
            try PairSafety.normalizedConfiguredAddress("D0:C0:50:D5:10:77"),
            "d0c050d51077"
        )
        XCTAssertNoThrow(
            try PairSafety.requireAddressIsUnpaired(
                in: [device(address: "aa-bb-cc-dd-ee-ff", isPaired: true)],
                configuredAddress: "d0-c0-50-d5-10-77"
            )
        )
    }

    func testInvalidConfiguredAddressIsRejected() {
        XCTAssertThrowsError(try PairSafety.normalizedConfiguredAddress("invalid")) {
            XCTAssertEqual($0 as? PairSafetyError, .invalidConfiguredAddress("invalid"))
        }
    }

    func testAlreadyPairedAddressIsRejectedRegardlessOfOtherProperties() {
        XCTAssertThrowsError(
            try PairSafety.requireAddressIsUnpaired(
                in: [device(name: "Unrelated", isPaired: true, classOfDevice: 0)],
                configuredAddress: "D0:C0:50:D5:10:77"
            )
        ) {
            XCTAssertEqual(
                $0 as? PairSafetyError,
                .configuredAddressAlreadyPaired(
                    address: "D0:C0:50:D5:10:77",
                    matchCount: 1
                )
            )
        }
    }

    func testDiscoveredSelectionRequiresOnePinnedUnpairedMagicMouseOfExactClass() throws {
        let expected = device()
        let selected = try PairSafety.selectDiscoveredDevice(
            from: [device(address: "aa-bb-cc-dd-ee-ff"), expected],
            configuredAddress: "D0:C0:50:D5:10:77"
        )
        XCTAssertEqual(selected, expected)
    }

    func testDiscoveredSelectionRejectsMissingAndDuplicatePinnedRecords() {
        XCTAssertThrowsError(
            try PairSafety.selectDiscoveredDevice(
                from: [device(address: "aa-bb-cc-dd-ee-ff")],
                configuredAddress: "d0-c0-50-d5-10-77"
            )
        ) {
            XCTAssertEqual(
                $0 as? PairSafetyError,
                .pinnedDeviceNotDiscovered(address: "d0-c0-50-d5-10-77")
            )
        }

        XCTAssertThrowsError(
            try PairSafety.selectDiscoveredDevice(
                from: [device(), device()],
                configuredAddress: "d0-c0-50-d5-10-77"
            )
        ) {
            XCTAssertEqual(
                $0 as? PairSafetyError,
                .multiplePinnedDevices(
                    address: "d0-c0-50-d5-10-77",
                    matchCount: 2
                )
            )
        }
    }

    func testCandidateValidationRejectsEveryIdentityOrStateMismatch() {
        let cases: [(PairedBluetoothDevice, PairSafetyError)] = [
            (device(address: "aa-bb-cc-dd-ee-ff"), .pinnedDeviceNotDiscovered(address: "d0-c0-50-d5-10-77")),
            (device(name: "Magic Keyboard"), .pinnedDeviceNameMismatch(name: "Magic Keyboard")),
            (device(classOfDevice: 0x002540), .pinnedDeviceClassMismatch(actual: 0x002540)),
            (device(isPaired: true), .pinnedDeviceIsAlreadyPaired)
        ]

        for (candidate, expectedError) in cases {
            XCTAssertThrowsError(
                try PairSafety.validateUnpairedCandidate(
                    candidate,
                    configuredAddress: "d0-c0-50-d5-10-77"
                )
            ) {
                XCTAssertEqual($0 as? PairSafetyError, expectedError)
            }
        }
    }

    func testPostPairVerificationRequiresExactlyOneFullyEligibleRecord() throws {
        let expected = device(isPaired: true, isConnected: true)
        XCTAssertEqual(
            try PairSafety.selectVerifiedPairedDevice(
                from: [device(address: "aa-bb-cc-dd-ee-ff", isPaired: true), expected],
                configuredAddress: "d0c050d51077"
            ),
            expected
        )

        XCTAssertThrowsError(
            try PairSafety.selectVerifiedPairedDevice(
                from: [expected, device(name: "Other", isPaired: true, classOfDevice: 0)],
                configuredAddress: "d0c050d51077"
            )
        ) {
            XCTAssertEqual(
                $0 as? PairSafetyError,
                .pairedVerificationFailed(address: "d0c050d51077", matchCount: 2)
            )
        }
    }

    func testPostPairVerificationChecksPairedNameAndClass() {
        let invalidCases: [(PairedBluetoothDevice, PairSafetyError)] = [
            (device(isPaired: false), .pairedDeviceIsNotPaired),
            (device(name: "Magic Keyboard", isPaired: true), .pinnedDeviceNameMismatch(name: "Magic Keyboard")),
            (device(isPaired: true, classOfDevice: 0x002540), .pinnedDeviceClassMismatch(actual: 0x002540))
        ]

        for (record, expectedError) in invalidCases {
            XCTAssertThrowsError(
                try PairSafety.selectVerifiedPairedDevice(
                    from: [record],
                    configuredAddress: "d0-c0-50-d5-10-77"
                )
            ) {
                XCTAssertEqual($0 as? PairSafetyError, expectedError)
            }
        }
    }

    func testCallbackDecisionsNeverAutomaticallyAnswerInteractiveChallenges() {
        XCTAssertEqual(PairSafety.decision(for: .pinCodeRequest), .stopAndReport)
        XCTAssertEqual(
            PairSafety.decision(for: .userConfirmationRequest(numericValue: 123_456)),
            .stopAndReport
        )
        XCTAssertEqual(
            PairSafety.decision(for: .passkeyNotification(passkey: 654_321)),
            .stopAndReport
        )
    }

    func testCallbackDecisionsContinueForProgressAndCompleteOnlyWhenFinished() {
        XCTAssertEqual(PairSafety.decision(for: .pairingStarted), .continueWaiting)
        XCTAssertEqual(PairSafety.decision(for: .connecting), .continueWaiting)
        XCTAssertEqual(PairSafety.decision(for: .connected), .continueWaiting)
        XCTAssertEqual(
            PairSafety.decision(for: .simplePairingComplete(status: 0)),
            .continueWaiting
        )
        XCTAssertEqual(
            PairSafety.decision(for: .pairingFinished(resultCode: 0)),
            .completed(resultCode: 0)
        )
    }

    private func device(
        name: String = "Ranveer's Magic Mouse",
        address: String = "d0-c0-50-d5-10-77",
        isPaired: Bool = false,
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
