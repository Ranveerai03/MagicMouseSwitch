using System.Diagnostics;
using Windows.Devices.Enumeration;

namespace MagicMouseSwitch.Cli;

internal sealed class UnpairCommand(EndpointDiscovery discovery, OperationLogger logger)
{
    internal async Task<int> RunAsync(CancellationToken cancellationToken)
    {
        IReadOnlyList<BluetoothEndpoint> matches =
            await discovery.FindTargetEndpointsAsync(includeUnpairedScan: false, cancellationToken);
        if (matches.Count == 0)
        {
            Console.WriteLine("The pinned Magic Mouse is already removed.");
            return 0;
        }

        if (matches.Count != 1)
        {
            Console.Error.WriteLine($"Safety stop: expected one pinned paired endpoint; found {matches.Count}.");
            return 2;
        }

        BluetoothEndpoint endpoint = matches[0];
        endpoint.Print();
        Console.WriteLine();
        Console.Write($"Type exactly '{TargetDevice.ConfirmationPhrase}' to continue: ");
        if (!string.Equals(Console.ReadLine(), TargetDevice.ConfirmationPhrase, StringComparison.Ordinal))
        {
            Console.WriteLine("Cancelled. No device was changed.");
            return 3;
        }

        if (!EndpointDiscovery.IsSafeTarget(endpoint))
        {
            Console.Error.WriteLine("Safety stop: endpoint identity changed before unpairing.");
            return 2;
        }

        Console.WriteLine("Removing Magic Mouse. This can take several seconds...");
        Stopwatch elapsed = Stopwatch.StartNew();
        logger.Info("unpairing", $"start id={endpoint.Id} address={endpoint.Address}");
        DeviceUnpairingResult result = await endpoint.Device.Pairing.UnpairAsync();
        logger.Info("unpairing", $"result={result.Status}", elapsed);
        if (result.Status is not (DeviceUnpairingResultStatus.Unpaired or DeviceUnpairingResultStatus.AlreadyUnpaired))
        {
            Console.Error.WriteLine($"Failed to remove Magic Mouse: {result.Status}");
            return 4;
        }

        Console.WriteLine("Magic Mouse removed.");
        Console.WriteLine("Turn the Magic Mouse off and back on.");
        return 0;
    }
}
