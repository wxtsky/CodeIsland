using System.Windows;
using System.Windows.Controls;
using CodeIsland.Hooks;
using System.IO;
using WpfButton = System.Windows.Controls.Button;
using System.Windows.Input;
using System.Windows.Media.Imaging;

namespace CodeIsland.Windows;

public partial class SettingsWindow : Window
{
    private readonly SettingsStore _store;
    private readonly Action<AppSettings> _applied;
    private AppSettings _settings;
    private readonly StartupRegistration _startup = new();

    public SettingsWindow(SettingsStore store, AppSettings settings, Action<AppSettings> applied, Func<string> hotKeyStatus)
    {
        InitializeComponent();
        var iconPath = Path.Combine(AppContext.BaseDirectory, "source", "codeisland.png");
        if (File.Exists(iconPath))
        {
            var icon = new BitmapImage(new Uri(iconPath, UriKind.Absolute));
            TitleAppIcon.Source = icon;
            AboutAppIcon.Source = icon;
        }
        _store = store;
        _settings = settings;
        _applied = applied;
        ApplyToForm(settings, includeRegistryState: true);
        ShortcutStatus.Text = hotKeyStatus();
        RefreshHooks();
    }

    private void SelectLanguage(string language)
    {
        LanguageBox.SelectedItem = LanguageBox.Items.Cast<ComboBoxItem>()
            .First(item => Equals(item.Tag, language));
    }

    private void ApplyToForm(AppSettings settings, bool includeRegistryState = false)
    {
        SelectLanguage(settings.Language);
        LaunchAtLoginBox.IsChecked = settings.LaunchAtLogin || includeRegistryState && _startup.IsEnabled();
        DisplayModeBox.SelectedItem = DisplayModeBox.Items.Cast<ComboBoxItem>()
            .First(item => Equals(item.Tag, settings.DisplayMode));
        SoundEnabledBox.IsChecked = settings.SoundEnabled;
        CleanupMinutesBox.Text = settings.SessionCleanupMinutes.ToString();
        HideInFullscreenBox.IsChecked = settings.HideInFullscreen;
        MaxSessionsBox.Text = settings.MaxVisibleSessions.ToString();
        HistoryLimitBox.Text = settings.EventHistoryLimit.ToString();
        ToggleShortcutBox.Text = settings.ToggleShortcut;
        ApproveShortcutBox.Text = settings.ApproveShortcut;
        DenyShortcutBox.Text = settings.DenyShortcut;
    }

    private void OnSave(object sender, RoutedEventArgs e)
    {
        try { _settings = ReadForm(); }
        catch (InvalidOperationException ex)
        {
            ShortcutStatus.Text = ex.Message;
            return;
        }
        _store.Save(_settings);
        try
        {
            var executable = Path.Combine(AppContext.BaseDirectory, "CodeIsland.Windows.exe");
            _startup.SetEnabled(_settings.LaunchAtLogin, executable);
        }
        catch (UnauthorizedAccessException ex)
        {
            GeneralStatus.Text = ex.Message;
        }
        _applied(_settings);
        Close();
    }

    private static int Parse(string text, int fallback) => int.TryParse(text, out var value) ? value : fallback;
    private void OnCancel(object sender, RoutedEventArgs e) => Close();
    private void OnTitleBarMouseDown(object sender, MouseButtonEventArgs e)
    {
        if (e.LeftButton == MouseButtonState.Pressed && e.ClickCount == 1) DragMove();
    }
    private void OnMinimize(object sender, RoutedEventArgs e) => WindowState = WindowState.Minimized;
    private void OnWindowClose(object sender, RoutedEventArgs e) => Close();
    private void OnDefaults(object sender, RoutedEventArgs e)
    {
        _settings = new AppSettings();
        ApplyToForm(_settings);
        GeneralStatus.Text = "Defaults loaded. Select Save to apply them.";
    }

    private void OnImport(object sender, RoutedEventArgs e)
    {
        var dialog = new Microsoft.Win32.OpenFileDialog { Filter = "CodeIsland settings (*.json)|*.json|All files (*.*)|*.*" };
        if (dialog.ShowDialog(this) != true) return;
        try
        {
            _settings = SettingsStore.Import(dialog.FileName);
            ApplyToForm(_settings);
            GeneralStatus.Text = $"Imported {Path.GetFileName(dialog.FileName)}. Select Save to apply.";
        }
        catch (InvalidDataException ex)
        {
            GeneralStatus.Text = ex.Message;
        }
    }

