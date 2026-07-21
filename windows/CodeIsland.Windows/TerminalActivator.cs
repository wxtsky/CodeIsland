using System.Runtime.InteropServices;
using System.Runtime.Versioning;
using System.Text;
using System.IO;

namespace CodeIsland.Windows;

public sealed record WindowInfo(IntPtr Handle, int ProcessId, string Title);

[SupportedOSPlatform("windows")]
public sealed class TerminalActivator
{
    private const int Restore = 9;

    public IReadOnlyList<WindowInfo> EnumerateWindows()
    {
        var windows = new List<WindowInfo>();
        EnumWindows((handle, _) =>
        {
            if (!IsWindowVisible(handle)) return true;
            var length = GetWindowTextLength(handle);
            if (length <= 0) return true;
            var title = new StringBuilder(length + 1);
            GetWindowText(handle, title, title.Capacity);
            GetWindowThreadProcessId(handle, out var processId);
            windows.Add(new WindowInfo(handle, unchecked((int)processId), title.ToString()));
            return true;
        }, IntPtr.Zero);
        return windows;
    }

    public bool TryActivate(int? processId, string? workingDirectory = null)
    {
        var windows = EnumerateWindows();
        var candidate = windows.FirstOrDefault(window =>
            processId is not null && window.ProcessId == processId.Value);
        candidate ??= windows.FirstOrDefault(window =>
            WindowMatcher.TitleMatchesWorkingDirectory(window.Title, workingDirectory));
        if (candidate is null) return false;
        ShowWindow(candidate.Handle, Restore);
        return SetForegroundWindow(candidate.Handle);
    }

    private delegate bool EnumWindowsProc(IntPtr handle, IntPtr parameter);

    [DllImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool EnumWindows(EnumWindowsProc callback, IntPtr parameter);
    [DllImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool IsWindowVisible(IntPtr handle);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    private static extern int GetWindowText(IntPtr handle, StringBuilder text, int count);
    [DllImport("user32.dll")]
    private static extern int GetWindowTextLength(IntPtr handle);
    [DllImport("user32.dll")]
    private static extern uint GetWindowThreadProcessId(IntPtr handle, out uint processId);
    [DllImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool ShowWindow(IntPtr handle, int command);
    [DllImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool SetForegroundWindow(IntPtr handle);
}

public static class WindowMatcher
{
    public static bool TitleMatchesWorkingDirectory(string? title, string? workingDirectory)
    {
        if (string.IsNullOrWhiteSpace(title) || string.IsNullOrWhiteSpace(workingDirectory)) return false;
        var directoryName = Path.GetFileName(Path.TrimEndingDirectorySeparator(workingDirectory));
        return !string.IsNullOrWhiteSpace(directoryName)
            && title.Contains(directoryName, StringComparison.OrdinalIgnoreCase);
    }
}
