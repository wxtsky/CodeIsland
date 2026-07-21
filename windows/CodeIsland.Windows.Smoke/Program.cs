using CodeIsland.Core;
using CodeIsland.Ipc;
using CodeIsland.Protocol;
using CodeIsland.Windows;
using CodeIsland.Bluetooth;
using System.IO.Compression;

var appIconPath = Path.Combine(AppContext.BaseDirectory, "source", "codeisland.png");
using (var appIcon = new System.Drawing.Bitmap(appIconPath))
{
    Require(appIcon.Width == 256 && appIcon.Height == 256 && appIcon.GetPixel(0, 0).A == 0,
        "Application pixel icon must be 256x256 with a transparent background.");
}
var appIcoPath = Path.Combine(AppContext.BaseDirectory, "source", "codeisland.ico");
using (var appIco = new System.Drawing.Icon(appIcoPath))
    Require(appIco.Width == 256 && appIco.Height == 256, "Application ICO must contain the 256px pixel icon.");
using (var trayMenu = TrayMenuFactory.Create())
{
    trayMenu.Items.Add("Open panel");
    Require(trayMenu.BackColor == System.Drawing.Color.FromArgb(8, 8, 9)
            && trayMenu.ForeColor == System.Drawing.Color.FromArgb(232, 232, 235),
        "Tray menu must use the black CodeIsland palette.");
    Require(trayMenu.Items[0].Height == 34 && !trayMenu.ShowImageMargin,
        "Tray menu items must use the compact pixel-theme layout.");
}
Console.WriteLine("SMOKE PASS: transparent app icon and pixel-theme tray menu verified.");

var statusConverter = new SessionStatusTextConverter();
Require((string)statusConverter.Convert(null, typeof(string), null!, System.Globalization.CultureInfo.InvariantCulture)
        == "CODEISLAND 0",
    "Collapsed idle panel must show CODEISLAND 0 instead of an active-session status.");
Console.WriteLine("SMOKE PASS: collapsed idle status text verified.");

var codexGifPath = Path.Combine(AppContext.BaseDirectory, "source", "codex.gif");
using (var codexGif = System.Drawing.Image.FromFile(codexGifPath))
{
    Require(codexGif.Width == 32 && codexGif.Height == 32,
        "Codex pet GIF must remain at its native 32x32 size.");
    Require(codexGif.GetFrameCount(System.Drawing.Imaging.FrameDimension.Time) == 6,
        "Codex pet GIF must contain six animation frames.");
}
var codexExpandedGifPath = Path.Combine(AppContext.BaseDirectory, "source", "codex-expanded.gif");
using (var codexExpandedGif = new System.Drawing.Bitmap(codexExpandedGifPath))
{
    Require(codexExpandedGif.Width == 32 && codexExpandedGif.Height == 32,
        "Expanded Codex pet GIF must remain at its native 32x32 size.");
    Require(codexExpandedGif.GetFrameCount(System.Drawing.Imaging.FrameDimension.Time) == 6,
        "Expanded Codex pet GIF must contain six animation frames.");
    var background = codexExpandedGif.GetPixel(0, 0);
    Require(background.R == 13 && background.G == 13 && background.B == 14,
        "Expanded Codex pet GIF must match the #0D0D0E session-card background.");
}
Console.WriteLine("SMOKE PASS: opaque 32x32 six-frame Codex pet GIF verified.");

var store = new DesktopSessionStore();
var request = new AgentEvent(
    "permission-1", "session-1", AgentKind.Codex, AgentEventType.PermissionRequest,
    DateTimeOffset.UtcNow, @"E:\repo", "Run tests", "Allow dotnet test?", "shell");
using var stop = new CancellationTokenSource(TimeSpan.FromSeconds(5));
var pending = store.WaitForResponseAsync(request, stop.Token);

Require(!pending.IsCompleted, "Permission request must wait for user action.");
Require(store.PendingCount == 1, "Pending request must be tracked.");
Require(store.Sessions.Single().State == SessionState.WaitingForPermission,
    "Session must enter WaitingForPermission state.");
Require(store.Resolve(request.EventId, UserAction.Approve), "Approve action must resolve the request.");

var response = await pending;
Require(response.Type == PipeMessageType.ActionResponse, "Response type must be ActionResponse.");
Require(response.Action == UserAction.Approve, "Response must preserve the user action.");
Require(response.AckFor == request.EventId, "Response must target the pending event.");
Require(store.PendingCount == 0, "Resolved request must be removed.");
Require(store.Sessions.Single().State == SessionState.Running,
    "Resolved permission request must return the session to Running.");
Require(store.CurrentSession?.SessionId == request.SessionId,
    "Collapsed panel must expose the current active session.");

var denyRequest = request with { EventId = "permission-2" };
var denyPending = store.WaitForResponseAsync(denyRequest, stop.Token);
Require(store.ResolveCurrent(UserAction.Deny), "Current pending request must be selectable for deny.");
Require((await denyPending).Action == UserAction.Deny, "Current request deny action must be returned.");

