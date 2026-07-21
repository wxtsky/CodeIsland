using System.Text.Json;
using System.Text.Json.Serialization;
using CodeIsland.Core;
using CodeIsland.Ipc;
using CodeIsland.Protocol;

var mode = args.Length > 0 ? args[0].ToLowerInvariant() : "serve";
if (mode == "serve")
{
    var machine = new SessionStateMachine();
    await using var server = CreateServer(machine);
    Console.WriteLine($"CodeIsland Bridge listening on {PipeEndpoint.Name()}");
    await server.RunAsync();
}
else if (mode == "send" && args.Length >= 2)
{
    var stdin = args.Contains("--stdin", StringComparer.OrdinalIgnoreCase);
    var source = GetOption(args, "--source");
    var eventName = GetOption(args, "--event");
    var userSid = GetOption(args, "--user-sid");
    var file = stdin ? null : args.Skip(1).FirstOrDefault(value => !value.StartsWith("--", StringComparison.Ordinal));
    var input = stdin ? await Console.In.ReadToEndAsync() : await File.ReadAllTextAsync(file
        ?? throw new ArgumentException("send requires --stdin or an event JSON file."));
    var agentEvent = ParseEvent(input, source, eventName);
    await using var client = new PipeClient(userSid);
    await client.ConnectWithRetryAsync(3, TimeSpan.FromSeconds(1), TimeSpan.FromMilliseconds(150));
    var response = await client.SendAsync(
        new PipeMessage(PipeMessageType.Event, Guid.NewGuid().ToString("N"), Event: agentEvent),
        agentEvent.Type is AgentEventType.PermissionRequest or AgentEventType.Question
            ? TimeSpan.FromHours(8)
            : TimeSpan.FromSeconds(3));
    Console.WriteLine(HookResponse(response, agentEvent, source));
}
else if (mode == "self-test")
{
    var permissionEvent = new AgentEvent("permission-1", "session-1", AgentKind.Codex,
        AgentEventType.PermissionRequest, DateTimeOffset.UtcNow);
    foreach (var (action, behavior) in new[]
             {
                 (UserAction.Approve, "allow"),
                 (UserAction.AlwaysAllow, "always"),
                 (UserAction.Deny, "deny")
             })
    {
        var hookResponse = HookResponse(new PipeMessage(PipeMessageType.ActionResponse, "response-1",
            AckFor: permissionEvent.EventId, Action: action), permissionEvent, "codex");
        using var hookDocument = JsonDocument.Parse(hookResponse);
        var actual = hookDocument.RootElement.GetProperty("hookSpecificOutput").GetProperty("decision")
            .GetProperty("behavior").GetString();
        if (actual != behavior) throw new InvalidOperationException($"Expected Codex behavior {behavior}, got {actual}.");
    }

    using var stop = new CancellationTokenSource();
    var machine = new SessionStateMachine();
    await using var server = CreateServer(machine);
    var serverTask = server.RunAsync(stop.Token);
    await using var client = new PipeClient();
    await client.ConnectWithRetryAsync(10, TimeSpan.FromMilliseconds(250), TimeSpan.FromMilliseconds(50));

    await ExpectAck(client, new PipeMessage(PipeMessageType.Hello, "hello-1"));
    var testEvent = new AgentEvent("event-1", "session-1", AgentKind.Codex,
        AgentEventType.SessionStart, DateTimeOffset.UtcNow, Environment.CurrentDirectory, "IPC self-test");
    var serializedEvent = JsonSerializer.Serialize(testEvent, CreateEventJsonOptions());
    testEvent = ParseEvent(serializedEvent, "codex", "SessionStart");
    var rawCodex = ParseEvent("""
        {"session_id":"codex-native-1","cwd":"C:\\work","tool_name":"shell","message":"running"}
        """, "codex", "PreToolUse");
    if (rawCodex.Agent != AgentKind.Codex || rawCodex.Type != AgentEventType.ToolStart
        || rawCodex.SessionId != "codex-native-1" || rawCodex.ToolName != "shell")
        throw new InvalidOperationException("Codex native hook payload normalization failed.");
    await ExpectAck(client, new PipeMessage(PipeMessageType.Event, "message-1", Event: testEvent));
    await ExpectAck(client, new PipeMessage(PipeMessageType.Heartbeat, "heartbeat-1"));

    if (!machine.TryGet("session-1", out var snapshot) || snapshot?.State != SessionState.Running)
        throw new InvalidOperationException("Event did not reach the session state machine.");
    Console.WriteLine("SELF-TEST PASS: handshake, event acknowledgement, heartbeat and state update verified.");
    await stop.CancelAsync();
    await serverTask;
}
else
{
    Console.Error.WriteLine("Usage: codeisland-bridge [serve | send <event.json> | send --stdin [--source codex] [--event SessionStart] [--user-sid SID] | self-test]");
    return 2;
}

