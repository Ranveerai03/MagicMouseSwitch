using Windows.Devices.Enumeration;

namespace MagicMouseSwitch.Cli;

internal enum MouseConnectionState
{
    Unknown,
    Unpaired,
    PairedDisconnected,
    Connected
}

internal enum MouseOperationProgressKind
{
    Disconnecting,
    Disconnected,
    WakeMouse,
    Searching,
    Pairing,
    Connected,
    PairingFailed,
    SafetyFailure
}

internal sealed record MouseOperationProgress(MouseOperationProgressKind Kind, string Message);

internal sealed record DisconnectResult(
    bool Success,
    DeviceUnpairingResultStatus? Status,
    BluetoothEndpoint? Endpoint,
    string Message);

internal sealed class MagicMouseOperations(
    EndpointDiscovery discovery,
    ConfigStore configStore,
    OperationLogger logger)
{
    internal async Task<MouseConnectionState> GetStateAsync(CancellationToken cancellationToken)
    {
        MagicMouseConfig? config = await configStore.LoadAsync(cancellationToken);
        if (string.IsNullOrWhiteSpace(config?.DeviceId))
        {
            return MouseConnectionState.Unknown;
        }

        DeviceInformation? device = await DeviceInformation.CreateFromIdAsync(
            config.DeviceId,
            EndpointDiscovery.RequestedProperties,
            DeviceInformationKind.AssociationEndpoint);
        cancellationToken.ThrowIfCancellationRequested();
        BluetoothEndpoint? endpoint = device is null ? null : EndpointDiscovery.TryCreateEndpoint(device);
        if (endpoint is null ||
            !string.Equals(
                endpoint.NormalizedAddress,
                TargetDevice.NormalizedBluetoothAddress,
                StringComparison.Ordinal) ||
            !UiTextNormalizer.ContainsMagicMouse(endpoint.Name))
        {
            return MouseConnectionState.Unknown;
        }

        if (!endpoint.IsPaired)
        {
            return MouseConnectionState.Unpaired;
        }

        return endpoint.IsConnected
            ? MouseConnectionState.Connected
            : MouseConnectionState.PairedDisconnected;
    }

    internal async Task<DisconnectResult> DisconnectAsync(
        OperationTimeline timeline,
        IProgress<MouseOperationProgress>? progress,
        CancellationToken cancellationToken)
    {
        timeline.Progress("paired_endpoint_lookup_started", "Resolving paired Magic Mouse endpoint...");
        BluetoothEndpoint endpoint = await new PairedEndpointResolver(discovery, configStore, logger)
            .ResolveAsync(timeline, cancellationToken);
        timeline.Progress("paired_endpoint_resolved", "Endpoint resolved.", $"id={endpoint.Id}");

        if (!EndpointDiscovery.IsSafeTarget(endpoint) || !endpoint.IsPaired)
        {
            const string safetyMessage = "Safety stop: endpoint identity or paired state changed before unpairing.";
            progress?.Report(new MouseOperationProgress(MouseOperationProgressKind.SafetyFailure, safetyMessage));
            return new DisconnectResult(false, null, endpoint, safetyMessage);
        }

        progress?.Report(new MouseOperationProgress(
            MouseOperationProgressKind.Disconnecting,
            "Disconnecting…"));
        timeline.Progress("unpair_started", "Removing Magic Mouse...");
        logger.Info("unpairing", $"start id={endpoint.Id} address={endpoint.Address}");
        DeviceUnpairingResult unpairResult = await endpoint.Device.Pairing.UnpairAsync();
        logger.Info("unpairing", $"result={unpairResult.Status}");
        timeline.Progress(
            "unpair_completed",
            $"UnpairAsync returned: {unpairResult.Status}",
            $"status={unpairResult.Status}");

        bool success = unpairResult.Status is
            DeviceUnpairingResultStatus.Unpaired or DeviceUnpairingResultStatus.AlreadyUnpaired;
        if (!success)
        {
            string failure = $"Failed to disconnect Magic Mouse: {unpairResult.Status}";
            progress?.Report(new MouseOperationProgress(MouseOperationProgressKind.PairingFailed, failure));
            return new DisconnectResult(false, unpairResult.Status, endpoint, failure);
        }

        timeline.Progress("unpaired_state_confirmed", "Windows confirmed removal.");
        progress?.Report(new MouseOperationProgress(
            MouseOperationProgressKind.Disconnected,
            "Magic Mouse disconnected"));
        return new DisconnectResult(true, unpairResult.Status, endpoint, "Magic Mouse disconnected");
    }
}
