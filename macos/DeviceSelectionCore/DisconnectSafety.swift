public typealias DisconnectSafetyError = GuardedMagicMouseSelectionError

public enum DisconnectSafety {
    public static let confirmationPhrase = "DISCONNECT MAGIC MOUSE"
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
