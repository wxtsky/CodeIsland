using System.Drawing;
using System.Windows.Forms;

namespace CodeIsland.Windows;

public static class DisplayPositioner
{
    public static Rectangle SelectWorkingArea(string mode)
    {
        var screen = mode.Equals("cursor", StringComparison.OrdinalIgnoreCase)
            ? Screen.FromPoint(Cursor.Position)
            : Screen.PrimaryScreen;
        return screen?.WorkingArea ?? new Rectangle(0, 0, 1920, 1080);
    }

    public static Rectangle WorkingAreaForWindow(IntPtr windowHandle) =>
        windowHandle == IntPtr.Zero
            ? Screen.PrimaryScreen?.WorkingArea ?? new Rectangle(0, 0, 1920, 1080)
            : Screen.FromHandle(windowHandle).WorkingArea;

    public static (double Left, double Top) TopCenter(Rectangle workingAreaPixels,
        double dpiScaleX, double dpiScaleY, double widthDip, double topDip = 14)
    {
        if (dpiScaleX <= 0 || dpiScaleY <= 0) throw new ArgumentOutOfRangeException(nameof(dpiScaleX));
        var left = workingAreaPixels.Left / dpiScaleX
            + (workingAreaPixels.Width / dpiScaleX - widthDip) / 2;
        var top = workingAreaPixels.Top / dpiScaleY + topDip;
        return (left, top);
    }
}