Console.WriteLine("SMOKE PASS: permission request, pending state, approve action and response payload verified.");

var question = request with { EventId = "question-1", Type = AgentEventType.Question, Text = "Which environment?" };
var questionPending = store.WaitForResponseAsync(question, stop.Token);
Require(store.Sessions.Single().State == SessionState.WaitingForAnswer, "Session must enter WaitingForAnswer state.");
Require(store.Resolve(question.EventId, UserAction.Answer, "staging"), "Answer action must resolve the question.");
var answer = await questionPending;
Require(answer.Action == UserAction.Answer && answer.ResponseText == "staging",
    "Answer response must preserve user text.");
Console.WriteLine("SMOKE PASS: question request and text answer payload verified.");

var bounded = new DesktopSessionStore(maxVisibleSessions: 2, historyLimit: 2);
for (var i = 1; i <= 3; i++)
{
    bounded.Apply(new AgentEvent($"history-{i}", $"bounded-{i}", AgentKind.Claude,
        AgentEventType.SessionStart, DateTimeOffset.UtcNow.AddMinutes(-i)));
}
Require(bounded.Sessions.Count == 2, "Visible sessions must respect the configured maximum.");
Require(bounded.EventHistory.Count == 2, "Event history must respect the configured maximum.");
var removed = bounded.RemoveExpired(DateTimeOffset.UtcNow.AddMinutes(-1.5));
Require(removed == 2, "Expired session cleanup must remove sessions older than the cutoff.");
Require(bounded.RemoveSession("bounded-1"), "Visible session must support explicit removal.");
Require(bounded.SessionCount == 0, "Explicit removal must update the visible collection.");
Console.WriteLine("SMOKE PASS: state recovery, bounded history, visible limit and expiry cleanup verified.");

var resumed = new DesktopSessionStore();
resumed.Apply(new AgentEvent("resume-start", "resume-session", AgentKind.Codex,
    AgentEventType.SessionStart, DateTimeOffset.UtcNow));
resumed.Apply(new AgentEvent("resume-error", "resume-session", AgentKind.Codex,
    AgentEventType.Error, DateTimeOffset.UtcNow, Text: "Command interrupted"));
resumed.Apply(new AgentEvent("resume-message", "resume-session", AgentKind.Codex,
    AgentEventType.Message, DateTimeOffset.UtcNow, Text: "Continuing with live output"));
var resumedSession = resumed.CurrentSession ?? throw new InvalidOperationException("Resumed session is missing.");
Require(resumedSession is { State: SessionState.Running, Error: null }
        && resumedSession.LastMessage == "Continuing with live output",
    "A resumed Codex session must clear its stale failure and expose live output.");
Require((string)new SessionStatusTextConverter().Convert(resumedSession, typeof(string), null!,
            System.Globalization.CultureInfo.InvariantCulture) == "Continuing with live output",
    "Collapsed panel must show resumed live output instead of the previous failure.");
var liveWithTool = resumedSession with { ActiveTool = "shell", LastMessage = "Streaming command output" };
Require((string)new SessionStatusTextConverter().Convert(liveWithTool, typeof(string), "collapsed",
            System.Globalization.CultureInfo.InvariantCulture) == "Streaming command output",
    "Collapsed panel must prioritize live output while a tool is still running.");
Console.WriteLine("SMOKE PASS: interrupted Codex session resumes with live collapsed status.");

var prioritized = new DesktopSessionStore(maxVisibleSessions: 3);
prioritized.Apply(new AgentEvent("priority-1", "priority-first", AgentKind.Codex,
    AgentEventType.SessionStart, DateTimeOffset.UtcNow));
prioritized.Apply(new AgentEvent("priority-2", "priority-second", AgentKind.Codex,
    AgentEventType.SessionStart, DateTimeOffset.UtcNow));
Require(prioritized.MoveSessionBefore("priority-first", "priority-second"),
    "Visible sessions must support drag-order prioritization.");
Require(prioritized.Sessions[0].SessionId == "priority-first"
        && prioritized.CurrentSession?.SessionId == "priority-first",
    "Dragged session must become the collapsed panel priority.");
Console.WriteLine("SMOKE PASS: drag ordering updates collapsed-session priority.");

Require(NotificationSoundManager.CueFor(AgentEventType.SessionStart) == NotificationCue.Start,
    "Session start must map to the start cue.");
Require(NotificationSoundManager.CueFor(AgentEventType.PermissionRequest) == NotificationCue.Approval,
    "Permission request must map to the approval cue.");
Require(NotificationSoundManager.CueFor(AgentEventType.SessionEnd) == NotificationCue.Complete,
    "Session end must map to the completion cue.");
Require(NotificationSoundManager.CueFor(AgentEventType.Error) == NotificationCue.Error,
    "Error must map to the error cue.");
