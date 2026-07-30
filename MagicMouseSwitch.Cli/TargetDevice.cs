namespace MagicMouseSwitch.Cli;

internal static class TargetDevice
{
    internal const string DisplayName = "Ranveer's Magic Mouse";
    internal const string RequiredNameFragment = "Magic Mouse";
    internal const string BluetoothAddress = "d0:c0:50:d5:10:77";
    internal const string InitialDeviceId =
        "Bluetooth#Bluetooth58:cd:c9:60:c4:5a-d0:c0:50:d5:10:77";
    internal const string ConfirmationPhrase = "UNPAIR RANVEER MAGIC MOUSE";

    internal static readonly string NormalizedBluetoothAddress =
        BluetoothAddressNormalizer.Normalize(BluetoothAddress);
}

internal static class BluetoothAddressNormalizer
{
    internal static string Normalize(string address)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(address);

        string normalized = new(address.Where(Uri.IsHexDigit).ToArray());
        if (normalized.Length != 12)
        {
            throw new FormatException(
                $"Bluetooth address '{address}' does not contain exactly 12 hexadecimal digits.");
        }

        return normalized.ToUpperInvariant();
    }

    internal static string Format(string normalized)
    {
        string value = Normalize(normalized);
        return string.Join(":", Enumerable.Range(0, 6).Select(i => value.Substring(i * 2, 2)))
            .ToLowerInvariant();
    }
}
