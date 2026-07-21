namespace CodeIsland.Hooks;

public sealed record HookRegistration(
    string Id,
    string Command,
    IReadOnlyList<string> Events,
    int ProtocolVersion,
    string InstallerVersion)
{
    public const int CurrentProtocolVersion = 1;
    public const string CurrentInstallerVersion = "0.2.1";

    public static HookRegistration Create(HookTool tool, string bridgePath) => new(
        tool.HookMarker,
        $"\"{Path.GetFullPath(bridgePath)}\" send --stdin --registration {tool.HookMarker}",
        tool.Events,
        CurrentProtocolVersion,
        CurrentInstallerVersion);
}
