using MagicMouseSwitch.Cli;
using System.Diagnostics;
using System.IO;
using System.Windows;
using Forms = System.Windows.Forms;

namespace MagicMouseSwitch.Tray;

public partial class App : System.Windows.Application
{
    internal const string InstanceMutexName = @"Local\RanveerRai.MagicMouseSwitch.Tray.v1";

    private readonly CancellationTokenSource _lifetime = new();
    private Mutex? _instanceMutex;
    private bool _ownsInstanceMutex;
    private Forms.NotifyIcon? _notifyIcon;
    private Forms.ToolStripMenuItem? _startupItem;
    private Forms.ToolStripMenuItem? _hotKeyStatusItem;
    private GlobalHotKey? _hotKey;
    private PopupWindow? _popup;
    private OperationLogger? _logger;
    private EndpointDiscovery? _discovery;
    private ConfigStore? _configStore;
    private MagicMouseOperations? _operations;
    private WindowsSettingsPairer? _pairer;
    private int _operationActive;

    protected override async void OnStartup(StartupEventArgs e)
    {
        base.OnStartup(e);
        try
        {
            _logger = new OperationLogger();
            RegisterUnhandledExceptionLogging();

            if (HandleStartupCommand(e.Args))
            {
                Shutdown();
                return;
            }

            _instanceMutex = new Mutex(initiallyOwned: true, InstanceMutexName, out bool createdNew);
            if (!createdNew)
            {
                _logger.Info("tray", "startup_cancelled=instance_already_running");
                Shutdown();
                return;
            }

            _ownsInstanceMutex = true;
            _discovery = new EndpointDiscovery(_logger);
            _configStore = new ConfigStore();
            MagicMouseConfig? config = await _configStore.LoadAsync(_lifetime.Token);
            _logger.Info(
                "tray",
                $"config_ready={config is not null} path={AppDataPaths.ConfigPath}");
            _operations = new MagicMouseOperations(_discovery, _configStore, _logger);
            _pairer = new WindowsSettingsPairer(_discovery, _logger, _configStore);
            _popup = new PopupWindow();

            CreateTrayIcon();
            try
            {
                _hotKey = new GlobalHotKey(() => _ = RunExclusiveAsync(ToggleAsync));
                _logger.Info("tray", "global_hotkey_registered=Ctrl+Shift+M");
            }
            catch (Exception exception)
            {
                _logger.Error("tray_hotkey", exception);
                if (_hotKeyStatusItem is not null)
                {
                    _hotKeyStatusItem.Text = "Hotkey unavailable — Ctrl+Shift+M is in use";
                }

                _notifyIcon!.Text = "Magic Mouse Switch — hotkey unavailable";
                _popup.ShowStatus(
                    "Ctrl+Shift+M could not be registered because it is already in use",
                    PopupOutcome.Failure);
            }
        }
        catch (Exception exception)
        {
            TryLogStartupFailure(exception);
            System.Windows.MessageBox.Show(
                $"Magic Mouse Switch could not start.\n\n{exception.Message}\n\nSee the LocalAppData logs for details.",
                "Magic Mouse Switch",
                MessageBoxButton.OK,
                MessageBoxImage.Error);
            Shutdown(-1);
        }
    }