Console.WriteLine("SMOKE PASS: notification sound event mapping verified.");

var attentionBase = new AgentEvent("attention", "attention-session", AgentKind.Codex,
    AgentEventType.ToolStart, DateTimeOffset.UtcNow);
Require(!PanelAttentionPolicy.RequiresExpansion(attentionBase with { ToolName = "approval terminal" }),
    "Read-only transcript approval hints without actionable buttons must not expand the panel.");
Require(PanelAttentionPolicy.RequiresExpansion(attentionBase with { Type = AgentEventType.PermissionRequest }),
    "Structured permission requests must expand the panel.");
Require(PanelAttentionPolicy.RequiresExpansion(attentionBase with { Type = AgentEventType.Question }),
    "User questions must expand the panel.");
Require(!PanelAttentionPolicy.RequiresExpansion(attentionBase with { ToolName = "plugin codegraph/status" }),
    "Ordinary plugin calls must not expand the panel.");
Require(!PanelAttentionPolicy.RequiresExpansion(attentionBase with { Type = AgentEventType.ToolEnd, ToolName = "approval terminal" }),
    "Tool completion must not reopen the panel.");
Require(!PanelAttentionPolicy.RequiresExpansion(attentionBase with { Type = AgentEventType.Error }),
    "Non-interactive errors must not expand the panel.");
Console.WriteLine("SMOKE PASS: only actionable approval and question events expand the panel.");

var settingsRoot = Path.Combine(Path.GetTempPath(), $"codeisland-settings-{Guid.NewGuid():N}");
try
{
    var settingsStore = new SettingsStore(settingsRoot);
    settingsStore.Save(new AppSettings
    {
        Language = "zh-CN",
        SoundEnabled = false,
        MaxVisibleSessions = 99,
        SessionCleanupMinutes = 0
    });
    var loaded = settingsStore.Load();
    Require(loaded.Language == "zh-CN" && !loaded.SoundEnabled, "Settings must round-trip.");
    Require(loaded.MaxVisibleSessions == 20 && loaded.SessionCleanupMinutes == 1,
        "Numeric settings must be clamped to supported ranges.");
    Require(L10n.Get("ApproveText", loaded.Language) == "允许", "Chinese resources must resolve.");
    Require(L10n.Get("ApproveText", "en-US") == "Approve", "English resources must resolve.");
    var exported = Path.Combine(settingsRoot, "exported.json");
    settingsStore.Export(exported, loaded);
    Require(SettingsStore.Import(exported) == loaded, "Exported settings must import without data loss.");
    File.WriteAllText(settingsStore.FilePath, "{broken");
    Require(settingsStore.Load() == new AppSettings(), "Malformed settings must fall back to defaults.");
    var invalidImportRejected = false;
    try { SettingsStore.Import(settingsStore.FilePath); }
    catch (InvalidDataException) { invalidImportRejected = true; }
    Require(invalidImportRejected, "Malformed imported settings must be rejected.");
    Console.WriteLine("SMOKE PASS: settings round-trip, validation, fallback and localization verified.");
}
finally
{
    if (Directory.Exists(settingsRoot)) Directory.Delete(settingsRoot, true);
}

var locatorRoot = Path.Combine(Path.GetTempPath(), $"codeisland-locator-{Guid.NewGuid():N}");
try
{
    var appDirectory = Path.Combine(locatorRoot, "app");
    Directory.CreateDirectory(appDirectory);
    var packagedBridge = Path.Combine(appDirectory, "CodeIsland.Bridge.exe");
    File.WriteAllText(packagedBridge, "bridge");
    Require(BridgeLocator.Find(appDirectory) == packagedBridge, "Packaged Bridge must be located beside the app.");
    File.Delete(packagedBridge);
    var developmentBridge = Path.Combine(locatorRoot, "CodeIsland.Bridge", "bin", "Debug", "net8.0", "CodeIsland.Bridge.exe");
    Directory.CreateDirectory(Path.GetDirectoryName(developmentBridge)!);
    File.WriteAllText(developmentBridge, "bridge");
    Require(BridgeLocator.Find(appDirectory, locatorRoot) == developmentBridge,
        "Development Bridge must be found from the repository root.");
    Console.WriteLine("SMOKE PASS: packaged and development Bridge location verified.");
}
finally
{
    if (Directory.Exists(locatorRoot)) Directory.Delete(locatorRoot, true);
}
var startupExecutable = Path.Combine(Path.GetTempPath(), "CodeIsland", "CodeIsland.Windows.exe");
Require(StartupRegistration.BuildCommand(startupExecutable) == $"\"{Path.GetFullPath(startupExecutable)}\"",
    "Startup command must quote and normalize the executable path.");
