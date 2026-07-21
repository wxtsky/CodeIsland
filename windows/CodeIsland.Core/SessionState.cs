namespace CodeIsland.Core;

public enum SessionState
{
    Idle,
    Running,
    WaitingForPermission,
    WaitingForAnswer,
    Completed,
    Failed,
    Cancelled
}
