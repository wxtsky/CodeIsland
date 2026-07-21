using System.IO;

namespace CodeIsland.Windows;

public static class BridgeLocator
{
    public static string? Find(string baseDirectory, string? repositoryRoot = null)
    {
        var packaged = Path.Combine(baseDirectory, "CodeIsland.Bridge.exe");
        if (File.Exists(packaged)) return packaged;
        if (repositoryRoot is not null)
        {
            foreach (var configuration in new[] { "Debug", "Release" })
            {
                var development = Path.Combine(repositoryRoot, "CodeIsland.Bridge", "bin", configuration,
                    "net8.0", "CodeIsland.Bridge.exe");
                if (File.Exists(development)) return development;
            }
        }
        return null;
    }

    public static string? FindCurrent()
    {
        var root = Directory.GetParent(AppContext.BaseDirectory)?.Parent?.Parent?.Parent?.Parent?.FullName;
        return Find(AppContext.BaseDirectory, root);
    }
}