Console.WriteLine("SMOKE PASS: startup command generation verified without registry mutation.");
Require(HotKeyBinding.TryParse("ctrl+shift+i", out var parsedHotKey), "Valid shortcut must parse.");
Require(parsedHotKey.ToString() == "Ctrl+Shift+I", "Shortcut must normalize modifier and key casing.");
Require(!HotKeyBinding.TryParse("Ctrl+Shift", out _), "Shortcut without a key must be rejected.");
var normalizedSettings = new AppSettings { ToggleShortcut = "Ctrl+Shift+I", ApproveShortcut = "Ctrl+Shift+I" }.Validate();
Require(normalizedSettings.ApproveShortcut == "Ctrl+Shift+I", "Settings validation must preserve valid shortcut syntax.");
Console.WriteLine("SMOKE PASS: shortcut parsing and normalization verified.");
Require(WindowMatcher.TitleMatchesWorkingDirectory("PowerShell - CodexStatus", @"E:\Demo\CodexStatus"),
    "Window title must match the working-directory leaf name.");
Require(!WindowMatcher.TitleMatchesWorkingDirectory("PowerShell - Other", @"E:\Demo\CodexStatus"),
    "Unrelated window title must not match.");
var processStore = new DesktopSessionStore();
processStore.Apply(new AgentEvent("process-1", "process-session", AgentKind.Codex,
    AgentEventType.SessionStart, DateTimeOffset.UtcNow, @"E:\Demo\CodexStatus", ProcessId: 4321,
    TerminalKind: "windows-terminal"));
Require(processStore.Sessions.Single().ProcessId == 4321
        && processStore.Sessions.Single().TerminalKind == "windows-terminal",
    "Process and terminal metadata must propagate to the session snapshot.");
Console.WriteLine("SMOKE PASS: window matching and process metadata propagation verified.");
var launcherRoot = Path.Combine(Path.GetTempPath(), $"codeisland-launcher-{Guid.NewGuid():N}");
try
{
    var launcherBin = Path.Combine(launcherRoot, "bin");
    var workspace = Path.Combine(launcherRoot, "workspace");
    Directory.CreateDirectory(launcherBin);
    Directory.CreateDirectory(workspace);
    File.WriteAllText(Path.Combine(launcherBin, "cursor.cmd"), "@echo off");
    File.WriteAllText(Path.Combine(launcherBin, "wt.exe"), "binary");
    var launcher = new WorkspaceLauncher();
    var cursorTarget = launcher.Resolve(AgentKind.Cursor, null, workspace, launcherBin);
    Require(cursorTarget?.Executable.EndsWith("cursor.cmd", StringComparison.OrdinalIgnoreCase) == true,
        "Cursor sessions must prefer the Cursor launcher.");
    var terminalTarget = launcher.Resolve(AgentKind.Codex, "windows-terminal", workspace, launcherBin);
    Require(terminalTarget?.Executable.EndsWith("wt.exe", StringComparison.OrdinalIgnoreCase) == true
            && terminalTarget.Arguments.StartsWith("-d ", StringComparison.Ordinal),
        "Terminal sessions must prefer Windows Terminal with a working-directory argument.");
    var codexDesktopTarget = launcher.ResolveConversation(AgentKind.Codex, "codex-desktop",
        "00000000-0000-4000-8000-000000000001");
    Require(codexDesktopTarget?.Executable ==
            "codex://threads/00000000-0000-4000-8000-000000000001",
        "Codex Desktop sessions must resolve to the exact thread deep link.");
Console.WriteLine("SMOKE PASS: Cursor, terminal and Codex Desktop thread launch resolution verified.");
}
finally
{
    if (Directory.Exists(launcherRoot)) Directory.Delete(launcherRoot, true);
}
var agentFrame = BuddyProtocol.EncodeAgent(AgentKind.Codex, SessionState.WaitingForPermission, "shell");
Require(agentFrame.SequenceEqual(new byte[] { 1, 3, 5, (byte)'s', (byte)'h', (byte)'e', (byte)'l', (byte)'l' }),
    "Buddy agent frame must match the upstream byte layout.");
var pairFrame = BuddyProtocol.EncodePairRequest(new byte[] { 1, 2, 3, 4, 5, 6 });
Require(pairFrame.SequenceEqual(new byte[] { 0xE0, 1, 2, 3, 4, 5, 6 }),
    "Buddy pair request must contain marker and six-byte host id.");
Require(BuddyProtocol.EncodeBrightness(500).SequenceEqual(new byte[] { 0xFE, 100 }),
    "Buddy brightness must clamp to 100 percent.");
Require(BuddyProtocol.DecodeUplink(new byte[] { 0xF0 }) is { Kind: BuddyUplinkKind.ControlCommand, Value: 0xF0 },
    "Buddy approve opcode must decode as a control command.");
Require(BuddyProtocol.DecodeUplink(new byte[] { 0xE2 }) is { Kind: BuddyUplinkKind.PairResponse },
    "Buddy pending opcode must decode as a pair response.");
