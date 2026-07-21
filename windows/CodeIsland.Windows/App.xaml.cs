using System.Configuration;
using System.Data;
using System.Windows;

using System.Threading;
using System.Windows.Forms;
using CodeIsland.Ipc;
using CodeIsland.Core;
using System.Windows.Threading;
using System.IO;
using CodeIsland.Hooks;
using Application = System.Windows.Application;

namespace CodeIsland.Windows;

public partial class App : Application
{
    private const string InstanceMutexName = "CodeIsland.Windows.SingleInstance.v5";
    private const string ShowPanelEventName = "CodeIsland.Windows.ShowPanel.v5";
    private Mutex? _instanceMutex;
    private EventWaitHandle? _showPanelEvent;
    private RegisteredWaitHandle? _showPanelRegistration;
    private NotifyIcon? _tray;
    private System.Drawing.Icon? _appIcon;
    private MainWindow? _window;
    private PipeServer? _pipeServer;
    private CancellationTokenSource? _pipeStop;
    private Task? _pipeTask;
    private DispatcherTimer? _cleanupTimer;
    private DispatcherTimer? _fullscreenTimer;
    private bool _fullscreenSuppressed;
    private DateTimeOffset _manualShowUntil;
    private CodexSessionTailer? _codexTailer;
    private readonly NotificationSoundManager _sounds = new();
    private readonly SettingsStore _settingsStore = new();
    private SettingsWindow? _settingsWindow;
    private ContextMenuStrip? _trayMenu;
    private readonly AppLogger _logger = new();
    public DesktopSessionStore Sessions { get; private set; } = null!;
    private AppSettings _settings = new();

    protected override void OnStartup(StartupEventArgs e)
    {
        _instanceMutex = new Mutex(true, InstanceMutexName, out var created);
        if (!created)
        {
            try
            {
                using var showPanel = EventWaitHandle.OpenExisting(ShowPanelEventName);
                showPanel.Set();
            }
            catch (Exception ex) when (ex is WaitHandleCannotBeOpenedException or UnauthorizedAccessException) { }
            Shutdown(2);
            return;
        }

        _showPanelEvent = new EventWaitHandle(false, EventResetMode.AutoReset, ShowPanelEventName);
        _showPanelRegistration = ThreadPool.RegisterWaitForSingleObject(_showPanelEvent, (_, _) =>
            Dispatcher.BeginInvoke(ShowPanel), null, Timeout.Infinite, false);

        _settings = _settingsStore.Load();
        _logger.Info("Application startup.");
        RepairOutdatedHooks();
        L10n.Apply(Resources, _settings.Language);
        Sessions = new DesktopSessionStore(_settings.MaxVisibleSessions, _settings.EventHistoryLimit);
        _sounds.Enabled = _settings.SoundEnabled;
        StartPipeServer();
        Sessions.EventApplied += (_, agentEvent) =>
        {
            _sounds.Play(agentEvent);
            _logger.Info($"Event received: agent={agentEvent.Agent} type={agentEvent.Type} tool={agentEvent.ToolName ?? "-"} session={agentEvent.SessionId}");
            if (PanelAttentionPolicy.RequiresExpansion(agentEvent))
                Dispatcher.BeginInvoke(() =>
                {
                    _window?.ExpandPanel();
                    ShowPanel();
                });
        };
        _codexTailer = new CodexSessionTailer();
        _codexTailer.EventReceived += (_, agentEvent) => Dispatcher.Invoke(() => Sessions.Apply(agentEvent));
        _codexTailer.Start();
        _window = new MainWindow(Sessions, _settings);
        _manualShowUntil = DateTimeOffset.UtcNow.AddSeconds(30);
        try
        {
            _window.Show();
        }
        catch (Exception ex)
        {
            _logger.Error("Main window startup failed", ex);
            Shutdown(3);
            return;
        }
        _fullscreenTimer = new DispatcherTimer { Interval = TimeSpan.FromMilliseconds(500) };
        _fullscreenTimer.Tick += (_, _) => UpdateFullscreenVisibility();
        _fullscreenTimer.Start();
        _cleanupTimer = new DispatcherTimer { Interval = TimeSpan.FromMinutes(1) };
        _cleanupTimer.Tick += (_, _) => Sessions.RemoveExpired(DateTimeOffset.UtcNow.AddMinutes(-_settings.SessionCleanupMinutes));
        _cleanupTimer.Start();
        var iconPath = Path.Combine(AppContext.BaseDirectory, "source", "codeisland.ico");
        _appIcon = File.Exists(iconPath)
            ? new System.Drawing.Icon(iconPath)
            : (System.Drawing.Icon)System.Drawing.SystemIcons.Application.Clone();
        _tray = new NotifyIcon
        {
            Icon = _appIcon,
            Visible = true,
            Text = "CodeIsland"
        };
        RebuildTrayMenu();
        _tray.DoubleClick += (_, _) => ShowPanel();
        if (e.Args.Contains("--settings", StringComparer.OrdinalIgnoreCase)) OpenSettings();
        base.OnStartup(e);
    }

    private void RepairOutdatedHooks()
    {
        var bridge = BridgeLocator.FindCurrent();
        if (bridge is null) return;
        try
        {
            var files = new HookFileStore();
            var detector = new ToolDetector(store: files);
            var manager = new HookManager(detector, files);
            foreach (var status in detector.DetectAll().Where(value => value.HookInstalled && !value.IsHealthy))
            {
                manager.Repair(status.Tool, bridge);
                _logger.Info($"Outdated hook repaired: {status.Tool.DisplayName}");
            }
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException or InvalidOperationException)
        {
            _logger.Error("Automatic hook repair failed", ex);
        }
    }

