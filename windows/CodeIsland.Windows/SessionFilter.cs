using CodeIsland.Core;

namespace CodeIsland.Windows;

public static class SessionFilter
{
    public static bool IsVisible(SessionSnapshot session, string mode) => mode switch
    {
        "active" => session.State is not (SessionState.Completed or SessionState.Cancelled or SessionState.Failed),
        "cli" => session.Agent is not AgentKind.Unknown,
        _ => true
    };
}