Console.WriteLine("SMOKE PASS: Buddy agent, pairing, brightness and uplink frames verified.");
var diagnosticsRoot = Path.Combine(Path.GetTempPath(), $"codeisland-diagnostics-{Guid.NewGuid():N}");
try
{
    var blockedLogRoot = Path.Combine(diagnosticsRoot, "blocked-log-root");
    Directory.CreateDirectory(diagnosticsRoot);
    File.WriteAllText(blockedLogRoot, "not a directory");
    var fallbackLogger = new AppLogger(blockedLogRoot);
    fallbackLogger.Info("fallback logger must not fail application startup");
    Require(!string.Equals(fallbackLogger.LogDirectory, blockedLogRoot, StringComparison.OrdinalIgnoreCase),
        "Logger must fall back when the configured log directory is unavailable.");
    var logRoot = Path.Combine(diagnosticsRoot, "logs");
    var logger = new AppLogger(logRoot, maxBytes: 80);
    logger.Info("Bearer abcdefghijklmnop sk-abcdefghijklmnop "
                + Environment.GetFolderPath(Environment.SpecialFolder.UserProfile));
    logger.Info(new string('x', 100));
    logger.Info("rotation trigger");
    Require(Directory.GetFiles(logRoot, "codeisland.log*").Length >= 2, "Logger must rotate oversized files.");
    var diagnosticsZip = Path.Combine(diagnosticsRoot, "diagnostics.zip");
    new DiagnosticsExporter().Export(diagnosticsZip, new AppSettings(), store, logRoot);
    using var diagnosticsArchive = ZipFile.OpenRead(diagnosticsZip);
    Require(diagnosticsArchive.GetEntry("diagnostics.json") is not null, "Diagnostics archive must contain a summary.");
    Require(diagnosticsArchive.Entries.Any(entry => entry.FullName.StartsWith("logs/", StringComparison.Ordinal)),
        "Diagnostics archive must contain logs.");
    var diagnosticText = string.Join('\n', diagnosticsArchive.Entries.Select(entry =>
    {
        using var reader = new StreamReader(entry.Open());
        return reader.ReadToEnd();
    }));
    Require(!diagnosticText.Contains("abcdefghijklmnop", StringComparison.Ordinal),
        "Diagnostics must redact API keys and bearer tokens.");
Console.WriteLine("SMOKE PASS: rolling logs, diagnostics ZIP and secret redaction verified.");
}
finally
{
    if (Directory.Exists(diagnosticsRoot)) Directory.Delete(diagnosticsRoot, true);
}
var displayPosition = DisplayPositioner.TopCenter(new System.Drawing.Rectangle(1920, 0, 1920, 1080),
    dpiScaleX: 1.5, dpiScaleY: 1.5, widthDip: 560);
Require(Math.Abs(displayPosition.Left - 1640) < 0.01 && Math.Abs(displayPosition.Top - 14) < 0.01,
    "Panel positioning must convert the selected display from pixels to DIPs.");
Require(new AppSettings { DisplayMode = "invalid" }.Validate().DisplayMode == "primary",
    "Invalid display mode must fall back to primary.");
Console.WriteLine("SMOKE PASS: multi-display DPI positioning and settings validation verified.");
var workArea = new System.Windows.Rect(0, 0, 1920, 1080);
var topDock = PanelDocking.Resolve(workArea, new System.Windows.Size(780, 300),
    new System.Windows.Point(570, 7));
Require(topDock.Edges == DockEdges.Top && topDock.Top == 0,
    "Panel near the top edge must snap flush to the screen.");
Require(topDock.Corners.TopLeft == 0 && topDock.Corners.TopRight == 0,
    "Top-docked black panel must remain flat behind its curved shoulders.");
var bottomRightDock = PanelDocking.Resolve(workArea, new System.Windows.Size(400, 64),
    new System.Windows.Point(1518, 1018));
Require(bottomRightDock.Edges == (DockEdges.Right | DockEdges.Bottom)
        && bottomRightDock.Left == 1520 && bottomRightDock.Top == 1016,
    "Collapsed panel must snap exactly into a screen corner.");
Require(bottomRightDock.Corners.TopLeft > 0 && bottomRightDock.Corners.TopRight == 0
        && bottomRightDock.Corners.BottomLeft == 0 && bottomRightDock.Corners.BottomRight == 0,
    "Corner-docked black panel must leave its screen-facing corners flat.");
var shoulders = DockShoulderGeometry.Create(new System.Windows.Size(780, 160), DockEdges.Top);
Require(!shoulders.First.Bounds.IsEmpty && !shoulders.Second.Bounds.IsEmpty
        && shoulders.First.Bounds.Left == 0 && shoulders.Second.Bounds.Right == 780,
    "Top docking must create curved shoulders at both screen connections.");
