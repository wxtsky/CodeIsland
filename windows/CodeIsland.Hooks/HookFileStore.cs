using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;

namespace CodeIsland.Hooks;

public sealed class HookFileStore
{
    private readonly string _backupDirectory;

    public HookFileStore(string? backupDirectory = null)
    {
        _backupDirectory = backupDirectory ?? Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "CodeIsland", "hook-backups");
    }

    public string Install(string configPath, HookRegistration registration)
    {
        Directory.CreateDirectory(Path.GetDirectoryName(configPath)!);
        var original = File.Exists(configPath) ? File.ReadAllText(configPath) : "{}";
        var root = JsonNode.Parse(original)?.AsObject()
            ?? throw new JsonException($"Configuration root in '{configPath}' must be a JSON object.");
        var hooks = GetHooks(root, create: true)!;
        var desired = JsonSerializer.SerializeToNode(registration);
        if (JsonNode.DeepEquals(hooks[registration.Id], desired)) return string.Empty;

        var backup = Path.Combine(_backupDirectory, $"{Path.GetFileName(configPath)}.{DateTime.UtcNow:yyyyMMddHHmmssfff}.bak");
        Directory.CreateDirectory(_backupDirectory);
        File.WriteAllText(backup, original, new UTF8Encoding(false));
        hooks[registration.Id] = desired;
        File.WriteAllText(configPath, root.ToJsonString(new JsonSerializerOptions { WriteIndented = true }), new UTF8Encoding(false));
        return backup;
    }

    public bool Remove(string configPath, string registrationId)
    {
        if (!File.Exists(configPath)) return false;
        var root = JsonNode.Parse(File.ReadAllText(configPath))?.AsObject()
            ?? throw new JsonException($"Configuration root in '{configPath}' must be a JSON object.");
        var hooks = GetHooks(root, create: false);
        if (hooks is null || !hooks.Remove(registrationId)) return false;
        if (hooks.Count == 0 && root["codeIsland"] is JsonObject codeIsland)
        {
            codeIsland.Remove("hooks");
            if (codeIsland.Count == 0) root.Remove("codeIsland");
        }
        File.WriteAllText(configPath, root.ToJsonString(new JsonSerializerOptions { WriteIndented = true }), new UTF8Encoding(false));
        return true;
    }

    public HookRegistration? Read(string configPath, string registrationId)
    {
        if (!File.Exists(configPath)) return null;
        var root = JsonNode.Parse(File.ReadAllText(configPath))?.AsObject()
            ?? throw new JsonException($"Configuration root in '{configPath}' must be a JSON object.");
        return GetHooks(root, create: false)?[registrationId]?.Deserialize<HookRegistration>();
    }

    private static JsonObject? GetHooks(JsonObject root, bool create)
    {
        if (root["codeIsland"] is not JsonObject codeIsland)
        {
            if (!create) return null;
            codeIsland = [];
            root["codeIsland"] = codeIsland;
        }
        if (codeIsland["hooks"] is JsonObject hooks) return hooks;
        if (!create) return null;
        hooks = [];
        codeIsland["hooks"] = hooks;
        return hooks;
    }
}
