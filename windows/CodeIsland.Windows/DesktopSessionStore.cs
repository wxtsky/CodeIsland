using System.Collections.ObjectModel;
using System.ComponentModel;
using System.Runtime.CompilerServices;
using CodeIsland.Core;
using CodeIsland.Ipc;

namespace CodeIsland.Windows;

public sealed class DesktopSessionStore : INotifyPropertyChanged
{
    private readonly SessionStateMachine _machine = new();
    private readonly Dictionary<string, PendingResponse> _pending = new(StringComparer.Ordinal);
    private readonly int _historyLimit;
    private readonly int _maxVisibleSessions;
    public ObservableCollection<SessionSnapshot> Sessions { get; } = [];
    public ObservableCollection<AgentEvent> EventHistory { get; } = [];
    public event EventHandler<AgentEvent>? EventApplied;
    public int SessionCount => Sessions.Count;
    public bool HasSessions => Sessions.Count > 0;
    public bool IsIdle => !HasSessions;
    public SessionSnapshot? CurrentSession => Sessions.FirstOrDefault(value =>
        value.State is not (SessionState.Completed or SessionState.Cancelled or SessionState.Failed))
        ?? Sessions.FirstOrDefault();

    public DesktopSessionStore(int maxVisibleSessions = 5, int historyLimit = 200)
    {
        if (maxVisibleSessions < 1) throw new ArgumentOutOfRangeException(nameof(maxVisibleSessions));
        if (historyLimit < 1) throw new ArgumentOutOfRangeException(nameof(historyLimit));
        _maxVisibleSessions = maxVisibleSessions;
        _historyLimit = historyLimit;
    }

    public void Apply(AgentEvent agentEvent)
    {
        if (!_machine.Apply(agentEvent) || !_machine.TryGet(agentEvent.SessionId, out var snapshot) || snapshot is null)
            return;
        EventHistory.Insert(0, agentEvent);
        while (EventHistory.Count > _historyLimit) EventHistory.RemoveAt(EventHistory.Count - 1);
        var existing = Sessions.Select((value, index) => (value, index))
            .FirstOrDefault(pair => pair.value.SessionId == snapshot.SessionId);
        if (existing.value is null) Sessions.Insert(0, snapshot);
        else Sessions[existing.index] = snapshot;
        while (Sessions.Count > _maxVisibleSessions) Sessions.RemoveAt(Sessions.Count - 1);
        OnPropertyChanged(nameof(SessionCount));
        OnPropertyChanged(nameof(HasSessions));
        OnPropertyChanged(nameof(IsIdle));
        OnPropertyChanged(nameof(CurrentSession));
        EventApplied?.Invoke(this, agentEvent);
    }

    public Task<PipeMessage> WaitForResponseAsync(AgentEvent agentEvent, CancellationToken cancellationToken)
    {
        Apply(agentEvent);
        var pending = new TaskCompletionSource<PipeMessage>(TaskCreationOptions.RunContinuationsAsynchronously);
        _pending[agentEvent.EventId] = new PendingResponse(agentEvent.SessionId, pending);
        cancellationToken.Register(() => pending.TrySetCanceled(cancellationToken));
        return pending.Task;
    }

    public bool Resolve(string eventId, UserAction action, string? responseText = null)
    {
        if (!_pending.Remove(eventId, out var pending)) return false;
        _machine.ResolvePending(pending.SessionId, eventId, DateTimeOffset.UtcNow);
        if (_machine.TryGet(pending.SessionId, out var snapshot) && snapshot is not null) ReplaceVisible(snapshot);
        return pending.Completion.TrySetResult(new PipeMessage(
            PipeMessageType.ActionResponse,
            Guid.NewGuid().ToString("N"),
            AckFor: eventId,
            Action: action,
            ResponseText: responseText));
    }

    public bool ResolveCurrent(UserAction action)
    {
        var pending = Sessions.FirstOrDefault(value =>
            value.State is SessionState.WaitingForPermission or SessionState.WaitingForAnswer);
        return pending?.PendingEventId is { } eventId && Resolve(eventId, action);
    }

    public int PendingCount => _pending.Count;

    public int RemoveExpired(DateTimeOffset cutoff)
    {
        var removed = _machine.RemoveExpired(cutoff);
        var activeIds = _machine.Sessions.Select(value => value.SessionId).ToHashSet(StringComparer.Ordinal);
        for (var i = Sessions.Count - 1; i >= 0; i--)
            if (!activeIds.Contains(Sessions[i].SessionId)) Sessions.RemoveAt(i);
        foreach (var eventId in _pending.Where(pair => !activeIds.Contains(pair.Value.SessionId))
                     .Select(pair => pair.Key).ToArray())
        {
            if (_pending.Remove(eventId, out var pending)) pending.Completion.TrySetCanceled();
        }
        OnPropertyChanged(nameof(SessionCount));
        OnPropertyChanged(nameof(HasSessions));
        OnPropertyChanged(nameof(IsIdle));
        OnPropertyChanged(nameof(CurrentSession));
        return removed;
    }

    public bool RemoveSession(string sessionId)
    {
        if (!_machine.Remove(sessionId)) return false;
        var visible = Sessions.FirstOrDefault(value => value.SessionId == sessionId);
        if (visible is not null) Sessions.Remove(visible);
        foreach (var eventId in _pending.Where(pair => pair.Value.SessionId == sessionId)
                     .Select(pair => pair.Key).ToArray())
        {
            if (_pending.Remove(eventId, out var pending)) pending.Completion.TrySetCanceled();
        }
        OnPropertyChanged(nameof(SessionCount));
        OnPropertyChanged(nameof(HasSessions));
        OnPropertyChanged(nameof(IsIdle));
        OnPropertyChanged(nameof(CurrentSession));
        return true;
    }

    public bool MoveSessionBefore(string sessionId, string targetSessionId)
    {
        var sourceIndex = Sessions.ToList().FindIndex(value => value.SessionId == sessionId);
        var targetIndex = Sessions.ToList().FindIndex(value => value.SessionId == targetSessionId);
        if (sourceIndex < 0 || targetIndex < 0 || sourceIndex == targetIndex) return false;
        Sessions.Move(sourceIndex, targetIndex);
        OnPropertyChanged(nameof(CurrentSession));
        return true;
    }

    private void ReplaceVisible(SessionSnapshot snapshot)
    {
        var index = Sessions.ToList().FindIndex(value => value.SessionId == snapshot.SessionId);
        if (index >= 0) Sessions[index] = snapshot;
        OnPropertyChanged(nameof(CurrentSession));
    }

    private sealed record PendingResponse(string SessionId, TaskCompletionSource<PipeMessage> Completion);

    public event PropertyChangedEventHandler? PropertyChanged;
    private void OnPropertyChanged([CallerMemberName] string? name = null) =>
        PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(name));
}
