using System.Text.Json;

namespace CodeIsland.Core;

public enum AgentEventType
{
    SessionStart,
    SessionEnd,
    ToolStart,
    ToolEnd,
    PermissionRequest,
    Question,
    Message,
    Error,
    Heartbeat
}

public sealed record AgentEvent(
    string EventId,
    string SessionId,
    AgentKind Agent,
    AgentEventType Type,
    DateTimeOffset Timestamp,
    string? WorkingDirectory = null,
    string? Title = null,
    string? Text = null,
    string? ToolName = null,
    JsonElement? Payload = null,
    int? ProcessId = null,
    string? TerminalKind = null);
