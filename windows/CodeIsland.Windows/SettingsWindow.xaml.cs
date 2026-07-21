using System.Windows;
using System.Windows.Controls;
using CodeIsland.Hooks;
using System.IO;
using WpfButton = System.Windows.Controls.Button;
using System.Windows.Input;
using System.Windows.Media.Imaging;
using System.Windows.Media;

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
        LanguageBox.SelectionChanged += (_, _) => RefreshAllLanguage();
        LanguageBox.PreviewMouseLeftButtonDown += (_, _) => LanguageBox.IsDropDownOpen = true;
        DisplayModeBox.PreviewMouseLeftButtonDown += (_, _) => DisplayModeBox.IsDropDownOpen = true;
        ApplyToForm(settings, includeRegistryState: true);
        RefreshAllLanguage();
        ShortcutStatus.Text = Localize(hotKeyStatus());
        RefreshHooks();
    }

    private void RefreshLanguageFixed()
    {
        var zh = L10n.ResolveLanguage((LanguageBox.SelectedItem as ComboBoxItem)?.Tag?.ToString() ?? "system") == "zh-CN";
        Title = zh ? "CodeIsland 设置" : "CodeIsland Settings";
        var text = new Dictionary<string,string>(StringComparer.OrdinalIgnoreCase)
        {
            ["GENERAL"] = zh ? "\u5e38\u89c4" : "GENERAL", ["BEHAVIOR"] = zh ? "\u884c\u4e3a" : "BEHAVIOR", ["APPEARANCE"] = zh ? "\u5916\u89c2" : "APPEARANCE", ["SOUND"] = zh ? "\u58f0\u97f3" : "SOUND", ["HOOKS"] = zh ? "\u6302\u94a9" : "HOOKS", ["SHORTCUTS"] = zh ? "\u5feb\u6377\u952e" : "SHORTCUTS", ["ABOUT"] = zh ? "\u5173\u4e8e" : "ABOUT",
            ["LANGUAGE"] = zh ? "\u8bed\u8a00" : "LANGUAGE", ["DISPLAY"] = zh ? "\u663e\u793a" : "DISPLAY", ["System"] = zh ? "\u7cfb\u7edf" : "System", ["English"] = zh ? "\u82f1\u8bed" : "English", ["简体中文"] = zh ? "\u7b80\u4f53\u4e2d\u6587" : "Simplified Chinese",
            ["Launch CodeIsland when I sign in"] = zh ? "\u767b\u5f55\u65f6\u542f\u52a8 CodeIsland" : "Launch CodeIsland when I sign in", ["Primary display"] = zh ? "\u4e3b\u663e\u793a\u5668" : "Primary display", ["Display under cursor"] = zh ? "\u5149\u6807\u6240\u5728\u663e\u793a\u5668" : "Display under cursor", ["Settings are stored in your roaming AppData folder."] = zh ? "\u8bbe\u7f6e\u4fdd\u5b58\u5728\u6f2b\u6e38 AppData \u6587\u4ef6\u5939\u4e2d\u3002" : "Settings are stored in your roaming AppData folder.",
            ["SAVE"] = zh ? "\u4fdd\u5b58" : "SAVE", ["CANCEL"] = zh ? "\u53d6\u6d88" : "CANCEL", ["IMPORT"] = zh ? "\u5bfc\u5165" : "IMPORT", ["EXPORT"] = zh ? "\u5bfc\u51fa" : "EXPORT", ["DEFAULTS"] = zh ? "\u9ed8\u8ba4\u503c" : "DEFAULTS", ["REFRESH"] = zh ? "\u5237\u65b0" : "REFRESH", ["INSTALL"] = zh ? "\u5b89\u88c5" : "INSTALL", ["REPAIR"] = zh ? "\u4fee\u590d" : "REPAIR", ["REMOVE"] = zh ? "\u79fb\u9664" : "REMOVE", ["CODEISLAND / SETTINGS"] = zh ? "CODEISLAND / \u8bbe\u7f6e" : "CODEISLAND / SETTINGS",
            ["\u5e38\u89c4"] = zh ? "\u5e38\u89c4" : "GENERAL", ["\u884c\u4e3a"] = zh ? "\u884c\u4e3a" : "BEHAVIOR", ["\u5916\u89c2"] = zh ? "\u5916\u89c2" : "APPEARANCE", ["\u58f0\u97f3"] = zh ? "\u58f0\u97f3" : "SOUND", ["\u6302\u94a9"] = zh ? "\u6302\u94a9" : "HOOKS", ["\u5feb\u6377\u952e"] = zh ? "\u5feb\u6377\u952e" : "SHORTCUTS", ["\u5173\u4e8e"] = zh ? "\u5173\u4e8e" : "ABOUT", ["\u8bed\u8a00"] = zh ? "\u8bed\u8a00" : "LANGUAGE", ["\u663e\u793a"] = zh ? "\u663e\u793a" : "DISPLAY"
        };
        foreach (var e in FindVisualChildren<FrameworkElement>(this))
        {
            if (e is TextBlock tb && text.TryGetValue(tb.Text, out var tv)) tb.Text = tv;
            else if (e is WpfButton b && b.Content is string bs && text.TryGetValue(bs, out var bv)) b.Content = bv;
            else if (e is System.Windows.Controls.CheckBox cb && cb.Content is string cs && text.TryGetValue(cs, out var cv)) cb.Content = cv;
            else if (e is ComboBoxItem ci && ci.Content is string isv && text.TryGetValue(isv, out var iv)) ci.Content = iv;
            else if (e is TabItem ti && ti.Header is string hs && text.TryGetValue(hs, out var hv)) ti.Header = hv;
        }
    }

    private void RefreshLanguageChinese()
    {
        var zh = L10n.ResolveLanguage((LanguageBox.SelectedItem as ComboBoxItem)?.Tag?.ToString() ?? "system") == "zh-CN";
        var map = new Dictionary<string,string>(StringComparer.OrdinalIgnoreCase) {
            ["GENERAL"]=zh?"常规":"GENERAL", ["BEHAVIOR"]=zh?"行为":"BEHAVIOR", ["APPEARANCE"]=zh?"外观":"APPEARANCE", ["SOUND"]=zh?"声音":"SOUND", ["HOOKS"]=zh?"挂钩":"HOOKS", ["SHORTCUTS"]=zh?"快捷键":"SHORTCUTS", ["ABOUT"]=zh?"关于":"ABOUT", ["LANGUAGE"]=zh?"语言":"LANGUAGE", ["DISPLAY"]=zh?"显示":"DISPLAY", ["System"]=zh?"系统":"System", ["English"]=zh?"英语":"English", ["SAVE"]=zh?"保存":"SAVE", ["CANCEL"]=zh?"取消":"CANCEL", ["REFRESH"]=zh?"刷新":"REFRESH", ["INSTALL"]=zh?"安装":"INSTALL", ["REPAIR"]=zh?"修复":"REPAIR", ["REMOVE"]=zh?"移除":"REMOVE", ["IMPORT"]=zh?"导入":"IMPORT", ["EXPORT"]=zh?"导出":"EXPORT", ["DEFAULTS"]=zh?"默认值":"DEFAULTS", ["Launch CodeIsland when I sign in"]=zh?"登录时启动 CodeIsland":"Launch CodeIsland when I sign in", ["Settings are stored in your roaming AppData folder."]=zh?"设置保存在漫游 AppData 文件夹中。":"Settings are stored in your roaming AppData folder."
        };
        foreach (var e in FindVisualChildren<FrameworkElement>(this)) { if (e is TextBlock t && map.TryGetValue(t.Text, out var a)) t.Text=a; else if (e is WpfButton b && b.Content is string s && map.TryGetValue(s, out var c)) b.Content=c; else if (e is System.Windows.Controls.CheckBox x && x.Content is string q && map.TryGetValue(q, out var d)) x.Content=d; else if (e is TabItem tab && tab.Header is string h && map.TryGetValue(h, out var z)) tab.Header=z; }
    }

    private void RefreshLanguage()
    {
        var lang = (LanguageBox.SelectedItem as ComboBoxItem)?.Tag?.ToString() ?? "system";
        var zh = L10n.ResolveLanguage(lang) == "zh-CN";
        var map = new Dictionary<string,string>(StringComparer.OrdinalIgnoreCase) {
            ["GENERAL"]=zh?"常规":"GENERAL", ["BEHAVIOR"]=zh?"行为":"BEHAVIOR", ["APPEARANCE"]=zh?"外观":"APPEARANCE", ["SOUND"]=zh?"声音":"SOUND", ["HOOKS"]=zh?"挂钩":"HOOKS", ["SHORTCUTS"]=zh?"快捷键":"SHORTCUTS", ["ABOUT"]=zh?"关于":"ABOUT",
            ["LANGUAGE"]=zh?"语言":"LANGUAGE", ["DISPLAY"]=zh?"显示":"DISPLAY", ["System"]=zh?"系统":"System", ["English"]=zh?"英语":"English", ["Launch CodeIsland when I sign in"]=zh?"登录时启动 CodeIsland":"Launch CodeIsland when I sign in", ["Primary display"]=zh?"主显示器":"Primary display", ["Display under cursor"]=zh?"光标所在显示器":"Display under cursor", ["SAVE"]=zh?"保存":"SAVE", ["CANCEL"]=zh?"取消":"CANCEL", ["SETTINGS"]=zh?"设置":"SETTINGS"
        };
        foreach (var element in FindVisualChildren<FrameworkElement>(this)) {
            if (element is TextBlock t && map.TryGetValue(t.Text, out var tx)) t.Text = tx;
            else if (element is WpfButton b && b.Content is string bs && map.TryGetValue(bs, out var bx)) b.Content = bx;
            else if (element is System.Windows.Controls.CheckBox c && c.Content is string cs && map.TryGetValue(cs, out var cx)) c.Content = cx;
            else if (element is ComboBoxItem i && i.Content is string isx && map.TryGetValue(isx, out var ix)) i.Content = ix;
            else if (element is TabItem tab && tab.Header is string hs && map.TryGetValue(hs, out var hx)) tab.Header = hx;
        }
    }
    private static readonly IReadOnlyDictionary<string, string> Chinese = new Dictionary<string, string>(StringComparer.Ordinal)
    {
        ["CODEISLAND / SETTINGS"] = "CODEISLAND / 设置", ["GENERAL"] = "常规", ["BEHAVIOR"] = "行为", ["APPEARANCE"] = "外观", ["SOUND"] = "声音", ["HOOKS"] = "挂钩", ["SHORTCUTS"] = "快捷键", ["ABOUT"] = "关于",
        ["LANGUAGE"] = "语言", ["DISPLAY"] = "显示", ["System"] = "系统", ["Simplified Chinese"] = "简体中文", ["English"] = "英语", ["Launch CodeIsland when I sign in"] = "登录时启动 CodeIsland", ["Primary display"] = "主显示器", ["Display under cursor"] = "光标所在显示器", ["Settings are stored in your roaming AppData folder."] = "设置保存在漫游 AppData 文件夹中。",
        ["SESSION CLEANUP (MINUTES)"] = "会话清理时间（分钟）", ["Hide panel in full-screen applications"] = "在全屏应用中隐藏面板", ["Inactive sessions are removed automatically after this period."] = "非活动会话将在此时间后自动移除。", ["Maximum visible sessions"] = "最大可见会话数", ["Event history limit"] = "事件历史记录上限",
        ["Play sounds for session events"] = "为会话事件播放声音", ["Sounds are played for start, approval, completion and error events."] = "在开始、审批、完成和错误事件发生时播放声音。", ["REFRESH"] = "刷新", ["TOOL"] = "工具", ["EXE"] = "程序", ["HOOK"] = "挂钩", ["HEALTH"] = "健康状态", ["STATUS"] = "状态", ["ACTIONS"] = "操作", ["INSTALL"] = "安装", ["REPAIR"] = "修复", ["REMOVE"] = "移除",
        ["Toggle panel"] = "显示或隐藏面板", ["Approve request"] = "批准请求", ["Deny request"] = "拒绝请求", ["Format: Ctrl+Shift+I, Alt+Shift+A, or Win+Ctrl+D"] = "格式：Ctrl+Shift+I、Alt+Shift+A 或 Win+Ctrl+D", ["CODEISLAND FOR WINDOWS"] = "CODEISLAND WINDOWS 版", ["Version 0.1.0"] = "版本 0.1.0", ["Real-time AI coding agent status panel."] = "实时 AI 编程代理状态面板。", ["MIT License"] = "MIT 许可证",
        ["IMPORT"] = "导入", ["EXPORT"] = "导出", ["DEFAULTS"] = "恢复默认值", ["CANCEL"] = "取消", ["SAVE"] = "保存", ["Minimize"] = "最小化", ["Close"] = "关闭", ["Shortcuts are not registered yet."] = "快捷键尚未注册。", ["Shortcuts are unavailable."] = "快捷键不可用。"
    };

    private bool IsChinese => L10n.ResolveLanguage((LanguageBox.SelectedItem as ComboBoxItem)?.Tag?.ToString() ?? "zh-CN") == "zh-CN";

    private string Localize(string value)
    {
        var english = Chinese.ContainsKey(value) ? value : Chinese.FirstOrDefault(pair => pair.Value == value).Key ?? value;
        return IsChinese && Chinese.TryGetValue(english, out var translated) ? translated : english;
    }

    private string Text(string english, string chinese) => IsChinese ? chinese : english;

    private void RefreshAllLanguage()
    {
        Title = IsChinese ? "CodeIsland 设置" : "CodeIsland Settings";
        foreach (var element in FindLogicalChildren<FrameworkElement>(this))
        {
            if (element is TextBlock text) text.Text = Localize(text.Text);
            else if (element is WpfButton button && button.Content is string buttonText) button.Content = Localize(buttonText);
            else if (element is System.Windows.Controls.CheckBox checkBox && checkBox.Content is string checkBoxText) checkBox.Content = Localize(checkBoxText);
            else if (element is ComboBoxItem item && item.Content is string itemText) item.Content = Localize(itemText);
            else if (element is TabItem tab && tab.Header is string header) tab.Header = Localize(header);
            if (element.ToolTip is string toolTip) element.ToolTip = Localize(toolTip);
        }
        foreach (var column in HooksGrid.Columns)
            if (column.Header is string header) column.Header = Localize(header);
    }

    private void OnSettingsTabChanged(object sender, SelectionChangedEventArgs e)
    {
        if (!ReferenceEquals(e.Source, SettingsTabs)) return;
        Dispatcher.BeginInvoke(RefreshAllLanguage);
    }

    private static IEnumerable<T> FindLogicalChildren<T>(DependencyObject parent) where T : DependencyObject
    {
        foreach (var child in LogicalTreeHelper.GetChildren(parent))
        {
            if (child is T typed) yield return typed;
            if (child is DependencyObject dependencyObject)
                foreach (var descendant in FindLogicalChildren<T>(dependencyObject)) yield return descendant;
        }
    }

    private static IEnumerable<T> FindVisualChildren<T>(DependencyObject d) where T : DependencyObject { if (d == null) yield break; for (var i=0;i<VisualTreeHelper.GetChildrenCount(d);i++) { var c=VisualTreeHelper.GetChild(d,i); if (c is T t) yield return t; foreach (var x in FindVisualChildren<T>(c)) yield return x; } }

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
        GeneralStatus.Text = Text("Defaults loaded. Select Save to apply them.", "已加载默认设置。选择“保存”以应用。");
    }

    private void OnImport(object sender, RoutedEventArgs e)
    {
        var dialog = new Microsoft.Win32.OpenFileDialog { Filter = Text("CodeIsland settings (*.json)|*.json|All files (*.*)|*.*", "CodeIsland 设置 (*.json)|*.json|所有文件 (*.*)|*.*") };
        if (dialog.ShowDialog(this) != true) return;
        try
        {
            _settings = SettingsStore.Import(dialog.FileName);
            ApplyToForm(_settings);
            GeneralStatus.Text = Text($"Imported {Path.GetFileName(dialog.FileName)}. Select Save to apply.", $"已导入 {Path.GetFileName(dialog.FileName)}。选择“保存”以应用。");
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
            Filter = Text("CodeIsland settings (*.json)|*.json", "CodeIsland 设置 (*.json)|*.json"),
            FileName = "codeisland-settings.json",
            DefaultExt = ".json"
        };
        if (dialog.ShowDialog(this) != true) return;
        _store.Export(dialog.FileName, ReadForm());
        GeneralStatus.Text = Text($"Exported to {Path.GetFileName(dialog.FileName)}.", $"已导出到 {Path.GetFileName(dialog.FileName)}。");
    }

    private AppSettings ReadForm()
    {
        var shortcuts = new[] { ToggleShortcutBox.Text, ApproveShortcutBox.Text, DenyShortcutBox.Text };
        if (shortcuts.Any(value => !HotKeyBinding.TryParse(value, out _)))
            throw new InvalidOperationException(Text("Each shortcut must contain modifiers and one letter or digit.", "每个快捷键必须包含修饰键以及一个字母或数字。"));
        var normalized = shortcuts.Select(value =>
        {
            HotKeyBinding.TryParse(value, out var binding);
            return binding.ToString();
        }).ToArray();
        if (normalized.Distinct(StringComparer.OrdinalIgnoreCase).Count() != normalized.Length)
            throw new InvalidOperationException(Text("Shortcuts must be unique.", "快捷键不能重复。"));
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
                throw new FileNotFoundException(Text("CodeIsland.Bridge.exe was not found. Build or reinstall CodeIsland.", "未找到 CodeIsland.Bridge.exe。请构建或重新安装 CodeIsland。"));
            var fileStore = new HookFileStore();
            var manager = new HookManager(new ToolDetector(store: fileStore), fileStore);
            var status = operation switch
            {
                HookOperation.Install => manager.Install(tool, bridge!),
                HookOperation.Repair => manager.Repair(tool, bridge!),
                HookOperation.Uninstall => manager.Uninstall(tool),
                _ => throw new ArgumentOutOfRangeException(nameof(operation))
            };
            var action = operation switch
            {
                HookOperation.Install => Text("installation", "安装"),
                HookOperation.Repair => Text("repair", "修复"),
                HookOperation.Uninstall => Text("removal", "移除"),
                _ => operation.ToString()
            };
            HookOperationStatus.Text = IsChinese
                ? $"{tool.DisplayName}：{action}完成。健康状态={status.IsHealthy}"
                : $"{tool.DisplayName}: {action} completed. Healthy={status.IsHealthy}";
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException or InvalidOperationException)
        {
            HookOperationStatus.Text = $"{tool.DisplayName}: {ex.Message}";
        }
        RefreshHooks();
    }

    private enum HookOperation { Install, Repair, Uninstall }
}
