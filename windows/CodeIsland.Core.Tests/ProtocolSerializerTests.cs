using CodeIsland.Core;
using CodeIsland.Protocol;

namespace CodeIsland.Core.Tests;

public sealed class ProtocolSerializerTests
{
    [Fact]
    public void RoundTripsEnvelope()
    {
        var value = new AgentEvent("event-1", "session-1", AgentKind.Claude,
            AgentEventType.PermissionRequest, DateTimeOffset.UtcNow, Text: "Allow?");

        var json = ProtocolSerializer.Serialize(ProtocolEnvelope.Create(value));
        var result = ProtocolSerializer.Deserialize(json);

        Assert.Equal(ProtocolEnvelope.CurrentVersion, result.ProtocolVersion);
        Assert.Equal(value, result.Event);
        Assert.Contains("permission_request", json);
    }

    [Fact]
    public void RejectsUnknownProtocolVersion()
    {
        const string json = "{\"protocolVersion\":99,\"event\":{}}";
        Assert.Throws<NotSupportedException>(() => ProtocolSerializer.Deserialize(json));
    }
}
