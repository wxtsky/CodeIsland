using System.Text;
using System.Windows;
using CodeIsland.Ipc;
using System.Windows.Controls;
using WpfButton = System.Windows.Controls.Button;
using WpfTextBox = System.Windows.Controls.TextBox;
using System.Windows.Data;
using System.Windows.Documents;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using System.Windows.Navigation;
using System.Windows.Shapes;
using System.Windows.Interop;
using System.Windows.Media.Animation;
using System.ComponentModel;
using CodeIsland.Core;

namespace CodeIsland.Windows;

/// <summary>
/// Interaction logic for MainWindow.xaml
/// </summary>
public partial class MainWindow : Window
{
    private bool _expanded = true;
    private const double ExpandedWidth = 780;
    private const double CollapsedWidth = 320;
    private const double CollapsedHeight = 40;
    private readonly DesktopSessionStore _sessions;
    private readonly Dictionary<string, string> _answerDrafts = new(StringComparer.Ordinal);
    private GlobalHotKeyManager? _hotKeys;
    private HwndSource? _source;
    private AppSettings _settings;
    private readonly TerminalActivator _terminalActivator = new();
    private readonly WorkspaceLauncher _workspaceLauncher = new();
    private ICollectionView? _sessionView;
    private System.Windows.Point _sessionDragStart;
    private string _filter = "all";
    private DockEdges _dockEdges = DockEdges.Top;
    public string HotKeyStatus => _hotKeys?.RegistrationSummary ?? "Shortcuts are not registered yet.";
    public IntPtr NativeHandle => new WindowInteropHelper(this).Handle;

    public MainWindow(DesktopSessionStore sessions, AppSettings settings)
    {
        InitializeComponent();
        _sessions = sessions;
        _settings = settings;
        SoundButton.Content = settings.SoundEnabled ? "\uE767" : "\uE74F";
        SoundButton.ToolTip = settings.SoundEnabled ? "Mute notifications" : "Enable notification sounds";
        _sessions.EventApplied += OnEventApplied;
        _sessions.PropertyChanged += OnSessionsChanged;
        DataContext = sessions;
        Loaded += (_, _) =>
        {
            PositionPanel();
            _sessionView = CollectionViewSource.GetDefaultView(_sessions.Sessions);
            if (_sessionView.GroupDescriptions.Count == 0)
                _sessionView.GroupDescriptions.Add(new PropertyGroupDescription(nameof(SessionSnapshot.Agent)));
            _sessionView.Filter = IsSessionVisible;
        };
        SourceInitialized += (_, _) =>
        {
            if (PresentationSource.FromVisual(this) is HwndSource source)
            {
                _source = source;
                RegisterHotKeys();
            }
        };
        Closed += (_, _) =>
        {
            _hotKeys?.Dispose();
            _sessions.EventApplied -= OnEventApplied;
            _sessions.PropertyChanged -= OnSessionsChanged;
        };
        StateChanged += (_, _) => { if (WindowState == WindowState.Minimized) Hide(); };
        MouseLeftButtonDown += OnPanelMouseDown;
        MouseDoubleClick += (_, _) => TogglePanel();
    }

    public void ApplySettings(AppSettings settings)
    {
        _settings = settings;
        SoundButton.Content = settings.SoundEnabled ? "\uE767" : "\uE74F";
        SoundButton.ToolTip = settings.SoundEnabled ? "Mute notifications" : "Enable notification sounds";
        PositionPanel();
        if (_source is not null) RegisterHotKeys();
    }

    private void RegisterHotKeys()
    {
        _hotKeys?.Dispose();
        _hotKeys = new GlobalHotKeyManager(_source!, _settings, TogglePanel,
            () => _sessions.ResolveCurrent(UserAction.Approve),
            () => _sessions.ResolveCurrent(UserAction.Deny));
    }