var collapsedCenter = new System.Windows.Point(340 + 320d / 2, 0 + 40d / 2);
var expandedFromCenter = PanelDocking.Place(workArea, new System.Windows.Size(780, 300),
    new System.Windows.Point(collapsedCenter.X - 780d / 2, collapsedCenter.Y - 300d / 2), DockEdges.Top);
Require(Math.Abs((expandedFromCenter.Left + 780d / 2) - collapsedCenter.X) < .01,
    "Top-docked expand must preserve the collapsed panel's horizontal center.");
Console.WriteLine("SMOKE PASS: four-edge snapping and seamless dock corner geometry verified.");
var monitorBounds = new System.Drawing.Rectangle(0, 0, 1920, 1080);
Require(FullscreenDetector.IsSameBounds(new System.Drawing.Rectangle(0, 0, 1920, 1080), monitorBounds),
    "A window covering the monitor must be detected as full screen.");
Require(!FullscreenDetector.IsSameBounds(new System.Drawing.Rectangle(0, 0, 1920, 1040), monitorBounds),
    "A window leaving taskbar space must not be detected as full screen.");
Console.WriteLine("SMOKE PASS: full-screen monitor bounds detection verified.");
var filterSession = new SessionSnapshot("filter", AgentKind.Codex, SessionState.Running,
    DateTimeOffset.UtcNow, DateTimeOffset.UtcNow, null, null, null, null, null, null, null, null);
Require(SessionFilter.IsVisible(filterSession, "all"), "All filter must include active CLI sessions.");
Require(SessionFilter.IsVisible(filterSession, "active"), "Active filter must include running sessions.");
Require(!SessionFilter.IsVisible(filterSession with { State = SessionState.Completed }, "active"),
    "Active filter must exclude completed sessions.");
Require(SessionFilter.IsVisible(filterSession, "cli"), "CLI filter must include known CLI agents.");
Require(!SessionFilter.IsVisible(filterSession with { Agent = AgentKind.Unknown }, "cli"),
    "CLI filter must exclude unknown sources.");
Console.WriteLine("SMOKE PASS: all, active and CLI session filters verified.");
var mcpContext = new CodexTranscriptContext();
CodexTranscriptParser.ParseLine(
    "{\"timestamp\":\"2026-07-20T08:00:00Z\",\"type\":\"session_meta\",\"payload\":{\"session_id\":\"mcp-session\",\"cwd\":\"E:\\\\Demo\"}}",
    mcpContext);
var mcpEvent = CodexTranscriptParser.ParseLine(
    "{\"timestamp\":\"2026-07-20T08:00:01Z\",\"type\":\"event_msg\",\"payload\":{\"type\":\"mcp_tool_call_end\",\"call_id\":\"mcp-1\",\"invocation\":{\"server\":\"node_repl\",\"tool\":\"js\"}}}",
    mcpContext);
Require(mcpEvent is { Type: AgentEventType.ToolEnd, ToolName: "plugin node_repl/js" }
        && mcpEvent.Text is null,
    "Codex MCP/plugin calls must be parsed with their server and tool names.");
var mcpStore = new DesktopSessionStore();
mcpStore.Apply(mcpEvent!);
Require(mcpStore.CurrentSession?.LastMessage is null,
    "Completed plugin calls must not fabricate a completion message.");
Console.WriteLine("SMOKE PASS: Codex MCP/plugin parsing does not fabricate output.");
var nestedMcpEvent = CodexTranscriptParser.ParseLine(
    "{\"timestamp\":\"2026-07-20T08:00:02Z\",\"type\":\"response_item\",\"payload\":{\"type\":\"custom_tool_call\",\"call_id\":\"outer-1\",\"name\":\"exec\",\"input\":\"const r = await tools.mcp__codegraph__codegraph_status({projectPath: \\\"E:\\\\\\\\Demo\\\"});\"}}",
    mcpContext);
Require(nestedMcpEvent is { Type: AgentEventType.ToolStart, ToolName: "plugin codegraph/codegraph_status" },
    "Nested MCP calls must expose the plugin name before the invocation completes.");
Console.WriteLine("SMOKE PASS: nested CodeGraph invocation is identified before completion.");
var liveMessageEvent = CodexTranscriptParser.ParseLine(
    "{\"timestamp\":\"2026-07-20T08:00:03Z\",\"type\":\"event_msg\",\"payload\":{\"type\":\"agent_message\",\"message\":\"Reading the project configuration now.\"}}",
    mcpContext);
Require(liveMessageEvent is { Type: AgentEventType.Message, Text: "Reading the project configuration now." },
    "Codex agent messages must be exposed as live display content.");
var reasoningEvent = CodexTranscriptParser.ParseLine(
    "{\"timestamp\":\"2026-07-20T08:00:04Z\",\"type\":\"event_msg\",\"payload\":{\"type\":\"agent_reasoning\",\"text\":\"hidden\"}}",
    mcpContext);
Require(reasoningEvent is { Type: AgentEventType.Heartbeat, Text: null, ToolName: "background" },
    "Internal reasoning must drive background animation without creating display text.");
