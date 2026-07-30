using Windows.Devices.Enumeration;

namespace MagicMouseSwitch.Cli;

internal sealed record BluetoothEndpoint(
    DeviceInformation Device,
    string Name,
    string Address,
    string NormalizedAddress,
    bool IsPaired,
    bool IsConnected,
    bool IsPresent)
{
    internal string Id => Device.Id;

    internal void Print()
    {
        Console.WriteLine($"Selected name:      {Name}");
        Console.WriteLine($"Bluetooth address: {Address}");
        Console.WriteLine($"Device ID:         {Id}");
        Console.WriteLine($"Paired:            {IsPaired}");
        Console.WriteLine($"Connected:         {IsConnected}");
        Console.WriteLine($"Present:           {IsPresent}");
    }
}
