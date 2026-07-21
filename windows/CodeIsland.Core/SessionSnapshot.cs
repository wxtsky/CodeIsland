namespace CodeIsland.Core;

public sealed record SessionSnapshot(
    string SessionId,
    AgentKind Agent,
    SessionState State,
    DateTimeOffset StartedAt,
    DateTimeOffset UpdatedAt,
    string? WorkingDirectory,
    string? Title,
    string? LastMessage,
    string? ActiveTool,
    string? PendingEventId,
    string? Error,
    int? ProcessId,
    string? TerminalKind,
    bool IsExecutingTool = false);
