using Microsoft.Win32;
using System.Runtime.InteropServices;
using System.Windows;
using System.Windows.Input;
using System.Windows.Interop;
using System.Windows.Media;
using System.Windows.Media.Animation;
using MediaBrush = System.Windows.Media.Brush;
using MediaColor = System.Windows.Media.Color;

namespace MagicMouseSwitch.Tray;

internal enum PopupOutcome
{
    Active,
    Success,
    Failure
}

public partial class PopupWindow : Window
{
    private const int ExtendedStyleIndex = -20;
    private const int ToolWindowStyle = 0x00000080;
    private const int NoActivateStyle = 0x08000000;
    private CancellationTokenSource? _dismissal;
    private long _generation;

    public PopupWindow()
    {
        InitializeComponent();
        SourceInitialized += OnSourceInitialized;
    }

    internal void ShowStatus(string status, PopupOutcome outcome, string? battery = null)
    {
        if (!Dispatcher.CheckAccess())
        {
            Dispatcher.Invoke(() => ShowStatus(status, outcome, battery));
            return;
        }

        ApplyWindowsTheme();
        StatusText.Text = status;
        BatteryText.Text = battery ?? string.Empty;
        BatteryText.Visibility = string.IsNullOrWhiteSpace(battery)
            ? Visibility.Collapsed
            : Visibility.Visible;
        PositionAbovePrimaryTaskbar();

        _dismissal?.Cancel();
        _dismissal?.Dispose();
        _dismissal = new CancellationTokenSource();
        long generation = Interlocked.Increment(ref _generation);

        DismissProgress.BeginAnimation(System.Windows.Controls.Primitives.RangeBase.ValueProperty, null);
        DismissProgress.IsIndeterminate = outcome == PopupOutcome.Active;
        DismissProgress.Value = 100;

        if (!IsVisible)
        {
            Opacity = 0;
            SlideTransform.Y = 18;
            Show();
            AnimateIn();
        }
        else if (Opacity < 1)
        {
            AnimateIn();
        }

        if (outcome != PopupOutcome.Active)
        {
            TimeSpan visibleFor = outcome == PopupOutcome.Success
                ? TimeSpan.FromSeconds(3)
                : TimeSpan.FromSeconds(6);
            _ = DismissAfterAsync(visibleFor, generation, _dismissal.Token);
        }
    }

    internal void Dismiss()
    {
        if (!Dispatcher.CheckAccess())
        {
            Dispatcher.Invoke(Dismiss);
            return;
        }

        _dismissal?.Cancel();
        AnimateOut();
    }

    private async Task DismissAfterAsync(TimeSpan delay, long generation, CancellationToken cancellationToken)
    {
        DismissProgress.IsIndeterminate = false;
        DoubleAnimation countdown = new(100, 0, delay) { FillBehavior = FillBehavior.HoldEnd };
        DismissProgress.BeginAnimation(System.Windows.Controls.Primitives.RangeBase.ValueProperty, countdown);
        try
        {
            await Task.Delay(delay, cancellationToken);
            if (generation == Interlocked.Read(ref _generation))
            {
                AnimateOut();
            }
        }
        catch (OperationCanceledException)
        {
            // A newer state replaced this dismissal schedule.
        }
    }

    private void AnimateIn()
    {
        BeginAnimation(OpacityProperty, new DoubleAnimation(1, TimeSpan.FromMilliseconds(180)));
        SlideTransform.BeginAnimation(
            TranslateTransform.YProperty,
            new DoubleAnimation(0, TimeSpan.FromMilliseconds(220))
            {
                EasingFunction = new CubicEase { EasingMode = EasingMode.EaseOut }
            });
    }

    private void AnimateOut()
    {
        DoubleAnimation fade = new(0, TimeSpan.FromMilliseconds(170));
        fade.Completed += (_, _) => Hide();
        BeginAnimation(OpacityProperty, fade);
        SlideTransform.BeginAnimation(
            TranslateTransform.YProperty,
            new DoubleAnimation(12, TimeSpan.FromMilliseconds(170))
            {
                EasingFunction = new CubicEase { EasingMode = EasingMode.EaseIn }
            });
    }

    private void PositionAbovePrimaryTaskbar()
    {
        Rect workArea = SystemParameters.WorkArea;
        Left = workArea.Left + ((workArea.Width - Width) / 2);
        Top = workArea.Bottom - Height - 18;
    }

    private void ApplyWindowsTheme()
    {
        bool light = true;
        try
        {
            object? value = Registry.GetValue(
                @"HKEY_CURRENT_USER\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize",
                "AppsUseLightTheme",
                1);
            light = Convert.ToInt32(value) != 0;
        }
        catch
        {
            // Use the light palette if theme discovery is unavailable.
        }

        Card.Background = new SolidColorBrush(light
            ? MediaColor.FromArgb(248, 250, 250, 252)
            : MediaColor.FromArgb(248, 31, 31, 34));
        Card.BorderBrush = new SolidColorBrush(light
            ? MediaColor.FromRgb(222, 224, 229)
            : MediaColor.FromRgb(66, 66, 72));
        Card.BorderThickness = new Thickness(1);
        TitleText.Foreground = new SolidColorBrush(light
            ? MediaColor.FromRgb(28, 28, 30)
            : MediaColor.FromRgb(245, 245, 247));
        StatusText.Foreground = new SolidColorBrush(light
            ? MediaColor.FromRgb(92, 92, 98)
            : MediaColor.FromRgb(174, 174, 181));
        BatteryText.Foreground = StatusText.Foreground;
        IconPlate.Background = new SolidColorBrush(light
            ? MediaColor.FromRgb(235, 238, 244)
            : MediaColor.FromRgb(48, 48, 53));
        MediaBrush icon = new SolidColorBrush(light
            ? MediaColor.FromRgb(48, 48, 53)
            : MediaColor.FromRgb(236, 236, 240));
        MouseOutline.Stroke = icon;
        ScrollMark.Fill = icon;
        DismissProgress.Foreground = new SolidColorBrush(MediaColor.FromRgb(92, 124, 250));
        DismissProgress.Background = new SolidColorBrush(light
            ? MediaColor.FromRgb(218, 220, 226)
            : MediaColor.FromRgb(64, 64, 69));
    }

    private void OnSourceInitialized(object? sender, EventArgs eventArgs)
    {
        IntPtr handle = new WindowInteropHelper(this).Handle;
        int styles = GetWindowLong(handle, ExtendedStyleIndex);
        SetWindowLong(handle, ExtendedStyleIndex, styles | ToolWindowStyle | NoActivateStyle);
    }

    private void Card_MouseLeftButtonUp(object sender, MouseButtonEventArgs e) => Dismiss();

    [DllImport("user32.dll", EntryPoint = "GetWindowLongW")]
    private static extern int GetWindowLong(IntPtr window, int index);

    [DllImport("user32.dll", EntryPoint = "SetWindowLongW")]
    private static extern int SetWindowLong(IntPtr window, int index, int newValue);
}
