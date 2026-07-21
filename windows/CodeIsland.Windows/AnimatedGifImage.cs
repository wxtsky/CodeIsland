using System.IO;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media.Imaging;
using System.Windows.Threading;

namespace CodeIsland.Windows;

public sealed class AnimatedGifImage : System.Windows.Controls.Image
{
    public static readonly DependencyProperty SourcePathProperty = DependencyProperty.Register(
        nameof(SourcePath), typeof(string), typeof(AnimatedGifImage),
        new PropertyMetadata(null, OnSourcePathChanged));

    private readonly DispatcherTimer _timer = new() { Interval = TimeSpan.FromMilliseconds(120) };
    private BitmapFrame[] _frames = [];
    private int _frameIndex;

    public string? SourcePath
    {
        get => (string?)GetValue(SourcePathProperty);
        set => SetValue(SourcePathProperty, value);
    }

    public AnimatedGifImage()
    {
        Stretch = System.Windows.Media.Stretch.Uniform;
        StretchDirection = StretchDirection.DownOnly;
        SnapsToDevicePixels = true;
        _timer.Tick += (_, _) =>
        {
            if (_frames.Length == 0) return;
            _frameIndex = (_frameIndex + 1) % _frames.Length;
            Source = _frames[_frameIndex];
        };
        Unloaded += (_, _) => _timer.Stop();
    }

    private static void OnSourcePathChanged(DependencyObject d, DependencyPropertyChangedEventArgs e)
    {
        ((AnimatedGifImage)d).LoadFrames(e.NewValue as string);
    }

    private void LoadFrames(string? path)
    {
        _timer.Stop();
        _frames = [];
        _frameIndex = 0;
        if (string.IsNullOrWhiteSpace(path) || !File.Exists(path))
        {
            Source = null;
            return;
        }

        using var stream = File.OpenRead(path);
        var decoder = new GifBitmapDecoder(stream, BitmapCreateOptions.PreservePixelFormat, BitmapCacheOption.OnLoad);
        _frames = decoder.Frames.ToArray();
        Source = _frames.FirstOrDefault();
        if (_frames.Length > 1) _timer.Start();
    }
}
