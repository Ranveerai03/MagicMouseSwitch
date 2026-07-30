using System.Runtime.InteropServices;
using System.Windows.Interop;

namespace MagicMouseSwitch.Tray;

internal sealed class GlobalHotKey : IDisposable
{
    private const int HotKeyMessage = 0x0312;
    private const uint ControlModifier = 0x0002;
    private const uint ShiftModifier = 0x0004;
    private const uint NoRepeatModifier = 0x4000;
    private const uint MKey = 0x4D;
    private const int HotKeyId = 0x4D4D;

    private readonly HwndSource _source;

    internal GlobalHotKey(Action callback)
    {
        HwndSourceParameters parameters = new("MagicMouseSwitch.HotKey")
        {
            Width = 0,
            Height = 0,
            WindowStyle = unchecked((int)0x80000000),
            ExtendedWindowStyle = 0x00000080
        };
        _source = new HwndSource(parameters);
        _source.AddHook(WindowProcedure);

        if (!RegisterHotKey(
                _source.Handle,
                HotKeyId,
                ControlModifier | ShiftModifier | NoRepeatModifier,
                MKey))
        {
            _source.Dispose();
            throw new InvalidOperationException("Ctrl+Shift+M is already registered by another application.");
        }

        IntPtr WindowProcedure(
            IntPtr window,
            int message,
            IntPtr wParam,
            IntPtr lParam,
            ref bool handled)
        {
            if (message == HotKeyMessage && wParam.ToInt32() == HotKeyId)
            {
                handled = true;
                callback();
            }

            return IntPtr.Zero;
        }
    }

    public void Dispose()
    {
        UnregisterHotKey(_source.Handle, HotKeyId);
        _source.Dispose();
    }

    [DllImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool RegisterHotKey(IntPtr window, int id, uint modifiers, uint virtualKey);

    [DllImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool UnregisterHotKey(IntPtr window, int id);
}