    private void CreateTrayIcon()
    {
        Forms.ContextMenuStrip menu = new();
        _hotKeyStatusItem = new Forms.ToolStripMenuItem("Hotkey: Ctrl+Shift+M")
        {
            Enabled = false
        };
        menu.Items.Add(_hotKeyStatusItem);
        menu.Items.Add(new Forms.ToolStripSeparator());
        menu.Items.Add("Connect Magic Mouse", null, (_, _) =>
            Dispatcher.InvokeAsync(() => _ = RunExclusiveAsync(ConnectAsync)));
        menu.Items.Add("Disconnect Magic Mouse", null, (_, _) =>
            Dispatcher.InvokeAsync(() => _ = RunExclusiveAsync(DisconnectAsync)));
        menu.Items.Add("Status", null, (_, _) =>
            Dispatcher.InvokeAsync(() => _ = ShowStatusAsync()));
        menu.Items.Add(new Forms.ToolStripSeparator());
        _startupItem = new Forms.ToolStripMenuItem("Start with Windows")
        {
            CheckOnClick = false,
            Checked = StartupRegistration.IsEnabled()
        };
        _startupItem.Click += (_, _) => Dispatcher.Invoke(ToggleStartup);
        menu.Items.Add(_startupItem);
        menu.Items.Add("Open logs", null, (_, _) => Dispatcher.Invoke(OpenLogs));
        menu.Items.Add("Diagnostic connect test", null, (_, _) =>
            Dispatcher.InvokeAsync(() => _ = RunExclusiveAsync(DiagnosticConnectAsync)));
        menu.Items.Add(new Forms.ToolStripSeparator());
        menu.Items.Add("Exit", null, (_, _) => Dispatcher.Invoke(ExitApplication));
        menu.Opening += (_, _) =>
        {
            if (_startupItem is not null)
            {
                _startupItem.Checked = StartupRegistration.IsEnabled();
            }
        };

        _notifyIcon = new Forms.NotifyIcon
        {
            Icon = TrayIconFactory.Create(),
            Text = "Magic Mouse Switch — Ctrl+Shift+M",
            ContextMenuStrip = menu,
            Visible = true
        };
        _notifyIcon.DoubleClick += (_, _) => Dispatcher.InvokeAsync(() => _ = ShowStatusAsync());
    }

    private async Task RunExclusiveAsync(Func<Task> operation)
    {
        if (Interlocked.CompareExchange(ref _operationActive, 1, 0) != 0)
        {
            _logger?.Info("tray", "operation_ignored=already_running");
            return;
        }

        try
        {
            await operation();
        }
        catch (OperationCanceledException) when (_lifetime.IsCancellationRequested)
        {
            // Application is exiting.
        }
        catch (Exception exception)
        {
            _logger?.Error("tray_operation", exception);
            _popup?.ShowStatus($"Pairing failed — {exception.Message}", PopupOutcome.Failure);
        }
        finally
        {
            Interlocked.Exchange(ref _operationActive, 0);
        }
    }

    private async Task ToggleAsync()
    {
        MouseConnectionState state = await RequireOperations().GetStateAsync(_lifetime.Token);
        if (state is MouseConnectionState.Connected or MouseConnectionState.PairedDisconnected)
        {
            await DisconnectAsync();
        }
        else if (state is MouseConnectionState.Unpaired or MouseConnectionState.Unknown)
        {
            await ConnectAsync();
        }
    }

    private async Task ConnectAsync() => await ConnectCoreAsync(requireCursorMovement: false);

    private async Task DiagnosticConnectAsync() => await ConnectCoreAsync(requireCursorMovement: true);

    private async Task ConnectCoreAsync(bool requireCursorMovement)
    {
        IProgress<MouseOperationProgress> progress = new Progress<MouseOperationProgress>(ShowProgress);
        int result = await RequirePairer().PairAsync(
            _lifetime.Token,
            strictAddressBeforeClick: false,
            sharedTimeline: null,
            printTimingSummary: false,
            requireCursorMovement: requireCursorMovement,
            progress: progress);
        if (result == 0)
        {
            return;
        }

        if (result == 7)
        {
            _popup?.ShowStatus("Safety verification failed", PopupOutcome.Failure);
        }
        else
        {
            _popup?.ShowStatus("Pairing failed", PopupOutcome.Failure);
        }
    }

    private async Task DisconnectAsync()
    {
        OperationTimeline timeline = new(RequireLogger());
        IProgress<MouseOperationProgress> progress = new Progress<MouseOperationProgress>(ShowProgress);
        DisconnectResult result = await RequireOperations().DisconnectAsync(
            timeline,
            progress,
            _lifetime.Token);
        if (!result.Success)
        {
            _popup?.ShowStatus(result.Message, PopupOutcome.Failure);
        }
    }

    private async Task ShowStatusAsync()
    {
        MouseConnectionState state = await RequireOperations().GetStateAsync(_lifetime.Token);
        (string text, PopupOutcome outcome) = state switch
        {
            MouseConnectionState.Connected => ("Magic Mouse connected", PopupOutcome.Success),
            MouseConnectionState.PairedDisconnected => ("Click the mouse to wake it", PopupOutcome.Success),
            MouseConnectionState.Unpaired => ("Magic Mouse disconnected", PopupOutcome.Success),
            _ => ("Unable to resolve Magic Mouse status", PopupOutcome.Failure)
        };
        _popup?.ShowStatus(text, outcome);
    }

