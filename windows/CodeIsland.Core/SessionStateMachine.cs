namespace CodeIsland.Core;

public sealed class SessionStateMachine
{
    private readonly Dictionary<string, SessionSnapshot> _sessions = new(StringComparer.Ordinal);
    private readonly HashSet<string> _processedEventIds = new(StringComparer.Ordinal);

    public IReadOnlyCollection<SessionSnapshot> Sessions => _sessions.Values;

    public bool Apply(AgentEvent agentEvent)
    {
        ArgumentNullException.ThrowIfNull(agentEvent);
        Validate(agentEvent);

        if (!_processedEventIds.Add(agentEvent.EventId))
        {
            return false;
        }

        _sessions.TryGetValue(agentEvent.SessionId, out var current);
        var startedAt = current?.StartedAt ?? agentEvent.Timestamp;
        var state = ResolveState(agentEvent.Type, current?.State);

        _sessions[agentEvent.SessionId] = new SessionSnapshot(
            agentEvent.SessionId,
            agentEvent.Agent == AgentKind.Unknown ? current?.Agent ?? AgentKind.Unknown : agentEvent.Agent,
            state,
            startedAt,
            agentEvent.Timestamp,
            agentEvent.WorkingDirectory ?? current?.WorkingDirectory,
            agentEvent.Title ?? current?.Title,
            ResolveMessage(agentEvent, current),
            ResolveActiveTool(agentEvent, current),
            state is SessionState.WaitingForPermission or SessionState.WaitingForAnswer
                ? agentEvent.EventId
                : null,
            ResolveError(agentEvent, current),
            agentEvent.ProcessId ?? current?.ProcessId,
            agentEvent.TerminalKind ?? current?.TerminalKind,
            ResolveExecutingTool(agentEvent, current));

        return true;
    }

    public bool TryGet(string sessionId, out SessionSnapshot? snapshot) =>
        _sessions.TryGetValue(sessionId, out snapshot);

    public bool ResolvePending(string sessionId, string eventId, DateTimeOffset timestamp)
    {
        if (!_sessions.TryGetValue(sessionId, out var snapshot) || snapshot.PendingEventId != eventId)
            return false;
        _sessions[sessionId] = snapshot with
        {
            State = SessionState.Running,
            UpdatedAt = timestamp,
            PendingEventId = null
        };
        return true;
    }

    public int RemoveExpired(DateTimeOffset cutoff) =>
        _sessions.Where(pair => pair.Value.UpdatedAt < cutoff)
            .Select(pair => pair.Key)
            .ToArray()
            .Count(key => _sessions.Remove(key));

    public bool Remove(string sessionId) => _sessions.Remove(sessionId);

    private static SessionState ResolveState(AgentEventType type, SessionState? current) => type switch
    {
        AgentEventType.SessionStart => SessionState.Running,
        AgentEventType.SessionEnd => SessionState.Completed,
        AgentEventType.ToolStart => SessionState.Running,
        AgentEventType.ToolEnd => SessionState.Running,
        AgentEventType.PermissionRequest => SessionState.WaitingForPermission,
        AgentEventType.Question => SessionState.WaitingForAnswer,
        AgentEventType.Message => current is SessionState.Completed or SessionState.Cancelled
            ? current.Value
            : SessionState.Running,
        AgentEventType.Error => SessionState.Failed,
        AgentEventType.Heartbeat => current ?? SessionState.Running,
        _ => current ?? SessionState.Idle
    };

    private static string? ResolveMessage(AgentEvent value, SessionSnapshot? current) =>
        value.Type == AgentEventType.ToolStart
            ? value.Text ?? current?.LastMessage
            : value.Type == AgentEventType.SessionStart
            ? value.Text
            : value.Type is AgentEventType.Message
            or AgentEventType.Question or AgentEventType.PermissionRequest
            || value.Type == AgentEventType.Heartbeat && !string.IsNullOrWhiteSpace(value.Text)
            || value.Type == AgentEventType.ToolEnd && !string.IsNullOrWhiteSpace(value.Text)
            ? value.Text ?? current?.LastMessage
            : current?.LastMessage;

    private static string? ResolveError(AgentEvent value, SessionSnapshot? current) => value.Type switch
    {
        AgentEventType.Error => value.Text,
        AgentEventType.SessionStart or AgentEventType.ToolStart or AgentEventType.ToolEnd
            or AgentEventType.Message or AgentEventType.PermissionRequest or AgentEventType.Question => null,
        _ => current?.Error
    };

    private static string? ResolveActiveTool(AgentEvent value, SessionSnapshot? current) => value.Type switch
    {
        AgentEventType.ToolStart => value.ToolName,
        AgentEventType.ToolEnd => null,
        AgentEventType.SessionEnd => null,
        AgentEventType.Error => null,
        _ => current?.ActiveTool
    };

    private static bool ResolveExecutingTool(AgentEvent value, SessionSnapshot? current) => value.Type switch
    {
        AgentEventType.SessionStart or AgentEventType.ToolStart or AgentEventType.ToolEnd => true,
        AgentEventType.Heartbeat when value.ToolName == "background" => true,
        AgentEventType.Message or AgentEventType.SessionEnd or AgentEventType.Error
            or AgentEventType.PermissionRequest or AgentEventType.Question => false,
        _ => current?.IsExecutingTool ?? false
    };

    private static void Validate(AgentEvent value)
    {
        if (string.IsNullOrWhiteSpace(value.EventId))
            throw new ArgumentException("EventId is required.", nameof(value));
        if (string.IsNullOrWhiteSpace(value.SessionId))
            throw new ArgumentException("SessionId is required.", nameof(value));
    }
}