return 0;

static PipeServer CreateServer(SessionStateMachine machine) => new((message, _) =>
{
    var response = message.Type switch
    {
        PipeMessageType.Hello or PipeMessageType.Heartbeat =>
            new PipeMessage(PipeMessageType.Ack, Guid.NewGuid().ToString("N"), AckFor: message.MessageId),
        PipeMessageType.Event when message.Event is not null =>
            new PipeMessage(PipeMessageType.Ack, Guid.NewGuid().ToString("N"), AckFor: message.MessageId),
        _ => new PipeMessage(PipeMessageType.Error, Guid.NewGuid().ToString("N"), Error: "Unsupported message.")
    };
    if (message.Type == PipeMessageType.Event && message.Event is not null) machine.Apply(message.Event);
    return ValueTask.FromResult<PipeMessage?>(response);
});

static async Task ExpectAck(PipeClient client, PipeMessage message)
{
    var response = await client.SendAsync(message, TimeSpan.FromSeconds(2));
    if (response.Type != PipeMessageType.Ack || response.AckFor != message.MessageId)
        throw new InvalidOperationException($"Expected ACK for {message.MessageId}.");
}

static AgentEvent ParseEvent(string json, string? source = null, string? eventName = null)
{
    using var document = JsonDocument.Parse(json);
    var root = document.RootElement;
    if (root.ValueKind == JsonValueKind.Object
        && root.TryGetProperty("eventId", out _)
        && root.TryGetProperty("sessionId", out _)
        && root.TryGetProperty("type", out _))
    {
        return JsonSerializer.Deserialize<AgentEvent>(json, CreateEventJsonOptions())
            ?? throw new InvalidOperationException("Input event JSON is empty.");
    }
    return RawAgentEventNormalizer.Normalize(json, source, eventName);
}

static string? GetOption(string[] values, string name)
{
    var index = Array.FindIndex(values, value => value.Equals(name, StringComparison.OrdinalIgnoreCase));
    return index >= 0 && index + 1 < values.Length ? values[index + 1] : null;
}

static JsonSerializerOptions CreateEventJsonOptions() => new(JsonSerializerDefaults.Web)
{
    PropertyNameCaseInsensitive = true,
    Converters = { new JsonStringEnumConverter(JsonNamingPolicy.SnakeCaseLower) }
};

static string HookResponse(PipeMessage response, AgentEvent agentEvent, string? source)
{
    if (agentEvent.Type != AgentEventType.PermissionRequest
        || !string.Equals(source, "codex", StringComparison.OrdinalIgnoreCase)
        || response.Type != PipeMessageType.ActionResponse)
        return PipeJson.Serialize(response);

    var behavior = response.Action switch
    {
        UserAction.Approve => "allow",
        UserAction.AlwaysAllow => "always",
        _ => "deny"
    };
    return JsonSerializer.Serialize(new
    {
        hookSpecificOutput = new
        {
            hookEventName = "PermissionRequest",
            decision = new { behavior }
        }
    });
}
