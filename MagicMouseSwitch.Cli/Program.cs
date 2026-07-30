using MagicMouseSwitch.Cli;

OperationLogger logger = new();
EndpointDiscovery discovery = new(logger);
using CancellationTokenSource cancellation = new();
Console.CancelKeyPress += (_, eventArgs) =>
{
    eventArgs.Cancel = true;
    cancellation.Cancel();
};

try
{
    string command = args.FirstOrDefault()?.ToLowerInvariant() ?? "help";
    int exitCode = command switch
    {
        "dry-run" => await RunDryRunAsync(discovery, cancellation.Token),
        "status" => await RunStatusAsync(discovery, cancellation.Token),
        "unpair" => await new UnpairCommand(discovery, logger).RunAsync(cancellation.Token),
        "pair-ui" => await new WindowsSettingsPairer(discovery, logger, new ConfigStore())
            .PairAsync(
                cancellation.Token,
                strictAddressBeforeClick: args.Skip(1).Any(argument =>
                    argument.Equals("--strict-address-before-click", StringComparison.OrdinalIgnoreCase))),
        "inspect-pairing-ui" => await new WindowsSettingsPairer(discovery, logger, new ConfigStore())
            .InspectPairingUiAsync(cancellation.Token),
        "feasibility-test" => await new FeasibilityTest(discovery, logger, new ConfigStore())
            .RunAsync(cancellation.Token),
        _ => PrintHelp()
    };
    Console.WriteLine($"Log: {logger.LogPath}");
    return exitCode;
}
catch (OperationCanceledException)
{
    Console.Error.WriteLine("Cancelled.");
    return 130;
}
catch (Exception exception)
{
    logger.Error("application", exception);
    Console.Error.WriteLine($"Error: {exception.Message}");
    Console.Error.WriteLine($"Log: {logger.LogPath}");
    return 1;
}

static async Task<int> RunDryRunAsync(EndpointDiscovery discovery, CancellationToken cancellationToken)
{
    Console.WriteLine("DRY RUN — PairAsync and UnpairAsync will not be called.");
    IReadOnlyList<BluetoothEndpoint> matches =
        await discovery.FindTargetEndpointsAsync(includeUnpairedScan: true, cancellationToken);
    if (matches.Count != 1)
    {
        Console.Error.WriteLine($"Safety stop: expected exactly one matching AssociationEndpoint; found {matches.Count}.");
        return 2;
    }

    BluetoothEndpoint endpoint = matches[0];
    endpoint.Print();
    Console.WriteLine();
    Console.WriteLine("Safety validation: PASS (normalized address and name fragment both match).");
    Console.WriteLine($"Next toggle operation: {(endpoint.IsPaired ? "UnpairAsync" : "PairAsync")}");
    Console.WriteLine("No device was changed.");
    return 0;
}

static async Task<int> RunStatusAsync(EndpointDiscovery discovery, CancellationToken cancellationToken)
{
    IReadOnlyList<BluetoothEndpoint> matches =
        await discovery.FindTargetEndpointsAsync(includeUnpairedScan: false, cancellationToken);
    if (matches.Count == 0)
    {
        Console.WriteLine("Confirmed Magic Mouse is not paired.");
        return 0;
    }

    if (matches.Count != 1)
    {
        Console.Error.WriteLine($"Safety stop: found {matches.Count} matching endpoints.");
        return 2;
    }

    matches[0].Print();
    return 0;
}

static int PrintHelp()
{
    Console.WriteLine("Magic Mouse Switch feasibility CLI");
    Console.WriteLine("  status            Show the confirmed target's paired/connected state");
    Console.WriteLine("  dry-run           Resolve and validate the exact AssociationEndpoint; change nothing");
    Console.WriteLine("  unpair            Remove only the pinned mouse after exact typed confirmation");
    Console.WriteLine("  pair-ui           Pair the pinned mouse through Windows Settings UI Automation");
    Console.WriteLine("    --strict-address-before-click  Wait for the pinned unpaired endpoint before UI selection");
    Console.WriteLine("  inspect-pairing-ui  Dump the Add a device UIA tree without selecting a device");
    Console.WriteLine("  feasibility-test  Deliberately unpair and re-pair after exact typed confirmation");
    return 64;
}
