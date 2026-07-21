using System.Text.Json;
using System.Text.Json.Serialization;

namespace CodeIsland.Ipc;

public static class PipeJson
{
    private static readonly JsonSerializerOptions Options = new(JsonSerializerDefaults.Web)
    {
        Converters = { new JsonStringEnumConverter(JsonNamingPolicy.SnakeCaseLower) }
    };

    public static string Serialize(PipeMessage message) => JsonSerializer.Serialize(message, Options);

    public static PipeMessage Deserialize(string json) =>
        JsonSerializer.Deserialize<PipeMessage>(json, Options)
        ?? throw new JsonException("Pipe message is empty.");
}
