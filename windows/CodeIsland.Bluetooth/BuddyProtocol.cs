using System.Text;
using CodeIsland.Core;

namespace CodeIsland.Bluetooth;

public static class BuddyProtocol
{
    public static readonly Guid ServiceUuid = Guid.Parse("0000beef-0000-1000-8000-00805f9b34fb");
    public static readonly Guid WriteCharacteristicUuid = Guid.Parse("0000beef-0001-1000-8000-00805f9b34fb");
    public static readonly Guid NotifyCharacteristicUuid = Guid.Parse("0000beef-0002-1000-8000-00805f9b34fb");
    public const string AdvertisedDeviceName = "Buddy";
    public const int HostIdLength = 6;
    public const int MaxToolNameBytes = 17;
    public const byte PairRequestMarker = 0xE0;
    public const byte UnpairMarker = 0xE1;
    public const byte WorkspaceMarker = 0xFC;
    public const byte BrightnessMarker = 0xFE;
    public const byte OrientationMarker = 0xFD;

    public static byte[] EncodeAgent(AgentKind agent, SessionState state, string? toolName = null)
    {
        var mascot = ToMascot(agent);
        var status = ToStatus(state);
        var tool = TruncateUtf8(toolName, MaxToolNameBytes);
        return [mascot, status, checked((byte)tool.Length), .. tool];
    }

    public static byte[] EncodeWorkspace(string? workspace)
    {
        var bytes = TruncateUtf8(workspace?.Trim(), 18);
        return [WorkspaceMarker, checked((byte)bytes.Length), .. bytes];
    }

    public static byte[] EncodeBrightness(double percent)
    {
        var value = double.IsFinite(percent) ? Math.Clamp((int)Math.Round(percent), 10, 100) : 70;
        return [BrightnessMarker, checked((byte)value)];
    }

    public static byte[] EncodeOrientation(bool down) => [OrientationMarker, down ? (byte)1 : (byte)0];
    public static byte[] EncodePairRequest(ReadOnlySpan<byte> hostId) => EncodeHostFrame(PairRequestMarker, hostId);
    public static byte[] EncodeUnpair(ReadOnlySpan<byte> hostId) => EncodeHostFrame(UnpairMarker, hostId);

    public static BuddyUplinkEvent? DecodeUplink(ReadOnlySpan<byte> payload)
    {
        if (payload.IsEmpty) return null;
        var value = payload[0];
        if (value is >= 0xE0 and <= 0xE2)
            return new BuddyUplinkEvent(BuddyUplinkKind.PairResponse, value);
        if (value <= 15) return new BuddyUplinkEvent(BuddyUplinkKind.Focus, value);
        if (value is >= 0xF0 and <= 0xF2)
            return new BuddyUplinkEvent(BuddyUplinkKind.ControlCommand, value);
        return null;
    }

    private static byte[] EncodeHostFrame(byte marker, ReadOnlySpan<byte> hostId)
    {
        if (hostId.Length != HostIdLength) throw new ArgumentException("Buddy host id must contain exactly 6 bytes.", nameof(hostId));
        var result = new byte[1 + HostIdLength];
        result[0] = marker;
        hostId.CopyTo(result.AsSpan(1));
        return result;
    }

    private static byte[] TruncateUtf8(string? value, int limit) =>
        string.IsNullOrEmpty(value) ? [] : Encoding.UTF8.GetBytes(value).Take(limit).ToArray();

    private static byte ToMascot(AgentKind agent) => agent switch
    {
        AgentKind.Claude => 0, AgentKind.Codex => 1, AgentKind.Gemini => 2, AgentKind.Cursor => 3,
        AgentKind.Copilot => 4, AgentKind.Trae => 5, AgentKind.Qoder => 6, AgentKind.Factory => 7,
        AgentKind.CodeBuddy => 8, AgentKind.OpenCode => 10, AgentKind.Kimi => 15,
        _ => throw new ArgumentOutOfRangeException(nameof(agent), agent, "Agent has no Buddy mascot slot.")
    };

    private static byte ToStatus(SessionState state) => state switch
    {
        SessionState.Idle or SessionState.Completed or SessionState.Cancelled => 0,
        SessionState.Running => 2,
        SessionState.WaitingForPermission => 3,
        SessionState.WaitingForAnswer => 4,
        SessionState.Failed => 3,
        _ => 1
    };
}

public enum BuddyUplinkKind { Focus, ControlCommand, PairResponse }
public sealed record BuddyUplinkEvent(BuddyUplinkKind Kind, byte Value);

public enum BuddyControlCommand : byte
{
    ApproveCurrentPermission = 0xF0,
    DenyCurrentPermission = 0xF1,
    SkipCurrentQuestion = 0xF2
}

public enum BuddyPairResponse : byte { Accepted = 0xE0, Rejected = 0xE1, Pending = 0xE2 }
