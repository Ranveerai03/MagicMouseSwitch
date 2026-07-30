using Windows.Devices.Enumeration;

namespace MagicMouseSwitch.Cli;

internal sealed class PairedEndpointResolver(
    EndpointDiscovery discovery,
    ConfigStore configStore,
    OperationLogger logger)
{
    private static readonly TimeSpan FallbackTimeout = TimeSpan.FromSeconds(5);

    internal async Task<BluetoothEndpoint> ResolveAsync(
        OperationTimeline timeline,
        CancellationToken cancellationToken)
    {
        MagicMouseConfig? config = null;
        try
        {
            config = await configStore.LoadAsync(cancellationToken);
            timeline.Progress(
                "saved_device_id_loaded",
                config is null ? "No saved Device ID was found." : "Saved Device ID loaded.",
                config is null ? "found=false" : $"found=true id={config.DeviceId}");
        }
        catch (Exception exception) when (exception is not OperationCanceledException)
        {
            logger.Error("config_load", exception);
            timeline.Progress(
                "saved_device_id_loaded",
                "Saved Device ID could not be loaded; using fallback enumeration.",
                $"found=false error={exception.Message}");
        }

        if (!string.IsNullOrWhiteSpace(config?.DeviceId))
        {
            BluetoothEndpoint? direct = await TryResolveDirectAsync(
                config.DeviceId,
                timeline,
                cancellationToken);
            if (direct is not null)
            {
                PrintPath("saved Device ID");
                return direct;
            }
        }

        timeline.Progress("fallback_enumeration_started", "Starting pinned paired-endpoint fallback enumeration...");
        BluetoothEndpoint fallback = await discovery.WaitForTargetAsync(
            paired: true,
            timeout: FallbackTimeout,
            cancellationToken);
        if (!IsValidPairedTarget(fallback))
        {
            throw new InvalidOperationException(
                "Fallback endpoint failed paired-state, address, or Magic Mouse name validation.");
        }

        timeline.Progress(
            "fallback_endpoint_found",
            "Fallback endpoint found.",
            $"id={fallback.Id} address={fallback.Address}");
        await configStore.SaveAfterSuccessfulPairingAsync(fallback);
        logger.Info("config_save", $"reason=fallback_endpoint id={fallback.Id} address={fallback.Address}");
        PrintPath("fallback enumeration");
        return fallback;
    }

    private async Task<BluetoothEndpoint?> TryResolveDirectAsync(
        string deviceId,
        OperationTimeline timeline,
        CancellationToken cancellationToken)
    {
        timeline.Progress(
            "direct_create_from_id_started",
            "Resolving saved AssociationEndpoint directly...");
        try
        {
            DeviceInformation? device = await DeviceInformation.CreateFromIdAsync(
                deviceId,
                EndpointDiscovery.RequestedProperties,
                DeviceInformationKind.AssociationEndpoint);
            cancellationToken.ThrowIfCancellationRequested();
            timeline.Progress(
                "direct_create_from_id_completed",
                "Direct CreateFromIdAsync completed.",
                $"result_null={device is null}");

            BluetoothEndpoint? endpoint = device is null ? null : EndpointDiscovery.TryCreateEndpoint(device);
            bool valid = endpoint is not null && IsValidPairedTarget(endpoint);
            timeline.Progress(
                "direct_endpoint_validation_completed",
                valid ? "Direct endpoint validation completed." : "Direct endpoint was stale or failed validation.",
                $"valid={valid}");
            return valid ? endpoint : null;
        }
        catch (Exception exception) when (exception is not OperationCanceledException)
        {
            logger.Error("direct_endpoint_resolution", exception);
            timeline.Progress(
                "direct_create_from_id_completed",
                "Direct CreateFromIdAsync failed; using fallback enumeration.",
                $"success=false error={exception.Message}");
            timeline.Progress(
                "direct_endpoint_validation_completed",
                "Direct endpoint validation completed.",
                "valid=false");
            return null;
        }
    }

    private static bool IsValidPairedTarget(BluetoothEndpoint endpoint) =>
        endpoint.IsPaired &&
        string.Equals(
            endpoint.NormalizedAddress,
            TargetDevice.NormalizedBluetoothAddress,
            StringComparison.Ordinal) &&
        UiTextNormalizer.ContainsMagicMouse(endpoint.Name);

    private static void PrintPath(string path)
    {
        Console.WriteLine($"Endpoint resolution path: {path}");
        Console.Out.Flush();
    }
}