var reasoningSummaryEvent = CodexTranscriptParser.ParseLine(
    "{\"timestamp\":\"2026-07-20T08:00:04Z\",\"type\":\"response_item\",\"payload\":{\"type\":\"reasoning\",\"id\":\"reasoning-1\",\"summary\":[{\"type\":\"summary_text\",\"text\":\"Inspecting session state\"},{\"type\":\"summary_text\",\"text\":\"Preparing the update\"}],\"encrypted_content\":\"hidden\"}}",
    mcpContext);
Require(reasoningSummaryEvent is
        { Type: AgentEventType.Heartbeat, Text: "Inspecting session state / Preparing the update", ToolName: "background" },
    "Public Codex reasoning summaries must be displayed without exposing encrypted reasoning content.");
var approvalEvent = CodexTranscriptParser.ParseLine(
    "{\"timestamp\":\"2026-07-20T08:00:05Z\",\"type\":\"response_item\",\"payload\":{\"type\":\"custom_tool_call\",\"call_id\":\"approval-1\",\"name\":\"shell_command\",\"input\":\"{\\\"sandbox_permissions\\\":\\\"require_escalated\\\",\\\"justification\\\":\\\"Allow this command?\\\"}\"}}",
    mcpContext);
Require(approvalEvent is { Type: AgentEventType.ToolStart, ToolName: "approval terminal" },
    "Any terminal escalation request must be marked for automatic panel expansion.");
var ordinaryTerminalEvent = CodexTranscriptParser.ParseLine(
    "{\"timestamp\":\"2026-07-20T08:00:05Z\",\"type\":\"response_item\",\"payload\":{\"type\":\"custom_tool_call\",\"call_id\":\"ordinary-terminal\",\"name\":\"exec\",\"input\":\"const r = await tools.shell_command({\\\"command\\\":\\\"rg require_escalated sandbox_permissions justification .\\\",\\\"sandbox_permissions\\\":\\\"use_default\\\"});\"}}",
    mcpContext);
Require(ordinaryTerminalEvent is { Type: AgentEventType.ToolStart, ToolName: "exec" },
    "Ordinary terminal commands mentioning approval terms must not trigger panel expansion.");
var inputEvent = CodexTranscriptParser.ParseLine(
    "{\"timestamp\":\"2026-07-20T08:00:06Z\",\"type\":\"response_item\",\"payload\":{\"type\":\"custom_tool_call\",\"call_id\":\"approval-2\",\"name\":\"request_user_input\",\"input\":\"{}\"}}",
    mcpContext);
Require(inputEvent is { Type: AgentEventType.ToolStart, ToolName: "approval user input" },
    "Codex user-input requests must be marked for automatic panel expansion.");
var commandEvent = CodexTranscriptParser.ParseLine(
    "{\"timestamp\":\"2026-07-20T08:00:07Z\",\"type\":\"response_item\",\"payload\":{\"type\":\"custom_tool_call\",\"call_id\":\"command-1\",\"name\":\"exec\",\"input\":\"const r = await tools.shell_command({\\\"command\\\":\\\"dotnet test CodeIsland.Core.Tests\\\",\\\"workdir\\\":\\\"E:\\\\\\\\Demo\\\"});\"}}",
    mcpContext);
Require(commandEvent is { Type: AgentEventType.ToolStart, Text: null },
    "Shell commands must not be copied into the collapsed output text.");
var syntheticStatusSession = resumedSession with { LastMessage = null, ActiveTool = "exec" };
Require((string)statusConverter.Convert(syntheticStatusSession, typeof(string), "collapsed",
            System.Globalization.CultureInfo.InvariantCulture) == "CODEISLAND 1",
    "Collapsed status must never fabricate running exec_ or thinking_.");
var liveStore = new DesktopSessionStore();
liveStore.Apply(new AgentEvent("old-message", "live-session", AgentKind.Codex,
    AgentEventType.Message, DateTimeOffset.UtcNow, Text: "Previous output"));
liveStore.Apply(new AgentEvent("new-tool", "live-session", AgentKind.Codex,
    AgentEventType.ToolStart, DateTimeOffset.UtcNow, ToolName: "shell_command"));
Require(liveStore.CurrentSession is
        { LastMessage: "Previous output", ActiveTool: "shell_command", IsExecutingTool: true },
    "A running tool must retain the last real output and enable the collapsed wave animation.");
liveStore.Apply(new AgentEvent("new-turn", "live-session", AgentKind.Codex,
    AgentEventType.SessionStart, DateTimeOffset.UtcNow));
Require(liveStore.CurrentSession is { LastMessage: null, IsExecutingTool: true },
    "A new Codex turn must immediately clear output left by the previous turn.");
liveStore.Apply(reasoningSummaryEvent! with { SessionId = "live-session" });
Require(liveStore.CurrentSession is
        { LastMessage: "Inspecting session state / Preparing the update", IsExecutingTool: true },
    "The first public reasoning summary must replace the empty new-turn display in real time.");
