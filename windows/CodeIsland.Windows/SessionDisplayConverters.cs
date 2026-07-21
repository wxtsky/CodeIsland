using System.Globalization;
using System.IO;
using System.Windows.Data;
using System.Windows.Media;
using CodeIsland.Core;

namespace CodeIsland.Windows;

public sealed class SessionTitleConverter : IValueConverter
{
    public object Convert(object? value, Type targetType, object? parameter, CultureInfo culture)
    {
        if (value is not SessionSnapshot session) return "session";
        if (!string.IsNullOrWhiteSpace(session.Title)) return session.Title;
        if (!string.IsNullOrWhiteSpace(session.WorkingDirectory))
            return Path.GetFileName(session.WorkingDirectory.TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar));
        return session.Agent.ToString().ToLowerInvariant();
    }

    public object ConvertBack(object value, Type targetType, object parameter, CultureInfo culture) =>
        throw new NotSupportedException();
}

public sealed class SessionElapsedConverter : IValueConverter
{
    public object Convert(object? value, Type targetType, object? parameter, CultureInfo culture)
    {
        if (value is not DateTimeOffset startedAt) return "<1m";
        var elapsed = DateTimeOffset.UtcNow - startedAt;
        if (elapsed.TotalMinutes < 1) return "<1m";
        if (elapsed.TotalHours < 1) return $"{Math.Max(1, (int)elapsed.TotalMinutes)}m";
        return elapsed.TotalHours < 24 ? $"{Math.Max(1, (int)elapsed.TotalHours)}h" : $"{Math.Max(1, (int)elapsed.TotalDays)}d";
    }

    public object ConvertBack(object value, Type targetType, object parameter, CultureInfo culture) =>
        throw new NotSupportedException();
}

public sealed class SessionStateBrushConverter : IValueConverter
{
    private static readonly System.Windows.Media.Brush Green = new SolidColorBrush(System.Windows.Media.Color.FromRgb(55, 208, 103));
    private static readonly System.Windows.Media.Brush Orange = new SolidColorBrush(System.Windows.Media.Color.FromRgb(242, 126, 74));
    private static readonly System.Windows.Media.Brush Red = new SolidColorBrush(System.Windows.Media.Color.FromRgb(239, 84, 91));
    private static readonly System.Windows.Media.Brush Gray = new SolidColorBrush(System.Windows.Media.Color.FromRgb(166, 166, 172));

    public object Convert(object? value, Type targetType, object? parameter, CultureInfo culture) => value switch
    {
        SessionState.Failed => Red,
        SessionState.WaitingForPermission or SessionState.WaitingForAnswer => Orange,
        SessionState.Completed or SessionState.Cancelled => Gray,
        _ => Green
    };

    public object ConvertBack(object value, Type targetType, object parameter, CultureInfo culture) =>
        throw new NotSupportedException();
}

public sealed class SessionStatusTextConverter : IValueConverter
{
    public object Convert(object? value, Type targetType, object? parameter, CultureInfo culture)
    {
        var collapsed = string.Equals(parameter as string, "collapsed", StringComparison.OrdinalIgnoreCase);
        if (collapsed)
            return value switch
            {
                null => "CODEISLAND 0",
                SessionSnapshot { Error: { Length: > 0 } error } => error,
                SessionSnapshot { State: SessionState.WaitingForPermission } => "waiting for approval_",
                SessionSnapshot { State: SessionState.WaitingForAnswer } => "waiting for answer_",
                SessionSnapshot { LastMessage: { Length: > 0 } message } => message,
                _ => "CODEISLAND 1"
            };
        return value switch
        {
            null => "CODEISLAND 0",
            SessionSnapshot { Error: { Length: > 0 } error } => error,
            SessionSnapshot { State: SessionState.WaitingForPermission } => "waiting for approval_",
            SessionSnapshot { State: SessionState.WaitingForAnswer } => "waiting for answer_",
            SessionSnapshot { State: SessionState.Completed } => "completed",
            SessionSnapshot { State: SessionState.Failed } => "failed_",
            SessionSnapshot { ActiveTool: { Length: > 0 } tool } => $"running {tool}_",
            SessionSnapshot { LastMessage: { Length: > 0 } message } => message,
            _ => "thinking_"
        };
    }

    public object ConvertBack(object value, Type targetType, object parameter, CultureInfo culture) =>
        throw new NotSupportedException();
}

public sealed class AgentAccentConverter : IValueConverter
{
    public object Convert(object? value, Type targetType, object? parameter, CultureInfo culture)
    {
        if (value is CollectionViewGroup group) value = group.Name;
        return value switch
    {
        AgentKind.Claude => new SolidColorBrush(System.Windows.Media.Color.FromRgb(235, 126, 77)),
        AgentKind.Codex => new SolidColorBrush(System.Windows.Media.Color.FromRgb(133, 112, 255)),
        AgentKind.Gemini => new SolidColorBrush(System.Windows.Media.Color.FromRgb(168, 107, 238)),
        _ => new SolidColorBrush(System.Windows.Media.Color.FromRgb(55, 208, 103))
    };
    }

    public object ConvertBack(object value, Type targetType, object parameter, CultureInfo culture) =>
        throw new NotSupportedException();
}

public sealed class AgentGroupHeaderConverter : IValueConverter
{
    public object Convert(object? value, Type targetType, object? parameter, CultureInfo culture) =>
        value is CollectionViewGroup group ? $"{group.Name} ({group.ItemCount})" : "Sessions";

    public object ConvertBack(object value, Type targetType, object parameter, CultureInfo culture) =>
        throw new NotSupportedException();
}

public sealed class AgentGifPathConverter : IValueConverter
{
    public object Convert(object? value, Type targetType, object? parameter, CultureInfo culture)
    {
        var name = value switch
        {
            AgentKind.Claude => "claude.gif",
            AgentKind.Codex when string.Equals(parameter as string, "expanded", StringComparison.OrdinalIgnoreCase)
                => "codex-expanded.gif",
            AgentKind.Codex => "codex.gif",
            AgentKind.Cursor => "cursor.gif",
            AgentKind.Gemini => "gemini.gif",
            AgentKind.OpenCode => "opencode.gif",
            AgentKind.Qoder => "qoder.gif",
            _ => null
        };
        return name is null ? string.Empty : Path.Combine(AppContext.BaseDirectory, "source", name);
    }

    public object ConvertBack(object value, Type targetType, object parameter, CultureInfo culture) =>
        throw new NotSupportedException();
}

public sealed class AgentGifSizeConverter : IValueConverter
{
    public object Convert(object? value, Type targetType, object? parameter, CultureInfo culture) =>
        value is AgentKind.Codex ? 32d : 128d;

    public object ConvertBack(object value, Type targetType, object parameter, CultureInfo culture) =>
        throw new NotSupportedException();
}
