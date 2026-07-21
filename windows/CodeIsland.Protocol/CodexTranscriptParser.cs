using System.Text.Json;
using System.Text.RegularExpressions;
using CodeIsland.Core;

namespace CodeIsland.Protocol;

public sealed class CodexTranscriptContext
{
    public string? SessionId { get; set; }
    public string? WorkingDirectory { get; set; }
}

public static class CodexTranscriptParser
{
    public static AgentEvent? ParseLine(string line, CodexTranscriptContext context)
    {
        using var document = JsonDocument.Parse(line);
        var root = document.RootElement;
        var recordType = String(root, "type");
        if (!root.TryGetProperty("payload", out var payload) || payload.ValueKind != JsonValueKind.Object) return null;
        var payloadType = String(payload, "type");
        var timestamp = DateTimeOffset.TryParse(String(root, "timestamp"), out var parsed)
            ? parsed : DateTimeOffset.UtcNow;

        if (recordType == "session_meta")
        {
            context.SessionId = String(payload, "session_id", "id") ?? context.SessionId;
            context.WorkingDirectory = String(payload, "cwd") ?? context.WorkingDirectory;
            return Create(context, "session-meta", AgentEventType.SessionStart, timestamp,
                title: Path.GetFileName(context.WorkingDirectory));
        }
        if (string.IsNullOrWhiteSpace(context.SessionId)) return null;

        if (recordType == "event_msg")
        {
            return payloadType switch
            {
                "task_started" => Create(context, Id(payload, timestamp), AgentEventType.SessionStart, timestamp),
                "agent_message" => Create(context, Id(payload, timestamp), AgentEventType.Message, timestamp,
                    text: Truncate(String(payload, "message"))),
                "agent_reasoning" => Create(context, Id(payload, timestamp), AgentEventType.Heartbeat, timestamp,
                    tool: "background"),
                "patch_apply_begin" => Create(context, Id(payload, timestamp), AgentEventType.ToolStart, timestamp,
                    tool: "apply_patch"),
                "patch_apply_end" => Create(context, Id(payload, timestamp), AgentEventType.ToolEnd, timestamp,
                    tool: "apply_patch"),
                "mcp_tool_call_begin" => Create(context, Id(payload, timestamp), AgentEventType.ToolStart, timestamp,
                    tool: McpTool(payload)),
                "mcp_tool_call_end" => Create(context, Id(payload, timestamp), AgentEventType.ToolEnd, timestamp,
                    tool: McpTool(payload)),
                "task_complete" or "turn_complete" => Create(context, Id(payload, timestamp), AgentEventType.SessionEnd, timestamp),
                "turn_aborted" or "error" => Create(context, Id(payload, timestamp), AgentEventType.Error, timestamp,
                    text: String(payload, "message")),
                _ => null
            };
        }
        if (recordType != "response_item") return null;
        return payloadType switch
        {
            "reasoning" => Create(context, Id(payload, timestamp), AgentEventType.Heartbeat,
                timestamp, text: ReasoningSummary(payload), tool: "background"),
            "custom_tool_call" or "function_call" => Create(context, Id(payload, timestamp), AgentEventType.ToolStart,
                timestamp, tool: ToolName(payload)),
            "custom_tool_call_output" or "function_call_output" => Create(context, Id(payload, timestamp), AgentEventType.ToolEnd,
                timestamp, tool: "tool"),
            "message" when String(payload, "role") == "assistant" => Create(context, Id(payload, timestamp),
                AgentEventType.Message, timestamp, text: AssistantText(payload)),
            _ => null
        };
    }

    private static AgentEvent Create(CodexTranscriptContext context, string id, AgentEventType type,
        DateTimeOffset timestamp, string? text = null, string? tool = null, string? title = null) =>
        new(id, context.SessionId!, AgentKind.Codex, type, timestamp, context.WorkingDirectory,
            title, text, tool, TerminalKind: "codex-desktop");

    private static string Id(JsonElement payload, DateTimeOffset timestamp) =>
        String(payload, "call_id", "id") ?? $"transcript-{timestamp.ToUnixTimeMilliseconds()}-{Guid.NewGuid():N}";

    private static string? AssistantText(JsonElement payload)
    {
        if (!payload.TryGetProperty("content", out var content) || content.ValueKind != JsonValueKind.Array) return null;
        foreach (var item in content.EnumerateArray())
        {
            var text = String(item, "text");
            if (!string.IsNullOrWhiteSpace(text)) return Truncate(text);
        }
        return null;
    }

    private static string? ReasoningSummary(JsonElement payload)
    {
        if (!payload.TryGetProperty("summary", out var summary) || summary.ValueKind != JsonValueKind.Array)
            return null;
        var parts = summary.EnumerateArray()
            .Select(item => String(item, "text"))
            .Where(text => !string.IsNullOrWhiteSpace(text));
        return Truncate(string.Join(" / ", parts));
    }

    private static string ToolName(JsonElement payload)
    {
        var input = String(payload, "input", "arguments");
        var name = String(payload, "name") ?? "tool";
        if (name.Equals("request_user_input", StringComparison.OrdinalIgnoreCase)) return "approval user input";
        if (!string.IsNullOrWhiteSpace(input)
            && Regex.IsMatch(input,
                @"[""']sandbox_permissions[""']\s*:\s*[""']require_escalated[""']",
                RegexOptions.IgnoreCase | RegexOptions.CultureInvariant))
            return "approval terminal";
        return NestedMcpTool(payload) ?? name;
    }

    private static string? Truncate(string? text) => string.IsNullOrWhiteSpace(text)
        ? null
        : text.Length <= 240 ? text : text[..240] + "...";

    private static string McpTool(JsonElement payload)
    {
        if (!payload.TryGetProperty("invocation", out var invocation)
            || invocation.ValueKind != JsonValueKind.Object)
            return "plugin";
        var server = String(invocation, "server");
        var tool = String(invocation, "tool");
        return (server, tool) switch
        {
            ({ Length: > 0 }, { Length: > 0 }) => $"plugin {server}/{tool}",
            ({ Length: > 0 }, _) => $"plugin {server}",
            (_, { Length: > 0 }) => $"plugin {tool}",
            _ => "plugin"
        };
    }

    private static string? NestedMcpTool(JsonElement payload)
    {
        var input = String(payload, "input", "arguments");
        if (string.IsNullOrWhiteSpace(input)) return null;
        var match = Regex.Match(input,
            @"tools\.mcp__(?<server>[A-Za-z0-9_]+)__(?<tool>[A-Za-z0-9_]+)",
            RegexOptions.CultureInvariant);
        return match.Success
            ? $"plugin {match.Groups["server"].Value}/{match.Groups["tool"].Value}"
            : null;
    }

    private static string? String(JsonElement element, params string[] names)
    {
        foreach (var name in names)
            if (element.TryGetProperty(name, out var value) && value.ValueKind == JsonValueKind.String)
                return value.GetString();
        return null;
    }
}
