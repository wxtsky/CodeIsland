using System.IO.Pipes;
using System.Text;
using System.Runtime.Versioning;

namespace CodeIsland.Ipc;

[SupportedOSPlatform("windows")]
public sealed class PipeClient : IAsyncDisposable
{
    private readonly string? _userSid;
    private NamedPipeClientStream? _pipe;
    private StreamReader? _reader;
    private StreamWriter? _writer;

    public PipeClient(string? userSid = null) => _userSid = userSid;

    public async Task ConnectAsync(TimeSpan timeout, CancellationToken cancellationToken = default)
    {
        _pipe = PipeEndpoint.CreateClient(_userSid);
        using var timeoutSource = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
        timeoutSource.CancelAfter(timeout);
        await _pipe.ConnectAsync(timeoutSource.Token);
        _reader = new StreamReader(_pipe, Encoding.UTF8, leaveOpen: true);
        _writer = new StreamWriter(_pipe, new UTF8Encoding(false), leaveOpen: true) { AutoFlush = true };
    }

    public async Task ConnectWithRetryAsync(
        int maxAttempts,
        TimeSpan connectTimeout,
        TimeSpan retryDelay,
        CancellationToken cancellationToken = default)
    {
        if (maxAttempts < 1) throw new ArgumentOutOfRangeException(nameof(maxAttempts));
        Exception? lastError = null;
        for (var attempt = 1; attempt <= maxAttempts; attempt++)
        {
            try
            {
                await ConnectAsync(connectTimeout, cancellationToken);
                return;
            }
            catch (Exception ex) when (ex is TimeoutException or IOException or OperationCanceledException)
            {
                lastError = ex;
                if (cancellationToken.IsCancellationRequested) throw;
                if (attempt < maxAttempts) await Task.Delay(retryDelay, cancellationToken);
            }
        }
        throw new IOException($"Could not connect to CodeIsland pipe after {maxAttempts} attempts.", lastError);
    }

    public async Task<PipeMessage> SendAsync(PipeMessage message, TimeSpan timeout, CancellationToken cancellationToken = default)
    {
        if (_writer is null || _reader is null) throw new InvalidOperationException("Pipe is not connected.");
        await _writer.WriteLineAsync(PipeJson.Serialize(message));
        using var timeoutSource = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
        timeoutSource.CancelAfter(timeout);
        var line = await _reader.ReadLineAsync(timeoutSource.Token)
            ?? throw new EndOfStreamException("Pipe disconnected before response.");
        return PipeJson.Deserialize(line);
    }

    public async ValueTask DisposeAsync()
    {
        if (_pipe is not null) await _pipe.DisposeAsync();
    }
}
