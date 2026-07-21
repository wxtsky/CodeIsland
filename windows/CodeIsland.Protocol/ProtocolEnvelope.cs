using System.Text.Json;
using System.Text.Json.Serialization;
using CodeIsland.Core;

namespace CodeIsland.Protocol;

public sealed record ProtocolEnvelope(
    [property: JsonPropertyName("protocolVersion")] int ProtocolVersion,
    [property: JsonPropertyName("event")] AgentEvent Event)
{
    public const int CurrentVersion = 1;

    public static ProtocolEnvelope Create(AgentEvent agentEvent) => new(CurrentVersion, agentEvent);
}

public static class ProtocolSerializer
{
    private static readonly JsonSerializerOptions Options = new(JsonSerializerDefaults.Web)
    {
        PropertyNameCaseInsensitive = true,
        Converters = { new JsonStringEnumConverter(JsonNamingPolicy.SnakeCaseLower) }
    };

    public static string Serialize(ProtocolEnvelope envelope) => JsonSerializer.Serialize(envelope, Options);

    public static ProtocolEnvelope Deserialize(string json)
    {
        var envelope = JsonSerializer.Deserialize<ProtocolEnvelope>(json, Options)
            ?? throw new JsonException("Protocol message is empty.");
        if (envelope.ProtocolVersion != ProtocolEnvelope.CurrentVersion)
            throw new NotSupportedException($"Protocol version {envelope.ProtocolVersion} is not supported.");
        return envelope;
    }
}
