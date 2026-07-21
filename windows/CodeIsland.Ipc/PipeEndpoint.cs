using System.IO.Pipes;
using System.Security.Principal;
using System.Runtime.Versioning;

namespace CodeIsland.Ipc;

[SupportedOSPlatform("windows")]
public static class PipeEndpoint
{
    public static string Name(string? userSid = null)
    {
        userSid ??= WindowsIdentity.GetCurrent().User?.Value ?? "unknown";
        var normalized = new string(userSid.Select(ch => char.IsLetterOrDigit(ch) ? ch : '-').ToArray());
        return $"codeisland-{normalized}";
    }

    public static NamedPipeServerStream CreateServer(string? userSid = null) =>
        new(Name(userSid), PipeDirection.InOut, 1, PipeTransmissionMode.Byte,
            PipeOptions.Asynchronous | PipeOptions.WriteThrough, 16 * 1024, 16 * 1024);

    public static NamedPipeClientStream CreateClient(string? userSid = null) =>
        new(".", Name(userSid), PipeDirection.InOut, PipeOptions.Asynchronous | PipeOptions.WriteThrough);
}
