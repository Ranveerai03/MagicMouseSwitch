namespace MagicMouseSwitch.Cli;

internal sealed class FeasibilityTest(
    EndpointDiscovery discovery,
    OperationLogger logger,
    ConfigStore configStore)
{
    internal async Task<int> RunAsync(CancellationToken cancellationToken)
    {
        Console.WriteLine("============================================================");
        Console.WriteLine("FEASIBILITY TEST — DESTRUCTIVE BLUETOOTH TEST");
        Console.WriteLine("============================================================");
        Console.WriteLine();
        Console.WriteLine("This test will remove and re-pair Ranveer’s Magic Mouse.");
        Console.WriteLine();
        Console.WriteLine("Type exactly:");
        Console.WriteLine(TargetDevice.ConfirmationPhrase);
        Console.WriteLine();
        Console.WriteLine("Then press Enter.");
        Console.WriteLine();
        Console.Write("Waiting for confirmation: ");
        Console.Out.Flush();
        string? confirmation = Console.ReadLine();
        if (!string.Equals(confirmation, TargetDevice.ConfirmationPhrase, StringComparison.Ordinal))
        {
            Console.WriteLine("Confirmation did not match. No device was changed.");
            return 3;
        }

        OperationTimeline timeline = new(logger);
        timeline.Progress("confirmation_accepted", "Confirmation accepted.");
        try
        {
            DisconnectResult disconnect = await new MagicMouseOperations(discovery, configStore, logger)
                .DisconnectAsync(timeline, progress: null, cancellationToken);
            if (!disconnect.Success)
            {
                Console.Error.WriteLine(disconnect.Message);
                return 4;
            }

            disconnect.Endpoint?.Print();
            Console.WriteLine();
            Console.WriteLine("Magic Mouse removed.");
            Console.Out.Flush();
            return await new WindowsSettingsPairer(discovery, logger, configStore)
                .PairAsync(
                    cancellationToken,
                    strictAddressBeforeClick: false,
                    sharedTimeline: timeline,
                    printTimingSummary: false);
        }
        finally
        {
            timeline.PrintSummary();
        }
    }
}