liveStore.Apply(new AgentEvent("mcp-tool", "mcp-session", AgentKind.Codex,
    AgentEventType.ToolStart, DateTimeOffset.UtcNow, ToolName: "plugin codegraph/status"));
liveStore.Apply(liveMessageEvent!);
Require(liveStore.Sessions.Single(value => value.SessionId == "mcp-session").IsExecutingTool == false,
    "Fresh Codex output must stop the collapsed wave animation immediately.");
liveStore.Apply(reasoningEvent!);
Require(liveStore.Sessions.Single(value => value.SessionId == "mcp-session").IsExecutingTool,
    "Background reasoning after output must restart the collapsed wave animation.");
liveStore.Apply(new AgentEvent("mcp-tool-end", "mcp-session", AgentKind.Codex,
    AgentEventType.ToolEnd, DateTimeOffset.UtcNow, ToolName: "plugin codegraph/status"));
Require(liveStore.Sessions.Single(value => value.SessionId == "mcp-session").IsExecutingTool,
    "Tool completion must keep waving while the agent continues background processing.");
liveStore.Apply(new AgentEvent("live-end", "mcp-session", AgentKind.Codex,
    AgentEventType.SessionEnd, DateTimeOffset.UtcNow));
var completedLiveSession = liveStore.Sessions.Single(value => value.SessionId == "mcp-session");
Require((string)statusConverter.Convert(completedLiveSession, typeof(string), "collapsed",
            System.Globalization.CultureInfo.InvariantCulture) == "Reading the project configuration now.",
    "Collapsed completed sessions must retain the last real Codex message.");
Console.WriteLine("SMOKE PASS: live Codex output and approval detection verified.");
var transcriptRoot = Path.Combine(Path.GetTempPath(), $"codeisland-transcript-{Guid.NewGuid():N}");
try
{
    Directory.CreateDirectory(transcriptRoot);
    var transcript = Path.Combine(transcriptRoot, "rollout-test.jsonl");
    File.WriteAllLines(transcript,
    [
        "{\"timestamp\":\"2026-07-17T08:00:00Z\",\"type\":\"session_meta\",\"payload\":{\"session_id\":\"live-session\",\"cwd\":\"E:\\\\Demo\\\\CodexStatus\"}}",
        "{\"timestamp\":\"2026-07-17T08:00:01Z\",\"type\":\"event_msg\",\"payload\":{\"type\":\"task_started\"}}"
    ]);
    var transcriptEvents = new List<AgentEvent>();
    using var liveSignal = new ManualResetEventSlim();
    using var partialLineSignal = new ManualResetEventSlim();
    using var tailer = new CodexSessionTailer(transcriptRoot);
    tailer.EventReceived += (_, agentEvent) =>
    {
        lock (transcriptEvents) transcriptEvents.Add(agentEvent);
        if (agentEvent.ToolName == "shell") liveSignal.Set();
        if (agentEvent.Text == "Partial line delivered immediately") partialLineSignal.Set();
    };
    tailer.Start(TimeSpan.FromDays(1));
    lock (transcriptEvents)
        Require(transcriptEvents.Any(value => value.SessionId == "live-session"),
            "Tailer startup must recover an existing active Codex session.");
    File.AppendAllText(transcript, Environment.NewLine
        + "{\"timestamp\":\"2026-07-17T08:00:02Z\",\"type\":\"response_item\",\"payload\":{\"type\":\"custom_tool_call\",\"call_id\":\"call-1\",\"name\":\"shell\"}}"
        + Environment.NewLine);
    Require(liveSignal.Wait(TimeSpan.FromSeconds(5)), "Tailer must emit events appended after startup.");
    var partialLine = "{\"timestamp\":\"2026-07-17T08:00:03Z\",\"type\":\"event_msg\",\"payload\":{\"type\":\"agent_message\",\"message\":\"Partial line delivered immediately\"}}";
    var splitAt = partialLine.Length / 2;
    File.AppendAllText(transcript, partialLine[..splitAt]);
    Require(!partialLineSignal.Wait(TimeSpan.FromMilliseconds(250)),
        "Tailer must retain an incomplete JSONL record instead of advancing past it.");
    File.AppendAllText(transcript, partialLine[splitAt..] + Environment.NewLine);
    Require(partialLineSignal.Wait(TimeSpan.FromSeconds(2)),
        "Tailer polling must deliver a completed partial JSONL record without waiting for another event.");
    Console.WriteLine("SMOKE PASS: Codex active-session recovery, partial writes and low-latency JSONL tailing verified.");
}
finally
{
    if (Directory.Exists(transcriptRoot)) Directory.Delete(transcriptRoot, true);
}
return 0;

static void Require(bool condition, string message)
{
    if (!condition) throw new InvalidOperationException(message);
}
