public enum BluetoothAddressNormalizer {
    /// Returns 12 lowercase ASCII hexadecimal digits after removing `:` and `-`.
    /// Invalid Bluetooth addresses return `nil`.
    public static func normalize(_ address: String) -> String? {
        let trimmed = address.trimmingCharacters(in: .whitespacesAndNewlines)
        let withoutSeparators = trimmed.filter { character in
            character != ":" && character != "-"
        }

        guard withoutSeparators.utf8.count == 12 else {
            return nil
        }

        guard withoutSeparators.utf8.allSatisfy(isASCIIHexDigit) else {
            return nil
        }

        return withoutSeparators.lowercased()
    }

    private static func isASCIIHexDigit(_ byte: UInt8) -> Bool {
        switch byte {
        case 48...57, 65...70, 97...102:
            return true
        default:
            return false
        }
    }
}
