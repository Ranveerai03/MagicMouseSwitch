using System.Runtime.InteropServices;
using System.Windows.Automation;

namespace MagicMouseSwitch.Cli;

internal static class WindowForeground
{
    private const int Restore = 9;

    internal static bool TryBringToForeground(AutomationElement window)
    {
        int handle;
        try
        {
            handle = window.Current.NativeWindowHandle;
        }
        catch (ElementNotAvailableException)
        {
            return false;
        }

        if (handle == 0)
        {
            return false;
        }

        IntPtr nativeHandle = new(handle);
        ShowWindowAsync(nativeHandle, Restore);
        return SetForegroundWindow(nativeHandle);
    }

    [DllImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool SetForegroundWindow(IntPtr window);

    [DllImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool ShowWindowAsync(IntPtr window, int command);
}
