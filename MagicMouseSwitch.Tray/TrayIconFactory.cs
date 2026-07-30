using System.Drawing;
using System.Drawing.Drawing2D;
using System.Runtime.InteropServices;

namespace MagicMouseSwitch.Tray;

internal static class TrayIconFactory
{
    internal static Icon Create()
    {
        using Bitmap bitmap = new(32, 32);
        using Graphics graphics = Graphics.FromImage(bitmap);
        graphics.SmoothingMode = SmoothingMode.AntiAlias;
        graphics.Clear(Color.Transparent);
        using SolidBrush background = new(Color.FromArgb(48, 54, 66));
        using Pen outline = new(Color.White, 2.2f)
        {
            StartCap = LineCap.Round,
            EndCap = LineCap.Round
        };
        using SolidBrush wheel = new(Color.White);

        graphics.FillEllipse(background, 1, 1, 30, 30);
        graphics.DrawRoundedRectangle(outline, new RectangleF(9, 5, 14, 22), 7);
        graphics.DrawLine(outline, 16, 6, 16, 13);
        graphics.FillEllipse(wheel, 15, 8, 2, 4);

        IntPtr handle = bitmap.GetHicon();
        try
        {
            using Icon temporary = Icon.FromHandle(handle);
            return (Icon)temporary.Clone();
        }
        finally
        {
            DestroyIcon(handle);
        }
    }

    private static void DrawRoundedRectangle(
        this Graphics graphics,
        Pen pen,
        RectangleF bounds,
        float radius)
    {
        float diameter = radius * 2;
        using GraphicsPath path = new();
        path.AddArc(bounds.Left, bounds.Top, diameter, diameter, 180, 90);
        path.AddArc(bounds.Right - diameter, bounds.Top, diameter, diameter, 270, 90);
        path.AddArc(bounds.Right - diameter, bounds.Bottom - diameter, diameter, diameter, 0, 90);
        path.AddArc(bounds.Left, bounds.Bottom - diameter, diameter, diameter, 90, 90);
        path.CloseFigure();
        graphics.DrawPath(pen, path);
    }

    [DllImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool DestroyIcon(IntPtr icon);
}
