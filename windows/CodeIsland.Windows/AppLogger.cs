using System.IO;
using System.Text.RegularExpressions;

namespace CodeIsland.Windows;

public sealed class AppLogger
{
    private readonly object _gate = new();
    private string _filePath;
    private readonly long _maxBytes;
    public string LogDirectory => Path.GetDirectoryName(_filePath)!;

    public AppLogger(string? rootDirectory = null, long maxBytes = 1_000_000)
    {
        rootDirectory ??= Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
            "CodeIsland", "logs");
        _filePath = CreateLogPath(rootDirectory);
        _maxBytes = maxBytes;
    }

    public void Info(string message) => Write("INFO", message);
    public void Error(string message, Exception? exception = null) =>
        Write("ERROR", exception is null ? message : $"{message}: {exception.GetType().Name}: {exception.Message}");

    private void Write(string level, string message)
    {
        lock (_gate)
        {
            var line = $"{DateTimeOffset.UtcNow:O} [{level}] {SensitiveDataRedactor.Redact(message)}{Environment.NewLine}";
            try
            {
                RotateIfNeeded();
                File.AppendAllText(_filePath, line);
            }
            catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
            {
                _filePath = CreateLogPath(Path.Combine(Path.GetTempPath(), "CodeIsland", "logs"));
                try { File.AppendAllText(_filePath, line); }
                catch (Exception fallbackError) when (fallbackError is IOException or UnauthorizedAccessException) { }
            }
        }
    }

    private static string CreateLogPath(string directory)
    {
        try
        {
            Directory.CreateDirectory(directory);
            return Path.Combine(directory, "codeisland.log");
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
        {
            var fallback = Path.Combine(Path.GetTempPath(), "CodeIsland", "logs");
            Directory.CreateDirectory(fallback);
            return Path.Combine(fallback, "codeisland.log");
        }
    }

    private void RotateIfNeeded()
    {
        if (!File.Exists(_filePath) || new FileInfo(_filePath).Length < _maxBytes) return;
        for (var i = 2; i >= 1; i--)
        {
            var source = i == 1 ? _filePath : _filePath + $".{i - 1}";
            var target = _filePath + $".{i}";
            if (File.Exists(source)) File.Move(source, target, true);
        }
    }
}

public static partial class SensitiveDataRedactor
{
    public static string Redact(string value)
    {
        var result = BearerRegex().Replace(value, "Bearer [REDACTED]");
        result = SecretRegex().Replace(result, "[REDACTED_SECRET]");
        var home = Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);
        if (!string.IsNullOrWhiteSpace(home)) result = result.Replace(home, "%USERPROFILE%", StringComparison.OrdinalIgnoreCase);
        return result;
    }

    [GeneratedRegex(@"(?i)Bearer\s+[A-Za-z0-9._~+/-]+=*")]
    private static partial Regex BearerRegex();
    [GeneratedRegex(@"(?i)(sk-[A-Za-z0-9_-]{12,}|api[_-]?key\s*[:=]\s*\S+|token\s*[:=]\s*\S+)")]
    private static partial Regex SecretRegex();
}
