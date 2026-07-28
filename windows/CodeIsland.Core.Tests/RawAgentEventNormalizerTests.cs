using CodeIsland.Core;
using CodeIsland.Protocol;

namespace CodeIsland.Core.Tests;

public sealed class RawAgentEventNormalizerTests
{
    [Theory]
    [InlineData("session.created", AgentEventType.SessionStart)]
    [InlineData("tool.execute.before", AgentEventType.ToolStart)]
    [InlineData("tool.execute.after", AgentEventType.ToolEnd)]
    [InlineData("permission.asked", AgentEventType.PermissionRequest)]
    [InlineData("session.error", AgentEventType.Error)]
    [InlineData("session.idle", AgentEventType.SessionEnd)]
    public void Normalize_OpenCodeEvent_MapsToAgentEventType(string eventName, AgentEventType expectedType)
    {
        var agentEvent = RawAgentEventNormalizer.Normalize("""
            {"session_id":"opencode-session","cwd":"C:\\work","tool_name":"bash","message":"running"}
            """, "opencode", eventName);

        Assert.Equal(AgentKind.OpenCode, agentEvent.Agent);
        Assert.Equal(expectedType, agentEvent.Type);
        Assert.Equal("opencode-session", agentEvent.SessionId);
        Assert.Equal("bash", agentEvent.ToolName);
    }
}
