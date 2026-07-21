using CodeIsland.Core;

namespace CodeIsland.Windows;

public static class PanelAttentionPolicy
{
    public static bool RequiresExpansion(AgentEvent agentEvent) =>
        agentEvent.Type is AgentEventType.PermissionRequest or AgentEventType.Question;
}