    private void ShowProgress(MouseOperationProgress progress)
    {
        PopupOutcome outcome = progress.Kind switch
        {
            MouseOperationProgressKind.Connected or MouseOperationProgressKind.Disconnected => PopupOutcome.Success,
            MouseOperationProgressKind.PairingFailed or MouseOperationProgressKind.SafetyFailure => PopupOutcome.Failure,
            _ => PopupOutcome.Active
        };
        _popup?.ShowStatus(progress.Message, outcome);
    }

    private void ToggleStartup()
    {
        bool enabled = !StartupRegistration.IsEnabled();
        StartupRegistration.SetEnabled(enabled);
        if (_startupItem is not null)
        {
            _startupItem.Checked = enabled;
        }

        _logger?.Info("tray", $"start_with_windows={enabled}");
    }

    private void OpenLogs()
    {
        string directory = Path.GetDirectoryName(RequireLogger().LogPath)!;
        Directory.CreateDirectory(directory);
        Process.Start(new ProcessStartInfo("explorer.exe", $"\"{directory}\"")
        {
            UseShellExecute = true
        });
    }

    private void ExitApplication()
    {
        Shutdown();
    }

    protected override void OnExit(ExitEventArgs e)
    {
        _lifetime.Cancel();
        _hotKey?.Dispose();
        _hotKey = null;
        if (_notifyIcon is not null)
        {
            _notifyIcon.Visible = false;
            _notifyIcon.Dispose();
            _notifyIcon = null;
        }

        _popup?.Close();
        _popup = null;
        if (_ownsInstanceMutex)
        {
            _instanceMutex?.ReleaseMutex();
            _ownsInstanceMutex = false;
        }

        _instanceMutex?.Dispose();
        _instanceMutex = null;
        base.OnExit(e);
    }

    private bool HandleStartupCommand(IReadOnlyList<string> arguments)
    {
        if (arguments.Count != 1)
        {
            return false;
        }

        switch (arguments[0].ToLowerInvariant())
        {
            case "--enable-startup":
                StartupRegistration.SetEnabled(true);
                _logger?.Info("tray", "startup_command=enable success=true");
                return true;
            case "--disable-startup":
                StartupRegistration.SetEnabled(false);
                _logger?.Info("tray", "startup_command=disable success=true");
                return true;
            default:
                return false;
        }
    }

    private void RegisterUnhandledExceptionLogging()
    {
        DispatcherUnhandledException += (_, args) =>
            _logger?.Error("tray_dispatcher_unhandled", args.Exception);
        AppDomain.CurrentDomain.UnhandledException += (_, args) =>
        {
            if (args.ExceptionObject is Exception exception)
            {
                _logger?.Error("tray_appdomain_unhandled", exception);
            }
        };
        TaskScheduler.UnobservedTaskException += (_, args) =>
            _logger?.Error("tray_task_unobserved", args.Exception);
    }

    private void TryLogStartupFailure(Exception exception)
    {
        try
        {
            if (_logger is not null)
            {
                _logger.Error("tray_startup", exception);
                return;
            }

            Directory.CreateDirectory(AppDataPaths.LogsDirectory);
            string path = Path.Combine(
                AppDataPaths.LogsDirectory,
                $"magic-mouse-switch-{DateTime.Now:yyyyMMdd}.log");
            File.AppendAllText(
                path,
                $"{DateTimeOffset.Now:O} [ERROR] operation=tray_startup {exception}\n");
        }
        catch
        {
            // No secondary startup error can be surfaced more reliably than the dialog below.
        }
    }

    private MagicMouseOperations RequireOperations() =>
        _operations ?? throw new InvalidOperationException("Operations are not initialized.");

    private WindowsSettingsPairer RequirePairer() =>
        _pairer ?? throw new InvalidOperationException("Pairer is not initialized.");

    private OperationLogger RequireLogger() =>
        _logger ?? throw new InvalidOperationException("Logger is not initialized.");
}