    private void OnApproveClick(object sender, RoutedEventArgs e) => Resolve(sender, UserAction.Approve);
    private void OnDenyClick(object sender, RoutedEventArgs e) => Resolve(sender, UserAction.Deny);
    private void OnAlwaysAllowClick(object sender, RoutedEventArgs e) => Resolve(sender, UserAction.AlwaysAllow);

    private void Resolve(object sender, UserAction action)
    {
        if (sender is WpfButton { Tag: string eventId }) _sessions.Resolve(eventId, action);
    }

    private void OnAnswerChanged(object sender, TextChangedEventArgs e)
    {
        if (sender is WpfTextBox { Tag: string eventId } textBox) _answerDrafts[eventId] = textBox.Text;
    }

    private void OnAnswerClick(object sender, RoutedEventArgs e)
    {
        if (sender is not WpfButton { Tag: string eventId }) return;
        _answerDrafts.TryGetValue(eventId, out var answer);
        if (string.IsNullOrWhiteSpace(answer)) return;
        if (_sessions.Resolve(eventId, UserAction.Answer, answer)) _answerDrafts.Remove(eventId);
    }

    private void OnSessionsChanged(object? sender, PropertyChangedEventArgs e)
    {
        if (e.PropertyName is nameof(DesktopSessionStore.Sessions) or nameof(DesktopSessionStore.SessionCount))
            Dispatcher.BeginInvoke(() => _sessionView?.Refresh());
    }

    private bool IsSessionVisible(object value) =>
        value is SessionSnapshot session && SessionFilter.IsVisible(session, _filter);

    private void OnFilterClick(object sender, MouseButtonEventArgs e)
    {
        if (sender is not FrameworkElement { Tag: string filter }) return;
        _filter = filter;
        _sessionView?.Refresh();
        foreach (var border in new[] { AllFilter, ActiveFilter, CliFilter })
        {
            border.Background = border.Tag is string tag && tag == _filter
                ? new SolidColorBrush(System.Windows.Media.Color.FromRgb(36, 36, 38))
                : new SolidColorBrush(System.Windows.Media.Color.FromRgb(22, 22, 24));
        }
        e.Handled = true;
    }

    private void OnJumpClick(object sender, RoutedEventArgs e)
    {
        if (sender is not WpfButton { Tag: SessionSnapshot snapshot }) return;
        var activated = _terminalActivator.TryActivate(snapshot.ProcessId, snapshot.WorkingDirectory);
        if (!activated) activated = _workspaceLauncher.TryLaunch(snapshot.Agent, snapshot.TerminalKind, snapshot.WorkingDirectory);
        if (!activated) ToolTip = "No matching terminal or IDE was found, and no fallback launcher is available.";
    }

    private void OnJumpPillClick(object sender, MouseButtonEventArgs e)
    {
        if (sender is FrameworkElement { Tag: SessionSnapshot snapshot }) ActivateSession(snapshot);
        e.Handled = true;
    }

    private void OnSessionDragStart(object sender, MouseButtonEventArgs e)
    {
        if (IsInteractiveElement(e.OriginalSource as DependencyObject)) return;
        _sessionDragStart = e.GetPosition(this);
        e.Handled = true;
    }

    private void OnSessionDragMove(object sender, System.Windows.Input.MouseEventArgs e)
    {
        if (e.LeftButton != MouseButtonState.Pressed || sender is not FrameworkElement { Tag: SessionSnapshot snapshot } card)
            return;
        var position = e.GetPosition(this);
        if (Math.Abs(position.X - _sessionDragStart.X) < SystemParameters.MinimumHorizontalDragDistance
            && Math.Abs(position.Y - _sessionDragStart.Y) < SystemParameters.MinimumVerticalDragDistance)
            return;
        System.Windows.DragDrop.DoDragDrop(card, snapshot.SessionId, System.Windows.DragDropEffects.Move);
    }

    private void OnSessionDragOver(object sender, System.Windows.DragEventArgs e)
    {
        e.Effects = e.Data.GetDataPresent(typeof(string))
            ? System.Windows.DragDropEffects.Move
            : System.Windows.DragDropEffects.None;
        e.Handled = true;
    }

