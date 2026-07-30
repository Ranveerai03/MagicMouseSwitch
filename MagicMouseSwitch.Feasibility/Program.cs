using Windows.Devices.Bluetooth;
using Windows.Devices.Enumeration;

const string TargetName = "Magic Mouse";
string[] properties =
[
    "System.Devices.Aep.DeviceAddress",
    "System.Devices.Aep.IsConnected",
    "System.Devices.Aep.IsPresent",
    "System.Devices.Aep.Bluetooth.Le.IsConnectable"
];

Console.WriteLine("Read-only Magic Mouse PairAsync feasibility probe");
Console.WriteLine($"Target name is an exact ordinal match: {TargetName}");

foreach (bool paired in new[] { true, false })
{
    string selector = BluetoothDevice.GetDeviceSelectorFromPairingState(paired);
    DeviceInformationCollection devices = await DeviceInformation.FindAllAsync(
        selector,
        properties,
        DeviceInformationKind.AssociationEndpoint);

    Console.WriteLine($"{(paired ? "Paired" : "Unpaired/discovered")} Bluetooth AEP count: {devices.Count}");
    foreach (DeviceInformation device in devices.Where(d =>
                 d.Name.Contains("Magic Mouse", StringComparison.OrdinalIgnoreCase)))
    {
        bool exact = string.Equals(device.Name, TargetName, StringComparison.Ordinal);
        Console.WriteLine($"  Name={device.Name}; Exact={exact}; IsPaired={device.Pairing.IsPaired}; CanPair={device.Pairing.CanPair}");
        Console.WriteLine($"  Id={device.Id}");
        foreach (string property in properties)
        {
            device.Properties.TryGetValue(property, out object? value);
            Console.WriteLine($"  {property}={value ?? "<missing>"}");
        }
    }
}
