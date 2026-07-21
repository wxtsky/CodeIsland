using System.Runtime.InteropServices;
using System.Runtime.Versioning;
using System.Windows.Interop;

namespace CodeIsland.Windows;

[SupportedOSPlatform("windows")]
public sealed class GlobalHotKeyManager : IDisposable
{
    private const int WmHotKey = 0x0312;
    private readonly HwndSource _source;
    private readonly Action _toggle;
    private readonly Action _approve;
    private readonly Action _deny;
    private bool _disposed;

    public bool ToggleRegistered { get; }
    public bool ApproveRegistered { get; }
    public bool DenyRegistered { get; }
    public string RegistrationSummary =>
        $"Toggle: {Label(ToggleRegistered)}, Approve: {Label(ApproveRegistered)}, Deny: {Label(DenyRegistered)}";

    private static string Label(bool registered) => registered ? "registered" : "conflict or unavailable";

    public GlobalHotKeyManager(HwndSource source, AppSettings settings, Action toggle, Action approve, Action deny)
    {
        _source = source;
        _toggle = toggle;
        _approve = approve;
        _deny = deny;
        _source.AddHook(WindowProc);
        ToggleRegistered = Register(1, settings.ToggleShortcut);
        ApproveRegistered = Register(2, settings.ApproveShortcut);
        DenyRegistered = Register(3, settings.DenyShortcut);
    }

    private bool Register(int id, string value) => HotKeyBinding.TryParse(value, out var binding)
        && RegisterHotKey(_source.Handle, id, binding.Modifiers, binding.VirtualKey);

    private IntPtr WindowProc(IntPtr hwnd, int message, IntPtr wParam, IntPtr lParam, ref bool handled)
    {
        if (message != WmHotKey) return IntPtr.Zero;
        switch (wParam.ToInt32())
        {
            case 1: _toggle(); handled = true; break;
            case 2: _approve(); handled = true; break;
            case 3: _deny(); handled = true; break;
        }
        return IntPtr.Zero;
    }

    public void Dispose()
    {
        if (_disposed) return;
        _disposed = true;
        _source.RemoveHook(WindowProc);
        UnregisterHotKey(_source.Handle, 1);
        UnregisterHotKey(_source.Handle, 2);
        UnregisterHotKey(_source.Handle, 3);
    }

    [DllImport("user32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool RegisterHotKey(IntPtr hWnd, int id, uint fsModifiers, uint vk);

    [DllImport("user32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool UnregisterHotKey(IntPtr hWnd, int id);
}

public readonly record struct HotKeyBinding(uint Modifiers, uint VirtualKey)
{
    private const uint Alt = 0x0001;
    private const uint Control = 0x0002;
    private const uint Shift = 0x0004;
    private const uint Win = 0x0008;

    public static bool TryParse(string? value, out HotKeyBinding binding)
    {
        binding = default;
        if (string.IsNullOrWhiteSpace(value)) return false;
        var parts = value.Split('+', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries);
        if (parts.Length < 2) return false;
        uint modifiers = 0;
        foreach (var modifier in parts[..^1])
        {
            modifiers |= modifier.ToLowerInvariant() switch
            {
                "ctrl" or "control" => Control,
                "alt" => Alt,
                "shift" => Shift,
                "win" or "windows" => Win,
                _ => 0
            };
        }
        if (modifiers == 0 || parts[..^1].Any(part => part.ToLowerInvariant() is not
                ("ctrl" or "control" or "alt" or "shift" or "win" or "windows"))) return false;
        var keyText = parts[^1].ToUpperInvariant();
        if (keyText.Length != 1 || !char.IsAsciiLetterOrDigit(keyText[0])) return false;
        binding = new HotKeyBinding(modifiers, keyText[0]);
        return true;
    }

    public override string ToString()
    {
        var parts = new List<string>();
        if ((Modifiers & Control) != 0) parts.Add("Ctrl");
        if ((Modifiers & Alt) != 0) parts.Add("Alt");
        if ((Modifiers & Shift) != 0) parts.Add("Shift");
        if ((Modifiers & Win) != 0) parts.Add("Win");
        parts.Add(((char)VirtualKey).ToString());
        return string.Join('+', parts);
    }
}
