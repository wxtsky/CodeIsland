using System.IO;
using System.IO.Compression;
using System.Text;
using System.Text.Json;
using CodeIsland.Hooks;

namespace CodeIsland.Windows;

public sealed class DiagnosticsExporter
{
    public void Export(string destinationPath, AppSettings settings, DesktopSessionStore sessions, string logDirectory)
    {
        Directory.CreateDirectory(Path.GetDirectoryName(Path.GetFullPath(destinationPath))!);
        using var file = File.Create(destinationPath);
        using var archive = new ZipArchive(file, ZipArchiveMode.Create);
        var hooks = DetectHooksSafely();
        var summary = new
        {
            generatedAtUtc = DateTimeOffset.UtcNow,
            applicationVersion = "0.1.0",
            operatingSystem = Environment.OSVersion.VersionString,
            runtime = Environment.Version.ToString(),
            processArchitecture = System.Runtime.InteropServices.RuntimeInformation.ProcessArchitecture.ToString(),
            settings = settings with { LaunchAtLogin = false },
            visibleSessionCount = sessions.SessionCount,
            eventHistoryCount = sessions.EventHistory.Count,
            hooks
        };
        WriteEntry(archive, "diagnostics.json", JsonSerializer.Serialize(summary,
            new JsonSerializerOptions(JsonSerializerDefaults.Web) { WriteIndented = true }));
        if (!Directory.Exists(logDirectory)) return;
        foreach (var log in Directory.GetFiles(logDirectory, "codeisland.log*"))
            WriteEntry(archive, $"logs/{Path.GetFileName(log)}", SensitiveDataRedactor.Redact(File.ReadAllText(log)));
    }

    private static object[] DetectHooksSafely()
    {
        try
        {
            return new ToolDetector().DetectAll().Select(status => (object)new
            {
                tool = status.Tool.DisplayName,
                executableFound = status.ExecutablePath is not null,
                status.HookInstalled,
                status.IsHealthy,
                status.Problem
            }).ToArray();
        }
        catch (Exception ex) when (ex is IOException or JsonException or UnauthorizedAccessException)
        {
            return [new { tool = "unavailable", error = SensitiveDataRedactor.Redact(ex.Message) }];
        }
    }

    private static void WriteEntry(ZipArchive archive, string name, string content)
    {
        var entry = archive.CreateEntry(name, CompressionLevel.Optimal);
        using var writer = new StreamWriter(entry.Open(), new UTF8Encoding(false));
        writer.Write(content);
    }
}
