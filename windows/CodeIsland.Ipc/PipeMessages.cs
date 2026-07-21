using System.Text.Json.Serialization;
using CodeIsland.Core;

namespace CodeIsland.Ipc;

public enum PipeMessageType
{
    Hello,
    Event,
    Ack,
    Heartbeat,
    ActionResponse,
    Error
}

public enum UserAction { Approve, Deny, AlwaysAllow, Answer, Skip }

public sealed record PipeMessage(
    [property: JsonPropertyName("type")] PipeMessageType Type,
    [property: JsonPropertyName("messageId")] string MessageId,
    [property: JsonPropertyName("protocolVersion")] int ProtocolVersion = 1,
    [property: JsonPropertyName("event")] AgentEvent? Event = null,
    [property: JsonPropertyName("ackFor")] string? AckFor = null,
    [property: JsonPropertyName("action")] UserAction? Action = null,
    [property: JsonPropertyName("responseText")] string? ResponseText = null,
    [property: JsonPropertyName("error")] string? Error = null);
