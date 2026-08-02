public typealias ForgetSafetyError = GuardedMagicMouseSelectionError

public enum ForgetSafety {
    public static let confirmationPhrase = "FORGET MAGIC MOUSE"
    public static let expectedPointingDeviceClass = GuardedMagicMouseSelection.expectedPointingDeviceClass

    public static func confirmationIsExact(_ enteredPhrase: String) -> Bool {
        enteredPhrase == confirmationPhrase
    }

    public static func selectEligibleDevice(
        from pairedDevices: [PairedBluetoothDevice],
        configuredAddress: String
    ) throws -> PairedBluetoothDevice {
        try GuardedMagicMouseSelection.selectEligibleDevice(
            from: pairedDevices,
            configuredAddress: configuredAddress
        )
    }
}