    private void OnExport(object sender, RoutedEventArgs e)
    {
        var dialog = new Microsoft.Win32.SaveFileDialog
        {
            Filter = "CodeIsland settings (*.json)|*.json",
            FileName = "codeisland-settings.json",
            DefaultExt = ".json"
        };
        if (dialog.ShowDialog(this) != true) return;
        _store.Export(dialog.FileName, ReadForm());
        GeneralStatus.Text = $"Exported to {Path.GetFileName(dialog.FileName)}.";
    }

    private AppSettings ReadForm()
    {
        var shortcuts = new[] { ToggleShortcutBox.Text, ApproveShortcutBox.Text, DenyShortcutBox.Text };
        if (shortcuts.Any(value => !HotKeyBinding.TryParse(value, out _)))
            throw new InvalidOperationException("Each shortcut must contain modifiers and one letter or digit.");
        var normalized = shortcuts.Select(value =>
        {
            HotKeyBinding.TryParse(value, out var binding);
            return binding.ToString();
        }).ToArray();
        if (normalized.Distinct(StringComparer.OrdinalIgnoreCase).Count() != normalized.Length)
            throw new InvalidOperationException("Shortcuts must be unique.");
        return (_settings with
        {
            Language = (LanguageBox.SelectedItem as ComboBoxItem)?.Tag?.ToString() ?? "system",
            LaunchAtLogin = LaunchAtLoginBox.IsChecked == true,
            DisplayMode = (DisplayModeBox.SelectedItem as ComboBoxItem)?.Tag?.ToString() ?? "primary",
            SoundEnabled = SoundEnabledBox.IsChecked == true,
            SessionCleanupMinutes = Parse(CleanupMinutesBox.Text, _settings.SessionCleanupMinutes),
            HideInFullscreen = HideInFullscreenBox.IsChecked == true,
            MaxVisibleSessions = Parse(MaxSessionsBox.Text, _settings.MaxVisibleSessions),
            EventHistoryLimit = Parse(HistoryLimitBox.Text, _settings.EventHistoryLimit),
            ToggleShortcut = normalized[0],
            ApproveShortcut = normalized[1],
            DenyShortcut = normalized[2]
        }).Validate();
    }
    private void OnRefreshHooks(object sender, RoutedEventArgs e) => RefreshHooks();
    private void RefreshHooks() => HooksGrid.ItemsSource = new ToolDetector().DetectAll()
        .Select(value => new HookStatusRow(value.Tool, value.ExecutablePath is not null,
            value.HookInstalled, value.IsHealthy, value.Problem)).ToArray();

    private sealed record HookStatusRow(HookTool Tool, bool HasExecutable, bool HookInstalled, bool IsHealthy, string? Problem);

    private void OnInstallHook(object sender, RoutedEventArgs e) => RunHookAction(sender, HookOperation.Install);
    private void OnRepairHook(object sender, RoutedEventArgs e) => RunHookAction(sender, HookOperation.Repair);
    private void OnUninstallHook(object sender, RoutedEventArgs e) => RunHookAction(sender, HookOperation.Uninstall);

    private void RunHookAction(object sender, HookOperation operation)
    {
        if (sender is not WpfButton { Tag: HookTool tool }) return;
        try
        {
            var bridge = BridgeLocator.FindCurrent();
            if (operation != HookOperation.Uninstall && bridge is null)
                throw new FileNotFoundException("CodeIsland.Bridge.exe was not found. Build or reinstall CodeIsland.");
            var fileStore = new HookFileStore();
            var manager = new HookManager(new ToolDetector(store: fileStore), fileStore);
            var status = operation switch
            {
                HookOperation.Install => manager.Install(tool, bridge!),
                HookOperation.Repair => manager.Repair(tool, bridge!),
                HookOperation.Uninstall => manager.Uninstall(tool),
                _ => throw new ArgumentOutOfRangeException(nameof(operation))
            };
            HookOperationStatus.Text = $"{tool.DisplayName}: {operation} completed. Healthy={status.IsHealthy}";
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException or InvalidOperationException)
        {
            HookOperationStatus.Text = $"{tool.DisplayName}: {ex.Message}";
        }
        RefreshHooks();
    }

    private enum HookOperation { Install, Repair, Uninstall }
}
