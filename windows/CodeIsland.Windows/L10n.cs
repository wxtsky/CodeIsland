using System.Globalization;
using System.Windows;

namespace CodeIsland.Windows;

public static class L10n
{
    private static readonly IReadOnlyDictionary<string, IReadOnlyDictionary<string, string>> Values =
        new Dictionary<string, IReadOnlyDictionary<string, string>>(StringComparer.Ordinal)
        {
            ["en-US"] = new Dictionary<string, string>
            {
                ["IdleText"] = "Waiting for AI coding sessions",
                ["ApproveText"] = "Approve",
                ["DenyText"] = "Deny",
                ["AlwaysAllowText"] = "Always allow",
                ["SendText"] = "Send",
                ["CloseSessionText"] = "Close session"
            },
            ["zh-CN"] = new Dictionary<string, string>
            {
                ["IdleText"] = "等待 AI 编程会话",
                ["ApproveText"] = "允许",
                ["DenyText"] = "拒绝",
                ["AlwaysAllowText"] = "始终允许",
                ["SendText"] = "发送",
                ["CloseSessionText"] = "关闭会话"
            }
        };

    public static string ResolveLanguage(string configuredLanguage)
    {
        if (configuredLanguage is "en-US" or "zh-CN") return configuredLanguage;
        return CultureInfo.CurrentUICulture.Name.StartsWith("zh", StringComparison.OrdinalIgnoreCase) ? "zh-CN" : "en-US";
    }

    public static void Apply(ResourceDictionary resources, string configuredLanguage)
    {
        foreach (var pair in Values[ResolveLanguage(configuredLanguage)]) resources[pair.Key] = pair.Value;
    }

    public static string Get(string key, string language) => Values[ResolveLanguage(language)][key];
}
