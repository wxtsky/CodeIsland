using System.Text.Json;
using System.IO;

namespace CodeIsland.Windows;

public sealed class SettingsStore
{
    private static readonly JsonSerializerOptions Options = new(JsonSerializerDefaults.Web) { WriteIndented = true };
    public string FilePath { get; }

    public SettingsStore(string? rootDirectory = null)
    {
        rootDirectory ??= Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), "CodeIsland");
        FilePath = Path.Combine(rootDirectory, "settings.json");
    }

    public AppSettings Load()
    {
        if (!File.Exists(FilePath)) return new AppSettings();
        try
        {
            return (JsonSerializer.Deserialize<AppSettings>(File.ReadAllText(FilePath), Options) ?? new AppSettings()).Validate();
        }
        catch (JsonException)
        {
            return new AppSettings();
        }
    }

    public void Save(AppSettings settings)
    {
        Directory.CreateDirectory(Path.GetDirectoryName(FilePath)!);
        var temporary = FilePath + ".tmp";
        File.WriteAllText(temporary, JsonSerializer.Serialize(settings.Validate(), Options));
        File.Move(temporary, FilePath, true);
    }

    public void Export(string destinationPath, AppSettings settings) =>
        File.WriteAllText(destinationPath, JsonSerializer.Serialize(settings.Validate(), Options));

    public static AppSettings Import(string sourcePath)
    {
        try
        {
            return (JsonSerializer.Deserialize<AppSettings>(File.ReadAllText(sourcePath), Options)
                ?? new AppSettings()).Validate();
        }
        catch (JsonException ex)
        {
            throw new InvalidDataException("The selected settings file is not valid JSON.", ex);
        }
    }
}