    private void OnSessionDrop(object sender, System.Windows.DragEventArgs e)
    {
        if (sender is FrameworkElement { Tag: SessionSnapshot target }
            && e.Data.GetData(typeof(string)) is string sourceSessionId
            && _sessions.MoveSessionBefore(sourceSessionId, target.SessionId))
            _sessionView?.Refresh();
        e.Handled = true;
    }

    private void ActivateSession(SessionSnapshot snapshot)
    {
        if (_workspaceLauncher.TryLaunchConversation(snapshot.Agent, snapshot.TerminalKind, snapshot.SessionId)) return;
        var activated = _terminalActivator.TryActivate(snapshot.ProcessId, snapshot.WorkingDirectory);
        if (!activated) activated = _workspaceLauncher.TryLaunch(snapshot.Agent, snapshot.TerminalKind, snapshot.WorkingDirectory);
        if (!activated) ToolTip = "No matching terminal or IDE was found, and no fallback launcher is available.";
    }

    private void OnSettingsClick(object sender, RoutedEventArgs e) =>
        ((App)System.Windows.Application.Current).OpenSettings();

    private void OnSoundClick(object sender, RoutedEventArgs e)
    {
        var enabled = ((App)System.Windows.Application.Current).ToggleSound();
        SoundButton.Content = enabled ? "\uE767" : "\uE74F";
        SoundButton.ToolTip = enabled ? "Mute notifications" : "Enable notification sounds";
    }

    private void OnExitClick(object sender, RoutedEventArgs e) =>
        ((App)System.Windows.Application.Current).RequestExit();

    private void PositionPanel()
    {
        if (_dockEdges != DockEdges.None)
        {
            ApplyDockPlacement(_dockEdges);
            return;
        }
        var area = DisplayPositioner.SelectWorkingArea(_settings.DisplayMode);
        var transform = PresentationSource.FromVisual(this)?.CompositionTarget?.TransformToDevice;
        var position = DisplayPositioner.TopCenter(area, transform?.M11 ?? 1, transform?.M22 ?? 1, Width);
        Left = position.Left;
        Top = position.Top;
    }

    private void OnPanelMouseDown(object sender, MouseButtonEventArgs e)
    {
        if (e.ClickCount > 1 || IsInteractiveElement(e.OriginalSource as DependencyObject)) return;
        try
        {
            DragMove();
            var placement = PanelDocking.Resolve(GetWorkingArea(),
                new System.Windows.Size(ActualWidth, ActualHeight), new System.Windows.Point(Left, Top), radius: _expanded ? 24 : 18);
            _dockEdges = placement.Edges;
            ApplyPlacement(placement);
        }
        catch (InvalidOperationException) { }
    }

    private static bool IsInteractiveElement(DependencyObject? element)
    {
        while (element is not null)
        {
            if (element is WpfButton or WpfTextBox) return true;
            element = VisualTreeHelper.GetParent(element);
        }
        return false;
    }

    private Rect GetWorkingArea()
    {
        var area = DisplayPositioner.WorkingAreaForWindow(NativeHandle);
        var transform = PresentationSource.FromVisual(this)?.CompositionTarget?.TransformToDevice;
        var scaleX = transform?.M11 ?? 1;
        var scaleY = transform?.M22 ?? 1;
        return new Rect(area.Left / scaleX, area.Top / scaleY, area.Width / scaleX, area.Height / scaleY);
    }

    private void ApplyDockPlacement(DockEdges edges)
    {
        var placement = PanelDocking.Place(GetWorkingArea(), new System.Windows.Size(ActualWidth, ActualHeight),
            new System.Windows.Point(Left, Top), edges, _expanded ? 24 : 18);
        ApplyPlacement(placement);
    }

