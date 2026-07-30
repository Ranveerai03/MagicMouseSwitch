using System.Diagnostics;
using Windows.Devices.Bluetooth;
using Windows.Devices.Enumeration;

namespace MagicMouseSwitch.Cli;

internal sealed class EndpointDiscovery(OperationLogger logger)
{
    internal const string AddressProperty = "System.Devices.Aep.DeviceAddress";
    internal const string ConnectedProperty = "System.Devices.Aep.IsConnected";
    internal const string PresentProperty = "System.Devices.Aep.IsPresent";

    internal static readonly string[] RequestedProperties =
    [
        AddressProperty,
        ConnectedProperty,
        PresentProperty
    ];

    internal async Task<IReadOnlyList<BluetoothEndpoint>> FindTargetEndpointsAsync(
        bool includeUnpairedScan,
        CancellationToken cancellationToken)
    {
        Stopwatch elapsed = Stopwatch.StartNew();
        logger.Info("discovery", $"start include_unpaired={includeUnpairedScan}");

        try
        {
            List<DeviceInformation> devices = [];
            devices.AddRange(await FindAllAsync(paired: true, cancellationToken));
            if (includeUnpairedScan)
            {
                devices.AddRange(await FindAllAsync(paired: false, cancellationToken));
            }

            IReadOnlyList<BluetoothEndpoint> matches = devices
                .GroupBy(device => device.Id, StringComparer.OrdinalIgnoreCase)
                .Select(group => group.First())
                .Select(TryCreateEndpoint)
                .Where(endpoint => endpoint is not null)
                .Cast<BluetoothEndpoint>()
                .Where(IsSafeTarget)
                .ToArray();

            logger.Info("discovery", $"complete safe_matches={matches.Count}", elapsed);
            return matches;
        }
        catch (Exception exception)
        {
            logger.Error("discovery", exception, elapsed);
            throw;
        }
    }

    internal async Task<IReadOnlyList<BluetoothEndpoint>> FindNamedMagicMouseEndpointsAsync(
        bool paired,
        CancellationToken cancellationToken)
    {
        Stopwatch elapsed = Stopwatch.StartNew();
        logger.Info("discovery", $"named_magic_mouse_start paired={paired}");
        try
        {
            IReadOnlyList<BluetoothEndpoint> matches = (await FindAllAsync(paired, cancellationToken))
                .GroupBy(device => device.Id, StringComparer.OrdinalIgnoreCase)
                .Select(group => group.First())
                .Select(TryCreateEndpoint)
                .Where(endpoint => endpoint is not null)
                .Cast<BluetoothEndpoint>()
                .Where(endpoint => endpoint.Name.Contains(
                    TargetDevice.RequiredNameFragment,
                    StringComparison.OrdinalIgnoreCase))
                .ToArray();
            logger.Info("discovery", $"named_magic_mouse_complete paired={paired} matches={matches.Count}", elapsed);
            return matches;
        }
        catch (Exception exception)
        {
            logger.Error("discovery", exception, elapsed);
            throw;
        }
    }

    internal async Task<BluetoothEndpoint> WaitForTargetAsync(
        bool paired,
        TimeSpan timeout,
        CancellationToken cancellationToken)
    {
        Stopwatch elapsed = Stopwatch.StartNew();
        logger.Info("discovery", $"watch_start paired={paired} timeout_seconds={timeout.TotalSeconds}");

        string selector = BluetoothDevice.GetDeviceSelectorFromPairingState(paired);
        DeviceWatcher watcher = DeviceInformation.CreateWatcher(
            selector,
            RequestedProperties,
            DeviceInformationKind.AssociationEndpoint);
        TaskCompletionSource<BluetoothEndpoint> found =
            new(TaskCreationOptions.RunContinuationsAsynchronously);

        void Added(DeviceWatcher _, DeviceInformation device)
        {
            BluetoothEndpoint? endpoint = TryCreateEndpoint(device);
            if (endpoint is not null && IsSafeTarget(endpoint))
            {
                found.TrySetResult(endpoint);
            }
        }

        watcher.Added += Added;
        using CancellationTokenSource timeoutSource = new(timeout);
        using CancellationTokenSource linked = CancellationTokenSource.CreateLinkedTokenSource(
            cancellationToken,
            timeoutSource.Token);
        using CancellationTokenRegistration registration = linked.Token.Register(() =>
            found.TrySetCanceled(linked.Token));

        try
        {
            watcher.Start();
            BluetoothEndpoint endpoint = await found.Task;
            logger.Info("discovery", $"watch_match id={endpoint.Id}", elapsed);
            return endpoint;
        }
        catch (OperationCanceledException) when (timeoutSource.IsCancellationRequested)
        {
            TimeoutException exception = new(
                $"Timed out after {timeout.TotalSeconds:0} seconds waiting for the confirmed Bluetooth address.");
            logger.Error("discovery", exception, elapsed);
            throw exception;
        }
        finally
        {
            watcher.Added -= Added;
            if (watcher.Status is DeviceWatcherStatus.Started or DeviceWatcherStatus.EnumerationCompleted)
            {
                watcher.Stop();
            }
        }
    }

    internal static bool IsSafeTarget(BluetoothEndpoint endpoint) =>
        string.Equals(
            endpoint.NormalizedAddress,
            TargetDevice.NormalizedBluetoothAddress,
            StringComparison.Ordinal) &&
        endpoint.Name.Contains(TargetDevice.RequiredNameFragment, StringComparison.OrdinalIgnoreCase);

    private static async Task<IEnumerable<DeviceInformation>> FindAllAsync(
        bool paired,
        CancellationToken cancellationToken)
    {
        cancellationToken.ThrowIfCancellationRequested();
        string selector = BluetoothDevice.GetDeviceSelectorFromPairingState(paired);
        DeviceInformationCollection result = await DeviceInformation.FindAllAsync(
            selector,
            RequestedProperties,
            DeviceInformationKind.AssociationEndpoint);
        cancellationToken.ThrowIfCancellationRequested();
        return result;
    }

    internal static BluetoothEndpoint? TryCreateEndpoint(DeviceInformation device)
    {
        if (!device.Properties.TryGetValue(AddressProperty, out object? rawAddress) ||
            rawAddress is not string address)
        {
            return null;
        }

        string normalized;
        try
        {
            normalized = BluetoothAddressNormalizer.Normalize(address);
        }
        catch (FormatException)
        {
            return null;
        }

        return new BluetoothEndpoint(
            device,
            device.Name,
            BluetoothAddressNormalizer.Format(normalized),
            normalized,
            device.Pairing.IsPaired,
            GetBoolean(device, ConnectedProperty),
            GetBoolean(device, PresentProperty));
    }

    private static bool GetBoolean(DeviceInformation device, string propertyName) =>
        device.Properties.TryGetValue(propertyName, out object? value) && value is true;
}
