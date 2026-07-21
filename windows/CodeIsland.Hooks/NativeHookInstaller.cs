using System.Text.Json;
using System.Text.Json.Nodes;

namespace CodeIsland.Hooks;

public sealed class NativeHookInstaller
{
    private readonly HookFileStore _store;
    public NativeHookInstaller(HookFileStore store) => _store = store;

    public string Install(string configPath, HookTool tool, HookRegistration registration)
    {
        var backup = _store.Install(configPath, registration);
        var root = ParseRoot(configPath);
        if (tool.Format == HookConfigurationFormat.Cursor) root["version"] = 1;
        var hooks = root["hooks"] as JsonObject ?? new JsonObject();
        root["hooks"] = hooks;
        foreach (var eventName in tool.Events)
        {
            var entries = hooks[eventName] as JsonArray ?? new JsonArray();
            hooks[eventName] = entries;
            RemoveCodeIslandEntries(entries, registration.Id);
            var source = tool.SourceTag ?? tool.Agent.ToString().ToLowerInvariant();
            var commandHook = new JsonObject
            {
                ["type"] = "command",
                ["command"] = $"{registration.Command} --source {source} --event {eventName}",
                ["timeout"] = KnownTools.TimeoutFor(tool, eventName)
            };
            entries.Add(tool.Format is HookConfigurationFormat.Claude or HookConfigurationFormat.Cursor
                ? new JsonObject { ["matcher"] = "*", ["hooks"] = new JsonArray(commandHook) }
                : new JsonObject { ["hooks"] = new JsonArray(commandHook) });
        }
        Save(configPath, root);
        return backup;
    }

    public bool Uninstall(string configPath, HookTool tool, string registrationId)
    {
        if (!File.Exists(configPath)) return false;
        var root = ParseRoot(configPath);
        var changed = false;
        if (root["hooks"] is JsonObject hooks)
        {
            foreach (var eventName in tool.Events)
            {
                if (hooks[eventName] is not JsonArray entries) continue;
                var before = entries.Count;
                RemoveCodeIslandEntries(entries, registrationId);
                changed |= before != entries.Count;
                if (entries.Count == 0) hooks.Remove(eventName);
            }
            if (hooks.Count == 0) root.Remove("hooks");
        }
        if (changed) Save(configPath, root);
        return _store.Remove(configPath, registrationId) || changed;
    }

    private static void RemoveCodeIslandEntries(JsonArray entries, string registrationId)
    {
        for (var i = entries.Count - 1; i >= 0; i--)
        {
            if ((entries[i]?.ToJsonString() ?? string.Empty).Contains(registrationId, StringComparison.Ordinal))
                entries.RemoveAt(i);
        }
    }

    private static JsonObject ParseRoot(string path) => JsonNode.Parse(File.ReadAllText(path))?.AsObject()
        ?? throw new JsonException($"Configuration root in '{path}' must be a JSON object.");

    private static void Save(string path, JsonObject root) =>
        File.WriteAllText(path, root.ToJsonString(new JsonSerializerOptions { WriteIndented = true }));
}