    private void ApplyPlacement(PanelDockPlacement placement)
    {
        Left = placement.Left;
        Top = placement.Top;
        PanelBorder.CornerRadius = placement.Corners;
        PanelBorder.BorderThickness = placement.Edges == DockEdges.None
            ? new Thickness(1)
            : new Thickness(0);
        var shoulderDepth = Math.Min(38, Math.Min(ActualWidth, ActualHeight) * .25);
        var shoulders = DockShoulderGeometry.Create(
            new System.Windows.Size(ActualWidth, ActualHeight), placement.Edges, shoulderDepth);
        DockShoulderFirst.Data = shoulders.First;
        DockShoulderSecond.Data = shoulders.Second;
        PanelBorder.Margin = placement.Edges.HasFlag(DockEdges.Top) || placement.Edges.HasFlag(DockEdges.Bottom)
            ? new Thickness(shoulderDepth, 0, shoulderDepth, 0)
            : placement.Edges.HasFlag(DockEdges.Left) || placement.Edges.HasFlag(DockEdges.Right)
                ? new Thickness(0, shoulderDepth, 0, shoulderDepth)
                : new Thickness(0);
    }

    public void TogglePanel()
    {
        var center = new System.Windows.Point(Left + ActualWidth / 2, Top + ActualHeight / 2);
        _expanded = !_expanded;
        ExpandedPanel.Visibility = _expanded ? Visibility.Visible : Visibility.Collapsed;
        CollapsedPanel.Visibility = _expanded ? Visibility.Collapsed : Visibility.Visible;
        if (_expanded)
        {
            ClearValue(HeightProperty);
            Width = ExpandedWidth;
            MaxHeight = 720;
            SizeToContent = SizeToContent.Height;
        }
        else
        {
            SizeToContent = SizeToContent.Manual;
            MaxHeight = CollapsedHeight;
            Width = CollapsedWidth;
            Height = CollapsedHeight;
        }
        UpdateLayout();
        var centeredPosition = new System.Windows.Point(center.X - ActualWidth / 2, center.Y - ActualHeight / 2);
        var placement = PanelDocking.Place(GetWorkingArea(), new System.Windows.Size(ActualWidth, ActualHeight),
            centeredPosition, _dockEdges, _expanded ? 24 : 18);
        ApplyPlacement(placement);
        AnimatePanelToggle(_expanded);
    }

    public void ExpandPanel()
    {
        if (!_expanded) TogglePanel();
    }

    private void AnimatePanelToggle(bool expanding)
    {
        if (!SystemParameters.ClientAreaAnimation) return;
        var easing = new CubicEase { EasingMode = EasingMode.EaseOut };
        var startScale = expanding ? 0.84 : 1.12;
        var duration = TimeSpan.FromMilliseconds(expanding ? 240 : 190);
        PanelScale.BeginAnimation(ScaleTransform.ScaleXProperty,
            new DoubleAnimation(startScale, 1, duration) { EasingFunction = easing });
        PanelScale.BeginAnimation(ScaleTransform.ScaleYProperty,
            new DoubleAnimation(startScale, 1, duration) { EasingFunction = easing });
        PanelChrome.BeginAnimation(OpacityProperty,
            new DoubleAnimation(0.68, 1, duration) { EasingFunction = easing });
    }

    private void OnEventApplied(object? sender, AgentEvent agentEvent)
    {
        if (PanelAttentionPolicy.RequiresExpansion(agentEvent))
            ExpandPanel();
        if (!SystemParameters.ClientAreaAnimation) return;
        var easing = new QuadraticEase { EasingMode = EasingMode.EaseOut };
        PanelScale.BeginAnimation(ScaleTransform.ScaleXProperty,
            new DoubleAnimation(0.96, 1, TimeSpan.FromMilliseconds(180)) { EasingFunction = easing });
        PanelScale.BeginAnimation(ScaleTransform.ScaleYProperty,
            new DoubleAnimation(0.96, 1, TimeSpan.FromMilliseconds(180)) { EasingFunction = easing });
        PanelBorder.BeginAnimation(OpacityProperty,
            new DoubleAnimation(0.72, 1, TimeSpan.FromMilliseconds(180)) { EasingFunction = easing });
    }
}
