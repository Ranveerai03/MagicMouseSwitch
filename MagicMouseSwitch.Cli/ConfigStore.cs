using System.IO;
using System.Text.Json;

namespace MagicMouseSwitch.Cli;

internal sealed class ConfigStore
{
    private readonly string _path = AppDataPaths.ConfigPath;

    internal async Task SaveAfterSuccessfulPairingAsync(BluetoothEndpoint endpoint)
    {
        Directory.CreateDirectory(AppDataPaths.RootDirectory);
        var config = new
        {
            BluetoothAddress = endpoint.Address,
            DeviceId = endpoint.Id,
            SavedAt = DateTimeOffset.Now
        };
        await using FileStream stream = File.Create(_path);
        await JsonSerializer.SerializeAsync(stream, config, new JsonSerializerOptions { WriteIndented = true });
        await stream.WriteAsync("\n"u8.ToArray());
    }

    internal async Task<MagicMouseConfig?> LoadAsync(CancellationToken cancellationToken)
    {
        if (!File.Exists(_path))
        {
            await MigrateOrInitializeAsync(cancellationToken);
        }

        await using FileStream stream = File.OpenRead(_path);
        return await JsonSerializer.DeserializeAsync<MagicMouseConfig>(
            stream,
            cancellationToken: cancellationToken);
    }

    private async Task MigrateOrInitializeAsync(CancellationToken cancellationToken)
    {
        Directory.CreateDirectory(AppDataPaths.RootDirectory);

        foreach (string candidate in LegacyConfigCandidates())
        {
            if (!File.Exists(candidate) ||
                string.Equals(candidate, _path, StringComparison.OrdinalIgnoreCase))
            {
                continue;
            }

            try
            {
                await using FileStream source = File.OpenRead(candidate);
                MagicMouseConfig? legacy = await JsonSerializer.DeserializeAsync<MagicMouseConfig>(
                    source,
                    cancellationToken: cancellationToken);
                if (legacy is not null && IsPinnedConfig(legacy))
                {
                    await WriteAsync(legacy, cancellationToken);
                    return;
                }
            }
            catch (Exception exception) when (
                exception is not OperationCanceledException &&
                exception is not UnauthorizedAccessException)
            {
                // A stale development file must not prevent safe initialization.
            }
        }

        await WriteAsync(
            new MagicMouseConfig(
                TargetDevice.BluetoothAddress,
                TargetDevice.InitialDeviceId,
                DateTimeOffset.Now),
            cancellationToken);
    }

    private async Task WriteAsync(MagicMouseConfig config, CancellationToken cancellationToken)
    {
        await using FileStream stream = File.Create(_path);
        await JsonSerializer.SerializeAsync(
            stream,
            config,
            new JsonSerializerOptions { WriteIndented = true },
            cancellationToken);
        await stream.WriteAsync("\n"u8.ToArray(), cancellationToken);
    }

    private static bool IsPinnedConfig(MagicMouseConfig config)
    {
        try
        {
            return string.Equals(
                       BluetoothAddressNormalizer.Normalize(config.BluetoothAddress),
                       TargetDevice.NormalizedBluetoothAddress,
                       StringComparison.Ordinal) &&
                   !string.IsNullOrWhiteSpace(config.DeviceId);
        }
        catch (FormatException)
        {
            return false;
        }
    }

    private static IEnumerable<string> LegacyConfigCandidates()
    {
        yield return Path.Combine(AppContext.BaseDirectory, "config.json");
        yield return Path.Combine(Environment.CurrentDirectory, "config.json");
        yield return Path.Combine(Environment.CurrentDirectory, "MagicMouseSwitch.Tray", "config.json");
        yield return Path.Combine(Environment.CurrentDirectory, "MagicMouseSwitch.Cli", "config.json");
    }
}

internal sealed record MagicMouseConfig(
    string BluetoothAddress,
    string DeviceId,
    DateTimeOffset SavedAt);
