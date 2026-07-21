using Microsoft.Win32;
using System.IO;

namespace CodeIsland.Windows;

public sealed class StartupRegistration
{
    private const string RunKeyPath = @"Software\Microsoft\Windows\CurrentVersion\Run";
    private const string ValueName = "CodeIsland";

    public static string BuildCommand(string executablePath) => $"\"{Path.GetFullPath(executablePath)}\"";

    public bool IsEnabled()
    {
        using var key = Registry.CurrentUser.OpenSubKey(RunKeyPath, writable: false);
        return key?.GetValue(ValueName) is string;
    }

    public void SetEnabled(bool enabled, string executablePath)
    {
        using var key = Registry.CurrentUser.CreateSubKey(RunKeyPath);
        if (key is null) throw new InvalidOperationException("Unable to open the current-user startup registry key.");
        if (enabled) key.SetValue(ValueName, BuildCommand(executablePath));
        else key.DeleteValue(ValueName, throwOnMissingValue: false);
    }
}
