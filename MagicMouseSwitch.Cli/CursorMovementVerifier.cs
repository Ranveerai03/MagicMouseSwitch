using System.Runtime.InteropServices;

namespace MagicMouseSwitch.Cli;

internal static class CursorMovementVerifier
{
    internal static async Task<bool> WaitAsync(TimeSpan timeout, CancellationToken cancellationToken)
    {
        if (!GetCursorPos(out Point initial))
        {
            return false;
        }

        DateTime deadline = DateTime.UtcNow + timeout;
        while (DateTime.UtcNow < deadline)
        {
            await Task.Delay(100, cancellationToken);
            if (GetCursorPos(out Point current) && (current.X != initial.X || current.Y != initial.Y))
            {
                return true;
            }
        }

        return false;
    }

    [DllImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool GetCursorPos(out Point point);

    [StructLayout(LayoutKind.Sequential)]
    private struct Point
    {
        internal int X;
        internal int Y;
    }
}
