using CodeIsland.Hooks;
using System.Text.Json.Nodes;

var command = args.FirstOrDefault()?.ToLowerInvariant() ?? "status";
if (command == "status")
{
    foreach (var status in new ToolDetector().DetectAll())
    {
        Console.WriteLine($"{status.Tool.DisplayName,-14} executable={status.ExecutablePath ?? "not found"}");
        Console.WriteLine($"{new string(' ', 15)}config={status.ConfigPath ?? "not found"} hook={status.HookInstalled} healthy={status.IsHealthy}");
    }
    return 0;
}

if (command == "self-test")
{
    var root = Path.Combine(Path.GetTempPath(), $"codeisland-hooks-{Guid.NewGuid():N}");
    var home = Path.Combine(root, "home");
    var bin = Path.Combine(root, "bin");
    var backups = Path.Combine(root, "backups");
    var bridge = Path.Combine(root, "codeisland-bridge.exe");
    Directory.CreateDirectory(home);
    Directory.CreateDirectory(bin);
    try
    {
        var tool = KnownTools.All.Single(value => value.DisplayName == "Codex");
        File.WriteAllText(Path.Combine(bin, "codex.cmd"), "@echo off");
        File.WriteAllText(bridge, "bridge");
        var configPath = Path.Combine(home, tool.ConfigPaths[0]);
        Directory.CreateDirectory(Path.GetDirectoryName(configPath)!);
        File.WriteAllText(configPath, "{\"model\":\"gpt-5\"}");

        var store = new HookFileStore(backups);
        var manager = new HookManager(new ToolDetector(home, bin, store), store);
        Require(!manager.GetStatus(tool).HookInstalled, "Hook must initially be absent.");
        Require(manager.Install(tool, bridge).IsHealthy, "Install must produce a healthy status.");
        var registration = store.Read(configPath, tool.HookMarker);
        Require(registration?.Command.Contains(Path.GetFullPath(bridge), StringComparison.Ordinal) == true,
            "Registration must invoke the selected Bridge executable.");
        Require(registration?.Events.SequenceEqual(tool.Events) == true, "Registration must contain all tool events.");
        Require(tool.Events.SequenceEqual(["SessionStart", "SessionEnd", "UserPromptSubmit", "PreToolUse",
                "PostToolUse", "PermissionRequest", "Stop"]),
            "Codex must install the complete upstream-compatible hook event set.");
        Require(registration?.ProtocolVersion == HookRegistration.CurrentProtocolVersion,
            "Registration must contain the current protocol version.");
        var codexRoot = JsonNode.Parse(File.ReadAllText(configPath))!.AsObject();
        var codexEntry = codexRoot["hooks"]?[tool.Events[0]]?[0]?.AsObject();
        Require(codexEntry is not null && !codexEntry.ContainsKey("matcher"),
            "Codex native hooks must use the matcher-free event-map format.");
        Require(codexEntry?["hooks"]?[0]?["command"]?.GetValue<string>().Contains(tool.HookMarker) == true,
            "Codex native hook command must contain its registration id.");
        var codexCommand = codexEntry?["hooks"]?[0]?["command"]?.GetValue<string>() ?? string.Empty;
        Require(codexCommand.Contains("--source codex", StringComparison.Ordinal)
                && codexCommand.Contains($"--event {tool.Events[0]}", StringComparison.Ordinal),
            "Codex native hook command must provide source and event tags.");
        var permissionEntry = codexRoot["hooks"]?["PermissionRequest"]?[0]?.AsObject();
        Require(permissionEntry?["hooks"]?[0]?["timeout"]?.GetValue<int>() == 86400,
            "Codex hook timeout must allow a user decision to remain pending.");
        Require(manager.Install(tool, bridge).IsHealthy, "Repeated install must be idempotent.");
        Require(Directory.GetFiles(backups).Length == 1, "Idempotent install must create one backup only.");
        Require(!manager.Uninstall(tool).HookInstalled, "Uninstall must remove the marker.");
        Require(File.ReadAllText(configPath).Contains("gpt-5", StringComparison.Ordinal), "User configuration must be preserved.");
        Require(!File.ReadAllText(configPath).Contains("codeIsland", StringComparison.Ordinal), "Uninstall must remove only CodeIsland registration.");

        var claude = KnownTools.All.Single(value => value.DisplayName == "Claude Code");
        File.WriteAllText(Path.Combine(bin, "claude.cmd"), "@echo off");
        var claudeConfig = Path.Combine(home, claude.ConfigPaths[0]);
        Directory.CreateDirectory(Path.GetDirectoryName(claudeConfig)!);
        File.WriteAllText(claudeConfig, "{\"theme\":\"dark\"}");
        Require(manager.Install(claude, bridge).IsHealthy, "Claude install must be healthy.");
        var claudeRoot = JsonNode.Parse(File.ReadAllText(claudeConfig))!.AsObject();
        var claudeEntry = claudeRoot["hooks"]?[claude.Events[0]]?[0]?.AsObject();
        Require(claudeEntry?["matcher"]?.GetValue<string>() == "*",
            "Claude native hooks must contain a matcher.");
        Require(claudeEntry?["hooks"]?[0]?["type"]?.GetValue<string>() == "command",
            "Claude native hooks must contain a command hook.");
        Require(!manager.Uninstall(claude).HookInstalled, "Claude uninstall must remove registration.");

        var gemini = KnownTools.All.Single(value => value.DisplayName == "Gemini CLI");
        File.WriteAllText(Path.Combine(bin, "gemini.cmd"), "@echo off");
        var geminiConfig = Path.Combine(home, gemini.ConfigPaths[0]);
        Directory.CreateDirectory(Path.GetDirectoryName(geminiConfig)!);
        File.WriteAllText(geminiConfig, "{\"security\":{\"auth\":\"oauth\"}}");
        Require(manager.Install(gemini, bridge).IsHealthy, "Gemini install must be healthy.");
        var geminiRoot = JsonNode.Parse(File.ReadAllText(geminiConfig))!.AsObject();
        var geminiEntry = geminiRoot["hooks"]?[gemini.Events[0]]?[0]?.AsObject();
        Require(geminiEntry is not null && !geminiEntry.ContainsKey("matcher"),
            "Gemini native hooks must use the matcher-free event-map format.");
        Require(geminiEntry?["hooks"]?[0]?["timeout"]?.GetValue<int>() == 10000,
            "Gemini native hook timeout must be expressed in milliseconds.");
        Require(File.ReadAllText(geminiConfig).Contains("oauth", StringComparison.Ordinal),
            "Gemini user settings must be preserved.");
        Require(!manager.Uninstall(gemini).HookInstalled, "Gemini uninstall must remove registration.");

        var cursor = KnownTools.All.Single(value => value.DisplayName == "Cursor");
        File.WriteAllText(Path.Combine(bin, "cursor.cmd"), "@echo off");
        var cursorConfig = Path.Combine(home, cursor.ConfigPaths[0]);
        Directory.CreateDirectory(Path.GetDirectoryName(cursorConfig)!);
        File.WriteAllText(cursorConfig, "{\"userSetting\":true}");
        Require(manager.Install(cursor, bridge).IsHealthy, "Cursor install must be healthy.");
        var cursorRoot = JsonNode.Parse(File.ReadAllText(cursorConfig))!.AsObject();
        Require(cursorRoot["version"]?.GetValue<int>() == 1, "Cursor hooks must declare format version 1.");
        Require(cursorRoot["hooks"]?[cursor.Events[0]]?[0]?["matcher"]?.GetValue<string>() == "*",
            "Cursor event entries must include a matcher.");
        Require(!manager.Uninstall(cursor).HookInstalled, "Cursor uninstall must remove registration.");

        var factory = KnownTools.All.Single(value => value.DisplayName == "Factory Droid");
        File.WriteAllText(Path.Combine(bin, "droid.cmd"), "@echo off");
        var factoryConfig = Path.Combine(home, factory.ConfigPaths[0]);
        Directory.CreateDirectory(Path.GetDirectoryName(factoryConfig)!);
        File.WriteAllText(factoryConfig, "{}");
        Require(manager.Install(factory, bridge).IsHealthy, "Factory Droid install must be healthy.");
        Require(File.ReadAllText(factoryConfig).Contains("--source droid", StringComparison.Ordinal),
            "Factory hooks must use the droid source tag.");
        Require(!manager.Uninstall(factory).HookInstalled, "Factory uninstall must remove registration.");

        foreach (var additionalToolName in new[] { "Qoder", "CodeBuddy", "GitHub Copilot CLI" })
        {
            var additionalTool = KnownTools.All.Single(value => value.DisplayName == additionalToolName);
            var executableName = additionalTool.ExecutableNames.First(name => name.EndsWith(".cmd", StringComparison.OrdinalIgnoreCase));
            File.WriteAllText(Path.Combine(bin, executableName), "@echo off");
            var additionalConfig = Path.Combine(home, additionalTool.ConfigPaths[0]);
            Directory.CreateDirectory(Path.GetDirectoryName(additionalConfig)!);
            File.WriteAllText(additionalConfig, "{\"preserved\":true}");

            Require(manager.Install(additionalTool, bridge).IsHealthy,
                $"{additionalToolName} install must be healthy.");
            var installedText = File.ReadAllText(additionalConfig);
            Require(installedText.Contains($"--source {additionalTool.Agent.ToString().ToLowerInvariant()}", StringComparison.Ordinal),
                $"{additionalToolName} hooks must include the expected source tag.");
            Require(manager.Uninstall(additionalTool).HookInstalled == false,
                $"{additionalToolName} uninstall must remove registration.");
            Require(File.ReadAllText(additionalConfig).Contains("preserved", StringComparison.Ordinal),
                $"{additionalToolName} uninstall must preserve user configuration.");
        }
        Console.WriteLine("SELF-TEST PASS: detect, backup, install, idempotency, health and uninstall verified.");
        return 0;
    }
    finally
    {
        if (Directory.Exists(root)) Directory.Delete(root, true);
    }
}

Console.Error.WriteLine("Usage: codeisland-hooks [status | self-test]");
return 2;

static void Require(bool condition, string message)
{
    if (!condition) throw new InvalidOperationException(message);
}
