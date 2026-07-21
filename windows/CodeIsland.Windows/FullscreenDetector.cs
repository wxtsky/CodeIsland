using System.Drawing;
using System.Runtime.InteropServices;
using System.Runtime.Versioning;

namespace CodeIsland.Windows;

[SupportedOSPlatform("windows")]
public static class FullscreenDetector
{
    public static bool IsFullscreenForeground(IntPtr ignoredWindow)
    {
        var foreground = GetForegroundWindow();
        if (foreground == IntPtr.Zero || foreground == ignoredWindow) return false;
        if (IsShellSurface(foreground)) return false;
        if (!GetWindowRect(foreground, out var window)) return false;
        var monitor = MonitorFromWindow(foreground, MonitorDefaultToNearest);
        var ignoredMonitor = MonitorFromWindow(ignoredWindow, MonitorDefaultToNearest);
        if (monitor == IntPtr.Zero || ignoredMonitor == IntPtr.Zero || monitor != ignoredMonitor) return false;
        var info = new MonitorInfo { Size = Marshal.SizeOf<MonitorInfo>() };
        if (!NativeGetMonitorInfo(monitor, ref info)) return false;
        return IsSameBounds(ToRectangle(window), ToRectangle(info.Monitor));
    }

    public static bool IsSameBounds(Rectangle window, Rectangle monitor) =>
        window.Left <= monitor.Left && window.Top <= monitor.Top
        && window.Right >= monitor.Right && window.Bottom >= monitor.Bottom;

    private const uint MonitorDefaultToNearest = 2;
    private static bool IsShellSurface(IntPtr window)
    {
        if (window == GetShellWindow()) return true;
        var className = new System.Text.StringBuilder(64);
        if (GetClassName(window, className, className.Capacity) == 0) return false;
        return className.ToString() is "Progman" or "WorkerW" or "Shell_TrayWnd";
    }

    [StructLayout(LayoutKind.Sequential)] private struct NativeRect { public int Left, Top, Right, Bottom; }
    [StructLayout(LayoutKind.Sequential)] private struct MonitorInfo
    {
        public int Size;
        public NativeRect Monitor;
        public NativeRect Work;
        public uint Flags;
    }
    [DllImport("user32.dll")] private static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] private static extern IntPtr GetShellWindow();
    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    private static extern int GetClassName(IntPtr handle, System.Text.StringBuilder className, int maxCount);
    [DllImport("user32.dll")] private static extern bool GetWindowRect(IntPtr handle, out NativeRect rect);
    [DllImport("user32.dll")] private static extern IntPtr MonitorFromWindow(IntPtr handle, uint flags);
    [DllImport("user32.dll", CharSet = CharSet.Unicode, EntryPoint = "GetMonitorInfoW")]
    private static extern bool NativeGetMonitorInfo(IntPtr monitor, ref MonitorInfo info);
    private static Rectangle ToRectangle(NativeRect rect) =>
        Rectangle.FromLTRB(rect.Left, rect.Top, rect.Right, rect.Bottom);
}
