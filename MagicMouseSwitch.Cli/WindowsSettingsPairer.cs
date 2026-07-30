using System.Diagnostics;
using System.Windows.Automation;
using Windows.Devices.Enumeration;

namespace MagicMouseSwitch.Cli;

internal sealed class WindowsSettingsPairer(
    EndpointDiscovery discovery,
    OperationLogger logger,
    ConfigStore configStore)
{
    // UIA_LegacyIAccessiblePatternId. The modern .NET Windows Desktop reference exposes
    // the registered AutomationPattern, but not the older strongly typed client wrapper.
    private static readonly AutomationPattern? LegacyAccessiblePattern = AutomationPattern.LookupById(10018);
    private static readonly TimeSpan DialogAttemptTimeout = TimeSpan.FromSeconds(8);
    private static readonly TimeSpan UiTimeout = TimeSpan.FromSeconds(45);
    private readonly UiAutomationElementLogger _elementLogger = new(logger);
    private AutomationElement? _settingsWindowUsed;
    private bool _settingsWindowOpenedByOperation;

    internal async Task<int> PairAsync(
        CancellationToken cancellationToken,
        bool strictAddressBeforeClick = false,
        OperationTimeline? sharedTimeline = null,
        bool printTimingSummary = true,
        bool requireCursorMovement = true,
        IProgress<MouseOperationProgress>? progress = null)
    {
        OperationTimeline timeline = sharedTimeline ?? new OperationTimeline(logger);
        try
        {
            IReadOnlyList<BluetoothEndpoint> paired =
                await discovery.FindTargetEndpointsAsync(includeUnpairedScan: false, cancellationToken);
            if (paired.Count > 1)
            {
                return Fail($"Safety stop: found {paired.Count} paired endpoints for the pinned address.");
            }

            if (paired.SingleOrDefault() is { IsPaired: true, IsConnected: true } existing)
            {
                existing.Print();
                timeline.Mark("paired_state_confirmed", "already_paired=true");
                timeline.Mark("connected_state_confirmed", "already_connected=true");
                progress?.Report(new MouseOperationProgress(
                    MouseOperationProgressKind.Connected,
                    "Magic Mouse connected"));
                Console.WriteLine("Magic Mouse connected.");
                logger.Info("pair_ui", "already_paired_and_connected=true");
                return 0;
            }

            progress?.Report(new MouseOperationProgress(
                MouseOperationProgressKind.WakeMouse,
                "Click the mouse to wake it"));
            AutomationElement pairingDialog = await OpenBluetoothPairingDialogAsync(cancellationToken, timeline);

            Console.WriteLine("Turn the Magic Mouse off and back on.");
            progress?.Report(new MouseOperationProgress(
                MouseOperationProgressKind.Searching,
                "Searching for Magic Mouse…"));
            AutomationElement actionableRow;
            if (strictAddressBeforeClick)
            {
                Console.WriteLine("Strict mode: waiting concurrently for the visible row and pinned Bluetooth endpoint...");
                Task<AutomationElement> uiTask = WaitForMagicMouseActionAsync(
                    pairingDialog,
                    UiTimeout,
                    cancellationToken,
                    requireExactFullName: false);
                Task<BluetoothEndpoint> bluetoothTask = discovery.WaitForTargetAsync(
                    paired: false,
                    timeout: UiTimeout,
                    cancellationToken);

                await Task.WhenAll(uiTask, bluetoothTask);
                actionableRow = await uiTask;
                BluetoothEndpoint discovered = await bluetoothTask;
                timeline.Mark("magic_mouse_ui_row_found");
                timeline.Mark("pinned_bluetooth_endpoint_found");
                discovered.Print();

                if (!EndpointDiscovery.IsSafeTarget(discovered) || discovered.IsPaired || !discovered.IsPresent)
                {
                    return Fail(
                        "Safety stop before selection: expected exactly one present, unpaired endpoint at the pinned address.");
                }
            }
            else
            {
                Console.WriteLine("Fast mode: waiting for the exact visible Magic Mouse row...");
                actionableRow = await WaitForMagicMouseActionAsync(
                    pairingDialog,
                    UiTimeout,
                    cancellationToken,
                    requireExactFullName: true);
                timeline.Mark("magic_mouse_ui_row_found");
                timeline.Mark("visible_exact_name_row_found");
            }

            PerformDefaultAction(actionableRow, "device_result");
            timeline.Mark("row_selected");
            progress?.Report(new MouseOperationProgress(
                MouseOperationProgressKind.Pairing,
                "Pairing…"));
            if (!strictAddressBeforeClick)
            {
                timeline.Mark("row_selected_before_endpoint_discovery");
            }
            Console.WriteLine("Pairing through Windows Settings...");

            BluetoothEndpoint connected = await CompleteAndVerifyAsync(pairingDialog, timeline, cancellationToken);
            await configStore.SaveAfterSuccessfulPairingAsync(connected);

            if (requireCursorMovement)
            {
                Console.WriteLine("Move the Magic Mouse within 15 seconds to validate cursor input...");
                bool cursorMoved = await CursorMovementVerifier.WaitAsync(TimeSpan.FromSeconds(15), cancellationToken);
                logger.Info("cursor_validation", $"moved={cursorMoved}");
                if (!cursorMoved)
                {
                    return Fail("Windows reports the pinned mouse connected, but cursor movement was not observed.");
                }

                timeline.Mark("cursor_movement_confirmed");
            }

            ClosePairingDialogOnly(pairingDialog);
            bool pairingDialogClosed = await WaitForPairingDialogClosedAsync(cancellationToken);
            if (pairingDialogClosed)
            {
                timeline.Mark("pairing_dialog_closed");
                CloseOwnedSettingsWindow(timeline);
            }
            else
            {
                logger.Info("window_cleanup", "settings window close skipped: pairing dialog remained open");
            }
            logger.Info(
                "pair_ui",
                $"verified address={connected.Address} paired={connected.IsPaired} connected={connected.IsConnected}");
            progress?.Report(new MouseOperationProgress(
                MouseOperationProgressKind.Connected,
                "Magic Mouse connected"));
            Console.WriteLine("Magic Mouse connected.");
            return 0;
        }
        catch (PairingSafetyException exception)
        {
            logger.Info("pair_ui", $"safety_failure={exception.Message}");
            progress?.Report(new MouseOperationProgress(
                MouseOperationProgressKind.SafetyFailure,
                "Safety verification failed"));
            Console.Error.WriteLine(exception.Message);
            return 7;
        }
        finally
        {
            if (printTimingSummary)
            {
                timeline.PrintSummary();
            }
        }
    }

    internal async Task<int> InspectPairingUiAsync(CancellationToken cancellationToken)
    {
        AutomationElement pairingDialog = await OpenBluetoothPairingDialogAsync(
            cancellationToken,
            new OperationTimeline(logger));
        Console.WriteLine("Turn the Magic Mouse off and back on if it is not already visible.");
        Console.WriteLine("Waiting for the visible device list to be populated...");

        await WaitForElementAsync(
            "inspection_populated_device_list",
            () => HasPopulatedDeviceList(pairingDialog) ? pairingDialog : null,
            UiTimeout,
            cancellationToken);

        Console.WriteLine();
        Console.WriteLine("=== Full Add a device UI Automation subtree ===");
        _elementLogger.LogTree("inspection_full_tree", pairingDialog, writeConsole: true);

        AutomationElement[] matches = FindMagicMouseTextElements(pairingDialog).ToArray();
        Console.WriteLine();
        Console.WriteLine($"=== Magic Mouse elements ({matches.Length}) ===");
        foreach (AutomationElement match in matches)
        {
            Console.WriteLine(UiAutomationElementLogger.Describe(match));
            Console.WriteLine("Ancestor chain:");
            _elementLogger.LogAncestorChain("inspection_magic_mouse", match, writeConsole: true);
            Console.WriteLine();
        }

        AutomationElement? textMatch = matches.FirstOrDefault();
        if (textMatch is null)
        {
            Console.WriteLine("No current dialog element contains 'Magic Mouse'. Nothing was clicked.");
            logger.Info("inspect_pairing_ui", "complete clicked=false magic_mouse_matches=0");
            return 0;
        }

        AutomationElement contentRoot = FindPairingContentRoot(pairingDialog) ?? pairingDialog;
        AutomationElement? actionable = FindNearestActionableAncestor(textMatch, contentRoot);
        if (actionable is null)
        {
            Console.WriteLine("No actionable ancestor was found. Nothing was clicked.");
            return 2;
        }

        Console.WriteLine("Nearest actionable ancestor (inspection only):");
        Console.WriteLine(UiAutomationElementLogger.Describe(actionable));
        Console.WriteLine("Nothing was clicked.");
        logger.Info("inspect_pairing_ui", "complete clicked=false actionable_ancestor_found=true");
        return 0;
    }

    private async Task<AutomationElement> OpenBluetoothPairingDialogAsync(
        CancellationToken cancellationToken,
        OperationTimeline timeline)
    {
        _settingsWindowUsed = null;
        _settingsWindowOpenedByOperation = false;
        AutomationElement? pairingDialog = FindAddDeviceDialog();
        if (pairingDialog is not null)
        {
            if (IsUsablePairingDialog(pairingDialog))
            {
                WindowForeground.TryBringToForeground(pairingDialog);
                timeline.Mark("add_device_dialog_found", "reused_existing=true");
                logger.Info("pair_ui", "reused_existing_add_device_dialog=true");
                return await EnsureBluetoothDeviceListAsync(pairingDialog, cancellationToken);
            }

            logger.Info("pair_ui", "stale_add_device_dialog=true action=close");
            CloseStalePairingDialog(pairingDialog);
        }

        Console.WriteLine("Opening Windows Bluetooth settings...");
        logger.Info("pair_ui", "launch uri=ms-settings:bluetooth");
        HashSet<int> settingsHandlesBeforeLaunch = GetSettingsWindowHandles();
        Process.Start(new ProcessStartInfo("ms-settings:bluetooth") { UseShellExecute = true });

        AutomationElement settingsWindow = await WaitForElementAsync(
            "settings_window",
            FindBluetoothSettingsWindow,
            DialogAttemptTimeout,
            cancellationToken);
        _settingsWindowUsed = settingsWindow;
        int settingsHandle = GetNativeWindowHandle(settingsWindow);
        _settingsWindowOpenedByOperation = settingsHandle != 0 &&
                                           !settingsHandlesBeforeLaunch.Contains(settingsHandle);
        WindowForeground.TryBringToForeground(settingsWindow);
        timeline.Mark(
            "settings_opened",
            $"opened_by_operation={_settingsWindowOpenedByOperation} native_handle={settingsHandle}");

        for (int attempt = 1; attempt <= 2; attempt++)
        {
            if (attempt == 2)
            {
                logger.Info("pair_ui", "dialog_open_retry=1");
                Console.WriteLine("Add a device dialog did not appear; retrying once...");
                AutomationElement? stale = FindAddDeviceDialog();
                if (stale is not null && IsUsablePairingDialog(stale))
                {
                    WindowForeground.TryBringToForeground(stale);
                    timeline.Mark("add_device_dialog_found", "found_during_retry_reenumeration=true");
                    return await EnsureBluetoothDeviceListAsync(stale, cancellationToken);
                }

                if (stale is not null)
                {
                    CloseStalePairingDialog(stale);
                }

                settingsWindow = await WaitForElementAsync(
                    "settings_window_retry",
                    FindBluetoothSettingsWindow,
                    DialogAttemptTimeout,
                    cancellationToken);
                _settingsWindowUsed = settingsWindow;
                settingsHandle = GetNativeWindowHandle(settingsWindow);
                _settingsWindowOpenedByOperation = settingsHandle != 0 &&
                                                   !settingsHandlesBeforeLaunch.Contains(settingsHandle);
                WindowForeground.TryBringToForeground(settingsWindow);
            }

            AutomationElement addDevice = await WaitForElementAsync(
                $"add_device_attempt_{attempt}",
                () => FindUniqueInteractiveByName(settingsWindow, ["Add device"]),
                DialogAttemptTimeout,
                cancellationToken);
            PerformDefaultAction(addDevice, "add_device");
            timeline.Mark("add_device_button_invoked", $"attempt={attempt}");

            try
            {
                pairingDialog = await WaitForElementAsync(
                    $"add_device_dialog_attempt_{attempt}",
                    FindAddDeviceDialog,
                    DialogAttemptTimeout,
                    cancellationToken);
                if (IsUsablePairingDialog(pairingDialog))
                {
                    WindowForeground.TryBringToForeground(pairingDialog);
                    timeline.Mark("add_device_dialog_found", $"attempt={attempt}");
                    return await EnsureBluetoothDeviceListAsync(pairingDialog, cancellationToken);
                }

                CloseStalePairingDialog(pairingDialog);
            }
            catch (TimeoutException exception)
            {
                logger.Info(
                    "pair_ui",
                    $"dialog_attempt={attempt} timed_out=true diagnostic={exception.Message}");
                // On attempt one, re-enumerate, foreground Settings, and invoke Add device once more.
            }
        }

        throw new TimeoutException(
            "Add a device ApplicationFrameWindow did not become usable after two 8-second attempts.");
    }

    private async Task<AutomationElement> EnsureBluetoothDeviceListAsync(
        AutomationElement pairingDialog,
        CancellationToken cancellationToken)
    {
        _elementLogger.LogTree("add_device_dialog_attached", pairingDialog);
        if (!HasPopulatedDeviceList(pairingDialog))
        {
            AutomationElement bluetoothChoice = await WaitForElementAsync(
                "bluetooth_choice",
                () => FindUniqueInteractiveByName(pairingDialog, ["Bluetooth"]),
                DialogAttemptTimeout,
                cancellationToken);
            PerformDefaultAction(bluetoothChoice, "bluetooth_choice");

            await WaitForElementAsync(
                "bluetooth_device_list",
                () => HasPopulatedDeviceList(pairingDialog) ? pairingDialog : null,
                DialogAttemptTimeout,
                cancellationToken);
        }

        _elementLogger.LogTree("bluetooth_device_dialog", pairingDialog);
        return pairingDialog;
    }

    private async Task<BluetoothEndpoint> CompleteAndVerifyAsync(
        AutomationElement pairingDialog,
        OperationTimeline timeline,
        CancellationToken cancellationToken)
    {
        Stopwatch elapsed = Stopwatch.StartNew();
        bool connectInvoked = false;
        DateTime deadline = DateTime.UtcNow + UiTimeout;
        DateTime nextProgress = DateTime.MinValue;
        string? verifiedDeviceId = null;

        while (DateTime.UtcNow < deadline)
        {
            cancellationToken.ThrowIfCancellationRequested();
            IReadOnlyList<BluetoothEndpoint> matches =
                await discovery.FindNamedMagicMouseEndpointsAsync(paired: true, cancellationToken);
            if (matches.Count > 0)
            {
                timeline.Mark("paired_state_confirmed");
                if (verifiedDeviceId is null)
                {
                    if (matches.Count != 1)
                    {
                        await RemoveMismatchedPairedEndpointsAsync(matches);
                        throw new PairingSafetyException(
                            "SAFETY FAILURE: Expected exactly one paired Magic Mouse endpoint.");
                    }

                    BluetoothEndpoint pairedEndpoint = matches[0];
                    if (!string.Equals(
                            pairedEndpoint.NormalizedAddress,
                            TargetDevice.NormalizedBluetoothAddress,
                            StringComparison.Ordinal))
                    {
                        await RemoveEndpointAfterSafetyFailureAsync(pairedEndpoint);
                        throw new PairingSafetyException(
                            "SAFETY FAILURE: Paired device address did not match pinned Magic Mouse.");
                    }

                    verifiedDeviceId = pairedEndpoint.Id;
                    timeline.Mark(
                        "paired_endpoint_address_verified",
                        $"address={pairedEndpoint.Address} id={pairedEndpoint.Id}");
                    logger.Info(
                        "pair_ui",
                        $"paired_endpoint_address_verified=true address={pairedEndpoint.Address} id={pairedEndpoint.Id}");
                }

                BluetoothEndpoint? verified = matches.SingleOrDefault(endpoint =>
                    string.Equals(endpoint.Id, verifiedDeviceId, StringComparison.OrdinalIgnoreCase));
                if (verified is { IsConnected: true })
                {
                    timeline.Mark("connected_state_confirmed");
                    logger.Info("pair_ui_wait", "paired_address_verified_and_connected=true", elapsed);
                    return verified;
                }
            }

            if (!connectInvoked)
            {
                AutomationElement? connect = FindUniqueInteractiveByName(pairingDialog, ["Connect"]);
                if (connect is not null)
                {
                    PerformDefaultAction(connect, "connect");
                    connectInvoked = true;
                }
            }

            if (DateTime.UtcNow >= nextProgress)
            {
                Console.WriteLine($"Still waiting for Windows confirmation... {elapsed.Elapsed.TotalSeconds:0}s");
                logger.Info("pair_ui_wait", "waiting_for_paired_connected=true", elapsed);
                _elementLogger.LogTree("pairing_progress", pairingDialog);
                nextProgress = DateTime.UtcNow + TimeSpan.FromSeconds(5);
            }

            await Task.Delay(500, cancellationToken);
        }

        throw new TimeoutException("Windows Settings did not report the pinned mouse paired and connected within 45 seconds.");
    }

    private async Task RemoveMismatchedPairedEndpointsAsync(IReadOnlyList<BluetoothEndpoint> endpoints)
    {
        foreach (BluetoothEndpoint endpoint in endpoints.Where(endpoint =>
                     !string.Equals(
                         endpoint.NormalizedAddress,
                         TargetDevice.NormalizedBluetoothAddress,
                         StringComparison.Ordinal)))
        {
            await RemoveEndpointAfterSafetyFailureAsync(endpoint);
        }
    }

    private async Task RemoveEndpointAfterSafetyFailureAsync(BluetoothEndpoint endpoint)
    {
        logger.Info(
            "pair_ui_safety_rollback",
            $"unpair_start name={endpoint.Name} address={endpoint.Address} id={endpoint.Id}");
        DeviceUnpairingResult result = await endpoint.Device.Pairing.UnpairAsync();
        logger.Info(
            "pair_ui_safety_rollback",
            $"unpair_result={result.Status} name={endpoint.Name} address={endpoint.Address} id={endpoint.Id}");
    }

    private async Task<AutomationElement> WaitForMagicMouseActionAsync(
        AutomationElement pairingDialog,
        TimeSpan timeout,
        CancellationToken cancellationToken,
        bool requireExactFullName)
    {
        AutomationElement contentRoot = FindPairingContentRoot(pairingDialog) ?? pairingDialog;
        object signalGate = new();
        TaskCompletionSource signal = NewSignal();
        StructureChangedEventHandler handler = (_, _) =>
        {
            lock (signalGate)
            {
                signal.TrySetResult();
            }
        };

        Stopwatch elapsed = Stopwatch.StartNew();
        DateTime nextProgress = DateTime.MinValue;
        bool eventHandlerRegistered = false;
        try
        {
            try
            {
                Automation.AddStructureChangedEventHandler(contentRoot, TreeScope.Subtree, handler);
                eventHandlerRegistered = true;
                logger.Info("ui_wait", "stage=magic_mouse_action structure_events=registered");
            }
            catch (ElementNotAvailableException)
            {
                logger.Info("ui_wait", "stage=magic_mouse_action structure_events=unavailable fallback=polling");
            }
            catch (InvalidOperationException exception)
            {
                logger.Info(
                    "ui_wait",
                    $"stage=magic_mouse_action structure_events=failed fallback=polling error={exception.Message}");
            }

            while (elapsed.Elapsed < timeout)
            {
                cancellationToken.ThrowIfCancellationRequested();
                AutomationElement? action = null;
                try
                {
                    action = requireExactFullName
                        ? FindSingleExactNamedMagicMouseAction(pairingDialog)
                        : FindSingleMagicMouseAction(pairingDialog);
                }
                catch (ElementNotAvailableException)
                {
                    logger.Info("ui_wait", "stage=magic_mouse_action transient_element_unavailable=true");
                }

                if (action is not null)
                {
                    logger.Info("ui_wait", "stage=magic_mouse_action found=true source=event_or_fallback", elapsed);
                    return action;
                }

                if (DateTime.UtcNow >= nextProgress)
                {
                    Console.WriteLine($"Waiting for Magic Mouse UI row... {elapsed.Elapsed.TotalSeconds:0}s");
                    logger.Info("ui_wait", "stage=magic_mouse_action found=false", elapsed);
                    nextProgress = DateTime.UtcNow + TimeSpan.FromSeconds(5);
                }

                Task currentSignal;
                lock (signalGate)
                {
                    currentSignal = signal.Task;
                }

                Task completed = await Task.WhenAny(
                    currentSignal,
                    Task.Delay(TimeSpan.FromMilliseconds(400), cancellationToken));
                if (completed == currentSignal)
                {
                    lock (signalGate)
                    {
                        if (ReferenceEquals(currentSignal, signal.Task))
                        {
                            signal = NewSignal();
                        }
                    }
                }
            }
        }
        finally
        {
            if (eventHandlerRegistered)
            {
                try
                {
                    Automation.RemoveStructureChangedEventHandler(contentRoot, handler);
                }
                catch (ElementNotAvailableException)
                {
                    logger.Info("ui_wait", "stage=magic_mouse_action event_root_closed=true");
                }
                catch (InvalidOperationException exception)
                {
                    logger.Info("ui_wait", $"stage=magic_mouse_action event_remove_failed={exception.Message}");
                }
            }
        }

        throw new TimeoutException("Timed out after 45 seconds waiting for the Magic Mouse UI row.");

        static TaskCompletionSource NewSignal() =>
            new(TaskCreationOptions.RunContinuationsAsynchronously);
    }

    private bool IsUsablePairingDialog(AutomationElement dialog)
    {
        try
        {
            return UiTextNormalizer.EqualsNormalized(dialog.Current.Name, "Add a device") &&
                   dialog.Current.ClassName.Equals("ApplicationFrameWindow", StringComparison.Ordinal) &&
                   dialog.Current.IsEnabled &&
                   !dialog.Current.IsOffscreen &&
                   FindPairingContentRoot(dialog) is not null;
        }
        catch (ElementNotAvailableException)
        {
            return false;
        }
    }

    private void CloseStalePairingDialog(AutomationElement dialog)
    {
        try
        {
            if (!UiTextNormalizer.EqualsNormalized(dialog.Current.Name, "Add a device"))
            {
                return;
            }

            if (dialog.TryGetCurrentPattern(WindowPattern.Pattern, out object pattern))
            {
                ((WindowPattern)pattern).Close();
                logger.Info("pair_ui", "stale_pairing_dialog_closed=true");
            }
        }
        catch (ElementNotAvailableException)
        {
            logger.Info("pair_ui", "stale_pairing_dialog_already_closed=true");
        }
    }

    private async Task<AutomationElement> WaitForElementAsync(
        string stage,
        Func<AutomationElement?> finder,
        TimeSpan timeout,
        CancellationToken cancellationToken)
    {
        Stopwatch elapsed = Stopwatch.StartNew();
        DateTime nextProgress = DateTime.MinValue;
        while (elapsed.Elapsed < timeout)
        {
            cancellationToken.ThrowIfCancellationRequested();
            AutomationElement? element = finder();
            if (element is not null)
            {
                _elementLogger.Log(stage, element);
                logger.Info("ui_wait", $"stage={stage} found=true", elapsed);
                return element;
            }

            if (DateTime.UtcNow >= nextProgress)
            {
                Console.WriteLine($"Waiting for {stage.Replace('_', ' ')}... {elapsed.Elapsed.TotalSeconds:0}s");
                logger.Info("ui_wait", $"stage={stage} found=false", elapsed);
                nextProgress = DateTime.UtcNow + TimeSpan.FromSeconds(5);
            }

            await Task.Delay(250, cancellationToken);
        }

        throw new TimeoutException($"Timed out after {timeout.TotalSeconds:0} seconds waiting for {stage.Replace('_', ' ')}.");
    }

    private AutomationElement? FindBluetoothSettingsWindow()
    {
        AutomationElementCollection windows = AutomationElement.RootElement.FindAll(
            TreeScope.Children,
            new PropertyCondition(AutomationElement.ControlTypeProperty, ControlType.Window));
        List<AutomationElement> candidates = [];
        foreach (AutomationElement window in windows)
        {
            try
            {
                bool namedSettings = window.Current.Name.Contains("Settings", StringComparison.OrdinalIgnoreCase);
                bool hasBluetoothPage = FindByName(window, "Bluetooth & devices").Count > 0;
                if (namedSettings && hasBluetoothPage)
                {
                    _elementLogger.Log("settings_window_candidate", window);
                    candidates.Add(window);
                }
            }
            catch (ElementNotAvailableException)
            {
                // A top-level window closed during enumeration.
            }
        }

        return candidates.Count == 1 ? candidates[0] : null;
    }

    private AutomationElement? FindAddDeviceDialog()
    {
        AutomationElementCollection topLevel = AutomationElement.RootElement.FindAll(
            TreeScope.Children,
            Condition.TrueCondition);
        List<AutomationElement> matches = [];
        foreach (AutomationElement desktopChild in topLevel)
        {
            try
            {
                _elementLogger.Log("desktop_child_during_dialog_search", desktopChild);
                AutomationElementCollection descendants = desktopChild.FindAll(
                    TreeScope.Descendants,
                    Condition.TrueCondition);
                IEnumerable<AutomationElement> titleElements = descendants
                    .Cast<AutomationElement>()
                    .Prepend(desktopChild)
                    .Where(element => UiTextNormalizer.EqualsNormalized(element.Current.Name, "Add a device"));

                foreach (AutomationElement titleElement in titleElements)
                {
                    _elementLogger.Log("add_device_title_candidate", titleElement);
                    AutomationElement? container = FindDialogContainerFromTitle(titleElement);
                    if (container is not null)
                    {
                        _elementLogger.Log("add_device_structural_container", container);
                        matches.Add(container);
                    }
                }
            }
            catch (ElementNotAvailableException)
            {
                // A dialog closed while the desktop children were enumerated.
            }
        }

        AutomationElement[] unique = matches
            .GroupBy(element => string.Join(".", element.GetRuntimeId()), StringComparer.Ordinal)
            .Select(group => group.First())
            .ToArray();

        AutomationElement[] windows = unique
            .Where(element => element.Current.ControlType == ControlType.Window)
            .ToArray();
        AutomationElement[] namedWindows = windows
            .Where(element => UiTextNormalizer.EqualsNormalized(element.Current.Name, "Add a device"))
            .ToArray();
        if (namedWindows.Length == 1)
        {
            return namedWindows[0];
        }

        if (windows.Length == 1)
        {
            return windows[0];
        }

        return unique.Length == 1 ? unique[0] : null;
    }

    private static AutomationElement? FindDialogContainerFromTitle(AutomationElement titleElement)
    {
        AutomationElement? current = titleElement;
        while (current is not null && !Automation.Compare(current, AutomationElement.RootElement))
        {
            try
            {
                ControlType type = current.Current.ControlType;
                bool containerType = type == ControlType.Window ||
                                     type == ControlType.Pane ||
                                     type == ControlType.Custom;
                if (containerType && HasDialogContent(current))
                {
                    return current;
                }

                current = TreeWalker.RawViewWalker.GetParent(current);
            }
            catch (ElementNotAvailableException)
            {
                return null;
            }
        }

        return null;
    }

    private static bool HasDialogContent(AutomationElement container)
    {
        AutomationElementCollection descendants = container.FindAll(
            TreeScope.Descendants,
            Condition.TrueCondition);
        bool hasCancel = false;
        bool hasBluetoothOrResults = false;
        foreach (AutomationElement element in descendants)
        {
            string name;
            try
            {
                name = UiTextNormalizer.Normalize(element.Current.Name);
            }
            catch (ElementNotAvailableException)
            {
                continue;
            }

            hasCancel |= name.Equals("Cancel", StringComparison.OrdinalIgnoreCase);
            hasBluetoothOrResults |= name.Equals("Bluetooth", StringComparison.OrdinalIgnoreCase) ||
                                     name.Contains("Show all devices", StringComparison.OrdinalIgnoreCase) ||
                                     UiTextNormalizer.ContainsMagicMouse(name);
        }

        return hasCancel && hasBluetoothOrResults;
    }

    private AutomationElement? FindSingleMagicMouseAction(AutomationElement pairingDialog)
    {
        AutomationElement contentRoot = FindPairingContentRoot(pairingDialog) ?? pairingDialog;
        List<AutomationElement> actions = [];
        foreach (AutomationElement textElement in FindMagicMouseTextElements(pairingDialog))
        {
            _elementLogger.Log("magic_mouse_text_match", textElement);
            _elementLogger.LogAncestorChain("magic_mouse_ancestor", textElement, writeConsole: false);
            AutomationElement? action = FindNearestActionableAncestor(textElement, contentRoot);
            if (action is not null)
            {
                _elementLogger.Log("magic_mouse_actionable_ancestor", action);
                actions.Add(action);
            }
        }

        AutomationElement[] unique = actions
            .GroupBy(element => string.Join(".", element.GetRuntimeId()), StringComparer.Ordinal)
            .Select(group => group.First())
            .ToArray();
        if (unique.Length > 1)
        {
            throw new InvalidOperationException(
                $"Safety stop: Windows displayed {unique.Length} actionable Magic Mouse rows; selection is ambiguous.");
        }

        return unique.SingleOrDefault();
    }

    private AutomationElement? FindSingleExactNamedMagicMouseAction(AutomationElement pairingDialog)
    {
        const string RequiredVisibleName = "Ranveer's Magic Mouse";
        AutomationElement contentRoot = FindPairingContentRoot(pairingDialog) ?? pairingDialog;
        Dictionary<string, (AutomationElement Row, AutomationElement? Action, bool HasExactName)> rows =
            new(StringComparer.Ordinal);

        foreach (AutomationElement namedElement in FindMagicMouseTextElements(pairingDialog))
        {
            AutomationElement? row = FindNearestVisibleDeviceRow(namedElement, contentRoot);
            AutomationElement? action = FindNearestFastActionableAncestor(namedElement, contentRoot);
            if (row is null)
            {
                continue;
            }

            try
            {
                if (row.Current.IsOffscreen)
                {
                    continue;
                }

                string id = string.Join(".", row.GetRuntimeId());
                bool exact = UiTextNormalizer.EqualsNormalized(namedElement.Current.Name, RequiredVisibleName);
                if (rows.TryGetValue(id, out var existing))
                {
                    rows[id] = (existing.Row, existing.Action ?? action, existing.HasExactName || exact);
                }
                else
                {
                    rows[id] = (row, action, exact);
                }
            }
            catch (ElementNotAvailableException)
            {
                // The result list changed during enumeration; the event/poll fallback will retry.
            }
        }

        if (rows.Count > 1)
        {
            throw new InvalidOperationException(
                $"Safety stop: Windows displayed {rows.Count} visible Magic Mouse rows; selection is ambiguous.");
        }

        if (rows.Count != 1)
        {
            return null;
        }

        var single = rows.Values.Single();
        return single.HasExactName && single.Action is not null ? single.Action : null;
    }

    private static AutomationElement? FindNearestVisibleDeviceRow(
        AutomationElement start,
        AutomationElement contentRoot)
    {
        AutomationElement? current = start;
        while (current is not null)
        {
            try
            {
                ControlType type = current.Current.ControlType;
                if (type == ControlType.ListItem ||
                    type == ControlType.Custom ||
                    type == ControlType.Button ||
                    type == ControlType.Pane)
                {
                    return current;
                }

                if (Automation.Compare(current, contentRoot))
                {
                    break;
                }

                current = TreeWalker.RawViewWalker.GetParent(current);
            }
            catch (ElementNotAvailableException)
            {
                return null;
            }
        }

        return null;
    }

    private static AutomationElement? FindNearestFastActionableAncestor(
        AutomationElement start,
        AutomationElement contentRoot)
    {
        AutomationElement? current = start;
        while (current is not null)
        {
            try
            {
                bool supportsFastAction = current.Current.IsEnabled &&
                                          (current.TryGetCurrentPattern(InvokePattern.Pattern, out _) ||
                                           current.TryGetCurrentPattern(SelectionItemPattern.Pattern, out _));
                if (supportsFastAction)
                {
                    return current;
                }

                if (Automation.Compare(current, contentRoot))
                {
                    break;
                }

                current = TreeWalker.RawViewWalker.GetParent(current);
            }
            catch (ElementNotAvailableException)
            {
                return null;
            }
        }

        return null;
    }

    private static IEnumerable<AutomationElement> FindMagicMouseTextElements(AutomationElement pairingDialog)
    {
        AutomationElement contentRoot = FindPairingContentRoot(pairingDialog) ?? pairingDialog;
        AutomationElementCollection descendants = contentRoot.FindAll(
            TreeScope.Descendants,
            Condition.TrueCondition);
        foreach (AutomationElement element in descendants)
        {
            string name;
            try
            {
                name = element.Current.Name;
            }
            catch (ElementNotAvailableException)
            {
                continue;
            }

            if (UiTextNormalizer.ContainsMagicMouse(name))
            {
                yield return element;
            }
        }
    }

    private static AutomationElement? FindNearestActionableAncestor(
        AutomationElement start,
        AutomationElement pairingDialog)
    {
        AutomationElement? current = start;
        while (current is not null)
        {
            if (SupportsAction(current))
            {
                return current;
            }

            if (Automation.Compare(current, pairingDialog))
            {
                break;
            }

            try
            {
                current = TreeWalker.RawViewWalker.GetParent(current);
            }
            catch (ElementNotAvailableException)
            {
                return null;
            }
        }

        return null;
    }

    private AutomationElement? FindUniqueInteractiveByName(AutomationElement root, string[] names)
    {
        List<AutomationElement> matches = [];
        AutomationElement searchRoot = FindPairingContentRoot(root) ?? root;
        AutomationElementCollection descendants = searchRoot.FindAll(TreeScope.Descendants, Condition.TrueCondition);
        foreach (AutomationElement element in descendants)
        {
            try
            {
                if (names.Any(name => UiTextNormalizer.EqualsNormalized(element.Current.Name, name)) &&
                    SupportsAction(element))
                {
                    _elementLogger.Log("interactive_name_match", element);
                    matches.Add(element);
                }
            }
            catch (ElementNotAvailableException)
            {
                // Ignore transient elements.
            }
        }

        AutomationElement[] unique = matches
            .GroupBy(element => string.Join(".", element.GetRuntimeId()), StringComparer.Ordinal)
            .Select(group => group.First())
            .ToArray();
        return unique.Length == 1 ? unique[0] : null;
    }

    private static AutomationElementCollection FindByName(AutomationElement root, string name) =>
        root.FindAll(
            TreeScope.Descendants,
            new PropertyCondition(AutomationElement.NameProperty, name, PropertyConditionFlags.IgnoreCase));

    private static bool HasPopulatedDeviceList(AutomationElement dialog)
    {
        AutomationElement contentRoot = FindPairingContentRoot(dialog) ?? dialog;
        AutomationElementCollection descendants = contentRoot.FindAll(TreeScope.Descendants, Condition.TrueCondition);
        foreach (AutomationElement element in descendants)
        {
            try
            {
                string name = UiTextNormalizer.Normalize(element.Current.Name);
                if (UiTextNormalizer.ContainsMagicMouse(name) ||
                    name.Contains("Show all devices", StringComparison.OrdinalIgnoreCase))
                {
                    return true;
                }
            }
            catch (ElementNotAvailableException)
            {
                // Ignore transient scan rows.
            }
        }

        return false;
    }

    private static bool SupportsAction(AutomationElement element)
    {
        try
        {
            return element.Current.IsEnabled &&
                   (element.TryGetCurrentPattern(InvokePattern.Pattern, out _) ||
                    element.TryGetCurrentPattern(SelectionItemPattern.Pattern, out _) ||
                    (LegacyAccessiblePattern is not null &&
                     element.TryGetCurrentPattern(LegacyAccessiblePattern, out _)));
        }
        catch (ElementNotAvailableException)
        {
            return false;
        }
    }

    private void PerformDefaultAction(AutomationElement element, string stage)
    {
        _elementLogger.Log(stage, element);
        if (element.TryGetCurrentPattern(InvokePattern.Pattern, out object invokePattern))
        {
            ((InvokePattern)invokePattern).Invoke();
            logger.Info("ui_action", $"stage={stage} pattern=InvokePattern");
            return;
        }

        if (element.TryGetCurrentPattern(SelectionItemPattern.Pattern, out object selectionPattern))
        {
            ((SelectionItemPattern)selectionPattern).Select();
            logger.Info("ui_action", $"stage={stage} pattern=SelectionItemPattern");
            return;
        }

        if (LegacyAccessiblePattern is not null &&
            element.TryGetCurrentPattern(LegacyAccessiblePattern, out object legacyPattern))
        {
            System.Reflection.MethodInfo? defaultAction = legacyPattern.GetType().GetMethod("DoDefaultAction");
            if (defaultAction is null)
            {
                throw new InvalidOperationException(
                    "LegacyIAccessiblePattern is supported, but its DoDefaultAction method is unavailable.");
            }

            defaultAction.Invoke(legacyPattern, null);
            logger.Info("ui_action", $"stage={stage} pattern=LegacyIAccessiblePattern");
            return;
        }

        throw new InvalidOperationException($"UI element for {stage} has no supported action pattern.");
    }

    private static AutomationElement? FindPairingContentRoot(AutomationElement pairingDialog)
    {
        AutomationElementCollection descendants = pairingDialog.FindAll(
            TreeScope.Descendants,
            new PropertyCondition(AutomationElement.AutomationIdProperty, "DevicesFlowFrame"));
        return descendants.Count == 1 ? descendants[0] : null;
    }

    private bool ClosePairingDialogOnly(AutomationElement pairingDialog)
    {
        try
        {
            AutomationElement? done = FindUniqueInteractiveByName(pairingDialog, ["Done"]);
            if (done is not null)
            {
                PerformDefaultAction(done, "done");
                logger.Info("window_cleanup", "pairing dialog closed via Done");
                return true;
            }

            if (UiTextNormalizer.EqualsNormalized(pairingDialog.Current.Name, "Add a device") &&
                pairingDialog.TryGetCurrentPattern(WindowPattern.Pattern, out object pattern))
            {
                ((WindowPattern)pattern).Close();
                logger.Info("window_cleanup", "pairing dialog closed via WindowPattern");
                return true;
            }

            logger.Info("window_cleanup", "pairing dialog was not open or had no safe close target");
            return false;
        }
        catch (ElementNotAvailableException)
        {
            logger.Info("window_cleanup", "pairing dialog closed before cleanup");
            return true;
        }
    }

    private async Task<bool> WaitForPairingDialogClosedAsync(CancellationToken cancellationToken)
    {
        Stopwatch elapsed = Stopwatch.StartNew();
        while (elapsed.Elapsed < TimeSpan.FromSeconds(2))
        {
            cancellationToken.ThrowIfCancellationRequested();
            if (FindAddDeviceDialog() is null)
            {
                logger.Info("window_cleanup", "pairing dialog closed");
                return true;
            }

            await Task.Delay(100, cancellationToken);
        }

        logger.Info("window_cleanup", "pairing dialog close was not confirmed within 2 seconds");
        return false;
    }

    private void CloseOwnedSettingsWindow(OperationTimeline timeline)
    {
        if (!_settingsWindowOpenedByOperation || _settingsWindowUsed is null)
        {
            logger.Info("window_cleanup", "reused existing settings window; left open");
            timeline.Mark("reused_existing_settings_window_left_open");
            return;
        }

        try
        {
            AutomationElement window = _settingsWindowUsed;
            bool isSpecificSettingsWindow =
                UiTextNormalizer.EqualsNormalized(window.Current.Name, "Settings") &&
                window.Current.ClassName.Equals("ApplicationFrameWindow", StringComparison.Ordinal) &&
                window.Current.NativeWindowHandle != 0;
            if (!isSpecificSettingsWindow ||
                !window.TryGetCurrentPattern(WindowPattern.Pattern, out object pattern))
            {
                logger.Info("window_cleanup", "settings window close skipped: tracked window failed identity check");
                return;
            }

            ((WindowPattern)pattern).Close();
            logger.Info("window_cleanup", "settings window closed");
            timeline.Mark("settings_window_closed");
        }
        catch (ElementNotAvailableException)
        {
            logger.Info("window_cleanup", "settings window already closed");
            timeline.Mark("settings_window_closed", "already_closed=true");
        }
    }

    private static HashSet<int> GetSettingsWindowHandles()
    {
        HashSet<int> handles = [];
        AutomationElementCollection windows = AutomationElement.RootElement.FindAll(
            TreeScope.Children,
            new PropertyCondition(AutomationElement.ControlTypeProperty, ControlType.Window));
        foreach (AutomationElement window in windows)
        {
            try
            {
                if (UiTextNormalizer.EqualsNormalized(window.Current.Name, "Settings") &&
                    window.Current.ClassName.Equals("ApplicationFrameWindow", StringComparison.Ordinal) &&
                    window.Current.NativeWindowHandle != 0)
                {
                    handles.Add(window.Current.NativeWindowHandle);
                }
            }
            catch (ElementNotAvailableException)
            {
                // A window closed while the pre-launch snapshot was collected.
            }
        }

        return handles;
    }

    private static int GetNativeWindowHandle(AutomationElement window)
    {
        try
        {
            return window.Current.NativeWindowHandle;
        }
        catch (ElementNotAvailableException)
        {
            return 0;
        }
    }

    private int Fail(string message)
    {
        logger.Info("pair_ui", $"failure={message}");
        Console.Error.WriteLine(message);
        return 2;
    }
}
