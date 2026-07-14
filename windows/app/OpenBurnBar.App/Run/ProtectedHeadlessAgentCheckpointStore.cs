using System;
using System.IO;
using System.Security.Cryptography;
using System.Threading;
using System.Threading.Tasks;
using OpenBurnBar.App.Configuration;
using OpenBurnBar.App.ManagedAgentRuntime.Run;

namespace OpenBurnBar.App.Run;

/// <summary>DPAPI-backed store for prompt-bearing agent checkpoints.</summary>
public sealed class ProtectedHeadlessAgentCheckpointStore : IHeadlessAgentCheckpointStore
{
    private const string PayloadPrefix = "headless-agent-checkpoint-";
    private readonly ProtectedFilePayloadStore _payloads;

    public ProtectedHeadlessAgentCheckpointStore(ProtectedFilePayloadStore payloads)
    {
        _payloads = payloads ?? throw new ArgumentNullException(nameof(payloads));
    }

    public static ProtectedHeadlessAgentCheckpointStore CreateDefault() =>
        new(ProtectedFilePayloadStore.CreateDefault());

    public Task SaveAsync(
        HeadlessAgentRunCheckpoint checkpoint,
        CancellationToken cancellationToken = default)
    {
        cancellationToken.ThrowIfCancellationRequested();
        byte[] bytes = HeadlessAgentCheckpointCodec.Serialize(checkpoint);
        _payloads.Write(PayloadName(checkpoint.RunId), bytes);
        return Task.CompletedTask;
    }

    public Task<HeadlessAgentRunCheckpoint?> LoadAsync(
        string runId,
        CancellationToken cancellationToken = default)
    {
        cancellationToken.ThrowIfCancellationRequested();
        HeadlessAgentCheckpointCodec.ValidateRunId(runId);
        byte[]? bytes;
        try
        {
            bytes = _payloads.Read(PayloadName(runId));
        }
        catch (SecretStoreException error) when (error.Failure == SecretStoreFailureKind.CorruptProtectedPayload)
        {
            throw new InvalidDataException("The protected headless-agent checkpoint is corrupt.", error);
        }
        return Task.FromResult(bytes is null
            ? null
            : HeadlessAgentCheckpointCodec.Deserialize(runId, bytes));
    }

    public Task DeleteAsync(string runId, CancellationToken cancellationToken = default)
    {
        cancellationToken.ThrowIfCancellationRequested();
        HeadlessAgentCheckpointCodec.ValidateRunId(runId);
        _payloads.Delete(PayloadName(runId));
        return Task.CompletedTask;
    }

    private static string PayloadName(string runId)
    {
        HeadlessAgentCheckpointCodec.ValidateRunId(runId);
        string hash = Convert.ToHexString(SHA256.HashData(System.Text.Encoding.UTF8.GetBytes(runId))).ToLowerInvariant();
        return PayloadPrefix + hash;
    }
}
