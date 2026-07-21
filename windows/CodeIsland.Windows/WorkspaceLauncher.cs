using System.Diagnostics;
using System.IO;
using CodeIsland.Core;

namespace CodeIsland.Windows;

public sealed record LaunchTarget(string Executable, string Arguments);

public sealed class WorkspaceLauncher
{
    public LaunchTarget? ResolveConversation(AgentKind agent, string? terminalKind, string sessionId)
    {
        if (agent != AgentKind.Codex
            || !string.Equals(terminalKind, "codex-desktop", StringComparison.OrdinalIgnoreCase)
            || string.IsNullOrWhiteSpace(sessionId)) return null;
        return new LaunchTarget($"codex://threads/{Uri.EscapeDataString(sessionId)}", string.Empty);
    }

    public bool TryLaunchConversation(AgentKind agent, string? terminalKind, string sessionId)
    {
        var target = ResolveConversation(agent, terminalKind, sessionId);
        if (target is null) return false;
        Process.Start(new ProcessStartInfo(target.Executable) { UseShellExecute = true });
        return true;
    }

    public LaunchTarget? Resolve(AgentKind agent, string? terminalKind, string workingDirectory, string? path = null)
    {
        if (!Directory.Exists(workingDirectory)) return null;
        var preferred = agent == AgentKind.Cursor
            ? new[] { "cursor.exe", "cursor.cmd", "code.exe", "code.cmd", "wt.exe" }
            : terminalKind?.Contains("terminal", StringComparison.OrdinalIgnoreCase) == true
                ? new[] { "wt.exe", "code.exe", "code.cmd" }
                : new[] { "code.exe", "code.cmd", "cursor.exe", "cursor.cmd", "wt.exe" };
        var executable = FindExecutable(preferred, path ?? Environment.GetEnvironmentVariable("PATH"));
        if (executable is null) return null;
        var arguments = Path.GetFileName(executable).Equals("wt.exe", StringComparison.OrdinalIgnoreCase)
            ? $"-d \"{Path.GetFullPath(workingDirectory)}\""
            : $"\"{Path.GetFullPath(workingDirectory)}\"";
        return new LaunchTarget(executable, arguments);
    }

    public bool TryLaunch(AgentKind agent, string? terminalKind, string? workingDirectory)
    {
        if (string.IsNullOrWhiteSpace(workingDirectory)) return false;
        var target = Resolve(agent, terminalKind, workingDirectory);
        if (target is null) return false;
        Process.Start(new ProcessStartInfo(target.Executable, target.Arguments) { UseShellExecute = true });
        return true;
    }

    private static string? FindExecutable(IEnumerable<string> names, string? path)
    {
        foreach (var directory in (path ?? string.Empty).Split(Path.PathSeparator,
                     StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries))
            foreach (var name in names)
            {
                var candidate = Path.Combine(directory, name);
                if (File.Exists(candidate)) return candidate;
            }
        return null;
    }
}
