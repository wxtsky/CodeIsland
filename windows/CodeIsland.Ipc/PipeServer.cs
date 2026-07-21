using System.IO.Pipes;
using System.Text;
using System.Text.Json;
using System.Runtime.Versioning;

namespace CodeIsland.Ipc;

[SupportedOSPlatform("windows")]
public sealed class PipeServer : IAsyncDisposable
{
    private readonly string? _userSid;
    private readonly Func<PipeMessage, CancellationToken, ValueTask<PipeMessage?>> _handler;
    private CancellationTokenSource? _stop;

    public PipeServer(Func<PipeMessage, CancellationToken, ValueTask<PipeMessage?>> handler, string? userSid = null)
    {
        _handler = handler;
        _userSid = userSid;
    }

    public Task RunAsync(CancellationToken cancellationToken = default)
    {
        _stop = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
        return AcceptLoopAsync(_stop.Token);
    }

    private async Task AcceptLoopAsync(CancellationToken cancellationToken)
    {
        while (!cancellationToken.IsCancellationRequested)
        {
            await using var pipe = PipeEndpoint.CreateServer(_userSid);
            try
            {
                await pipe.WaitForConnectionAsync(cancellationToken);
                await HandleConnectionAsync(pipe, cancellationToken);
            }
            catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested) { }
            catch (IOException) when (!cancellationToken.IsCancellationRequested) { }
        }
    }

    private async Task HandleConnectionAsync(NamedPipeServerStream pipe, CancellationToken cancellationToken)
    {
        using var reader = new StreamReader(pipe, Encoding.UTF8, leaveOpen: true);
        await using var writer = new StreamWriter(pipe, new UTF8Encoding(false), leaveOpen: true) { AutoFlush = true };
        while (pipe.IsConnected && !cancellationToken.IsCancellationRequested)
        {
            var line = await reader.ReadLineAsync(cancellationToken);
            if (line is null) break;
            PipeMessage? response;
            try
            {
                response = await _handler(PipeJson.Deserialize(line), cancellationToken);
            }
            catch (Exception ex) when (ex is JsonException or ArgumentException or NotSupportedException)
            {
                response = new PipeMessage(PipeMessageType.Error, Guid.NewGuid().ToString("N"), Error: ex.Message);
            }
            if (response is not null) await writer.WriteLineAsync(PipeJson.Serialize(response));
        }
    }

    public async ValueTask DisposeAsync()
    {
        if (_stop is not null) await _stop.CancelAsync();
        _stop?.Dispose();
    }
}