    private void ExportDiagnostics()
    {
        var dialog = new Microsoft.Win32.SaveFileDialog
        {
            Filter = "CodeIsland diagnostics (*.zip)|*.zip",
            FileName = $"codeisland-diagnostics-{DateTime.Now:yyyyMMdd-HHmmss}.zip",
            DefaultExt = ".zip"
        };
        if (dialog.ShowDialog() != true) return;
        try
        {
            new DiagnosticsExporter().Export(dialog.FileName, _settings, Sessions, _logger.LogDirectory);
            _logger.Info("Diagnostics exported.");
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
        {
            _logger.Error("Diagnostics export failed", ex);
            System.Windows.MessageBox.Show(ex.Message, "CodeIsland", MessageBoxButton.OK, MessageBoxImage.Error);
        }
    }

    internal void OpenSettings()
    {
        if (_settingsWindow is { IsVisible: true })
        {
            _settingsWindow.Activate();
            return;
        }
        _settingsWindow = new SettingsWindow(_settingsStore, _settings, ApplySettings,
            () => _window?.HotKeyStatus ?? "Shortcuts are unavailable.");
        _settingsWindow.Closed += (_, _) => _settingsWindow = null;
        _settingsWindow.Show();
    }

    internal bool ToggleSound()
    {
        _settings = _settings with { SoundEnabled = !_settings.SoundEnabled };
        _settingsStore.Save(_settings);
        _sounds.Enabled = _settings.SoundEnabled;
        return _settings.SoundEnabled;
    }

    private void ApplySettings(AppSettings settings)
    {
        _settings = settings;
        _sounds.Enabled = settings.SoundEnabled;
        L10n.Apply(Resources, settings.Language);
        RebuildTrayMenu();
        _window?.ApplySettings(settings);
        if (!settings.HideInFullscreen && _fullscreenSuppressed && _window is not null)
        {
            _window.Show();
            _fullscreenSuppressed = false;
        }
    }

    private void RebuildTrayMenu()
    {
        if (_tray is null) return;
        _trayMenu?.Dispose();
        _trayMenu = TrayMenuFactory.Create(_settings.Language, ShowPanel, () => _window?.Hide(), OpenSettings, ExportDiagnostics, RequestExit);
        _tray.ContextMenuStrip = _trayMenu;
    }

    private void UpdateFullscreenVisibility()
    {
        if (_window is null || !_settings.HideInFullscreen) return;
        if (DateTimeOffset.UtcNow < _manualShowUntil) return;
        var fullscreen = FullscreenDetector.IsFullscreenForeground(_window.NativeHandle);
        if (fullscreen && _window.IsVisible)
        {
            _window.Hide();
            _fullscreenSuppressed = true;
        }
        else if (!fullscreen && _fullscreenSuppressed)
        {
            _window.Show();
            _fullscreenSuppressed = false;
        }
    }

    private void StartPipeServer()
    {
        _pipeStop = new CancellationTokenSource();
        _pipeServer = new PipeServer(async (message, cancellationToken) =>
        {
            if (message.Type == PipeMessageType.Event && message.Event is not null)
            {
                if (message.Event.Type is AgentEventType.PermissionRequest or AgentEventType.Question)
                {
                    Task<PipeMessage>? responseTask = null;
                    Dispatcher.Invoke(() => { responseTask = Sessions.WaitForResponseAsync(message.Event, cancellationToken); });
                    return await responseTask!;
                }
                Dispatcher.Invoke(() => Sessions.Apply(message.Event));
                return new PipeMessage(PipeMessageType.Ack, Guid.NewGuid().ToString("N"), AckFor: message.MessageId);
            }
            if (message.Type is PipeMessageType.Hello or PipeMessageType.Heartbeat)
                return new PipeMessage(PipeMessageType.Ack, Guid.NewGuid().ToString("N"), AckFor: message.MessageId);
            return new PipeMessage(PipeMessageType.Error, Guid.NewGuid().ToString("N"), Error: "Unsupported message.");
        });
        _pipeTask = _pipeServer.RunAsync(_pipeStop.Token);
    }

    private void ShowPanel()
    {
        if (_window is null) return;
        _manualShowUntil = DateTimeOffset.UtcNow.AddSeconds(30);
        _fullscreenSuppressed = false;
        _window.Show();
        if (_window.WindowState == WindowState.Minimized) _window.WindowState = WindowState.Normal;
        _window.Activate();
    }

    internal void RequestExit()
    {
        if (!Dispatcher.CheckAccess())
        {
            Dispatcher.BeginInvoke(RequestExit);
            return;
        }
        if (_tray is not null) _tray.Visible = false;
        Shutdown();
    }

    protected override void OnExit(ExitEventArgs e)
    {
        _pipeStop?.Cancel();
        _codexTailer?.Dispose();
        _logger.Info("Application exit.");
        _cleanupTimer?.Stop();
        _fullscreenTimer?.Stop();
        if (_tray is not null)
        {
            _tray.Visible = false;
            _tray.Dispose();
            _tray = null;
        }
        if (_pipeTask is { IsCompleted: true })
        {
            try { _pipeTask.GetAwaiter().GetResult(); }
            catch (OperationCanceledException) { }
        }
        _pipeServer?.DisposeAsync().AsTask().GetAwaiter().GetResult();
        _pipeStop?.Dispose();
        _appIcon?.Dispose();
        _showPanelRegistration?.Unregister(null);
        _showPanelEvent?.Dispose();
        _instanceMutex?.Dispose();
        base.OnExit(e);
    }
}

