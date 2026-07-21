using System.Globalization;
using System.Windows;
using System.Windows.Media;
using System.Windows.Threading;

namespace CodeIsland.Windows;

public sealed class WaveTextBlock : FrameworkElement
{
    public static readonly DependencyProperty TextProperty = DependencyProperty.Register(
        nameof(Text), typeof(string), typeof(WaveTextBlock),
        new FrameworkPropertyMetadata(string.Empty, FrameworkPropertyMetadataOptions.AffectsRender));

    public static readonly DependencyProperty IsAnimatingProperty = DependencyProperty.Register(
        nameof(IsAnimating), typeof(bool), typeof(WaveTextBlock),
        new FrameworkPropertyMetadata(false, OnAnimationChanged));

    private readonly DispatcherTimer _timer;
    private int _phase;

    public WaveTextBlock()
    {
        ClipToBounds = true;
        SnapsToDevicePixels = true;
        _timer = new DispatcherTimer(DispatcherPriority.Render)
        {
            Interval = TimeSpan.FromMilliseconds(80)
        };
        _timer.Tick += (_, _) =>
        {
            _phase++;
            InvalidateVisual();
        };
        Loaded += (_, _) =>
        {
            if (IsAnimating) _timer.Start();
        };
        Unloaded += (_, _) => _timer.Stop();
    }

    public string Text
    {
        get => (string)GetValue(TextProperty);
        set => SetValue(TextProperty, value);
    }

    public bool IsAnimating
    {
        get => (bool)GetValue(IsAnimatingProperty);
        set => SetValue(IsAnimatingProperty, value);
    }

    protected override void OnRender(DrawingContext drawingContext)
    {
        base.OnRender(drawingContext);
        if (string.IsNullOrEmpty(Text) || ActualWidth <= 0) return;

        drawingContext.PushClip(new RectangleGeometry(new Rect(0, 0, ActualWidth, ActualHeight)));
        var typeface = new Typeface(new System.Windows.Media.FontFamily("Cascadia Mono, Consolas"), FontStyles.Normal,
            FontWeights.Bold, FontStretches.Normal);
        var brush = new SolidColorBrush(System.Windows.Media.Color.FromRgb(57, 228, 110));
        brush.Freeze();
        var pixelsPerDip = VisualTreeHelper.GetDpi(this).PixelsPerDip;
        var elements = StringInfo.GetTextElementEnumerator(Text);
        var parts = new List<string>();
        while (elements.MoveNext()) parts.Add(elements.GetTextElement());

        var x = 0d;
        var crest = parts.Count == 0 ? -1 : _phase % (parts.Count + 3);
        for (var index = 0; index < parts.Count; index++)
        {
            var formatted = new FormattedText(parts[index], CultureInfo.CurrentUICulture,
                System.Windows.FlowDirection.LeftToRight, typeface, 14, brush, pixelsPerDip);
            if (x + formatted.WidthIncludingTrailingWhitespace > ActualWidth) break;
            var wavePosition = index - (crest - 2);
            var lift = IsAnimating ? wavePosition switch
            {
                0 => 1.5d,
                1 => 2.75d,
                2 => 4d,
                _ => 0d
            } : 0d;
            drawingContext.DrawText(formatted, new System.Windows.Point(x, 3 - lift));
            x += formatted.WidthIncludingTrailingWhitespace;
        }
        drawingContext.Pop();
    }

    private static void OnAnimationChanged(DependencyObject dependencyObject, DependencyPropertyChangedEventArgs args)
    {
        var control = (WaveTextBlock)dependencyObject;
        control._phase = 0;
        if ((bool)args.NewValue && control.IsLoaded) control._timer.Start();
        else control._timer.Stop();
        control.InvalidateVisual();
    }
}
