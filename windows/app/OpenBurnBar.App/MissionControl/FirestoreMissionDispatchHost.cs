using System;
using System.Collections.Generic;
using System.Globalization;
using System.Linq;
using System.Threading;
using System.Threading.Tasks;
using OpenBurnBar.App.Presentation.MissionControl;
using OpenBurnBar.CloudSync.Firestore;
using OpenBurnBar.CloudSync.Gateway;
using OpenBurnBar.CloudSync.Models;
using OpenBurnBar.CloudSync.Offline;

namespace OpenBurnBar.App.MissionControl;

/// <summary>
/// Firestore-backed <see cref="IMissionDispatchHost"/> over
/// <c>users/{uid}/cli_agent_mission_requests</c> — the same envelope the phone writes.
/// Writes go through <see cref="OfflineWriteQueue"/> for latency compensation.
/// </summary>
public sealed class FirestoreMissionDispatchHost : IMissionDispatchHost
{
    public const string MissionRequestsCollection = "cli_agent_mission_requests";

    private readonly ICloudSyncGateway _gateway;
    private readonly OfflineWriteQueue _writeQueue;
    private readonly string _userRootPath;
    private readonly Func<DateTimeOffset> _clock;

    public FirestoreMissionDispatchHost(
        ICloudSyncGateway gateway,
        string firebaseUid,
        Func<DateTimeOffset>? clock = null)
    {
        if (string.IsNullOrWhiteSpace(firebaseUid))
        {
            throw new ArgumentException("Firebase uid is required.", nameof(firebaseUid));
        }

        _gateway = gateway ?? throw new ArgumentNullException(nameof(gateway));
        _writeQueue = new OfflineWriteQueue(gateway, startOnline: true);
        _userRootPath = $"users/{firebaseUid.Trim()}";
        _clock = clock ?? (() => DateTimeOffset.UtcNow);
    }

    /// <summary>Exposed for unit tests.</summary>
    internal OfflineWriteQueue WriteQueue => _writeQueue;

    public async Task<MissionDispatchOutcome> DispatchAsync(MissionDispatchRequest request)
    {
        if (request is null)
        {
            throw new ArgumentNullException(nameof(request));
        }

        if (string.IsNullOrWhiteSpace(request.Prompt))
        {
            return MissionDispatchOutcome.Failed("Prompt is required.");
        }

        string missionId = Guid.NewGuid().ToString("N");
        DateTimeOffset now = _clock();
        string createdAt = now.ToString("O", CultureInfo.InvariantCulture);
        string title = string.IsNullOrWhiteSpace(request.Title)
            ? $"Mission · {MissionKindInfo.DisplayName(request.Kind)}"
            : request.Title.Trim();

        CloudSyncFields fields = MissionFirestoreMapping.ToDispatchFields(
            request,
            missionId,
            title,
            createdAt);

        string documentPath = $"{_userRootPath}/{MissionRequestsCollection}/{missionId}";
        try
        {
            await _writeQueue.SetAsync(documentPath, fields, merge: false).ConfigureAwait(false);
            return MissionDispatchOutcome.Success(missionId);
        }
        catch (Exception ex)
        {
            return MissionDispatchOutcome.Failed(ex.Message);
        }
    }

    public async Task RespondToApprovalAsync(MissionApprovalAsk ask, bool approve)
    {
        if (ask is null)
        {
            throw new ArgumentNullException(nameof(ask));
        }

        string status = approve ? "running" : "rejected";
        string approvalStatus = approve ? "approved" : "rejected";
        string updatedAt = _clock().ToString("O", CultureInfo.InvariantCulture);

        CloudSyncFields patch = CloudSyncFields.From(new[]
        {
            new KeyValuePair<string, CloudSyncValue>("status", CloudSyncValue.Of(status)),
            new KeyValuePair<string, CloudSyncValue>("approvalStatus", CloudSyncValue.Of(approvalStatus)),
            new KeyValuePair<string, CloudSyncValue>("updatedAt", CloudSyncValue.Of(updatedAt)),
        });

        string documentPath = $"{_userRootPath}/{MissionRequestsCollection}/{ask.MissionId}";
        await _writeQueue.SetAsync(documentPath, patch, merge: true).ConfigureAwait(false);
    }

    public async Task<MissionConsoleSnapshot> RefreshAsync()
    {
        DateTimeOffset now = _clock();
        string collectionPath = $"{_userRootPath}/{MissionRequestsCollection}";

        IReadOnlyList<MissionRecord> pending = await LoadByStatusAsync(collectionPath, "pending", now)
            .ConfigureAwait(false);
        IReadOnlyList<MissionRecord> awaiting = await LoadByStatusAsync(collectionPath, "waiting_for_approval", now)
            .ConfigureAwait(false);
        IReadOnlyList<MissionRecord> running = await LoadByStatusAsync(collectionPath, "running", now)
            .ConfigureAwait(false);
        IReadOnlyList<MissionRecord> claimed = await LoadByStatusAsync(collectionPath, "claimed", now)
            .ConfigureAwait(false);
        IReadOnlyList<MissionRecord> inProgress = await LoadByStatusAsync(collectionPath, "in_progress", now)
            .ConfigureAwait(false);

        var missions = pending
            .Concat(awaiting)
            .Concat(running)
            .Concat(claimed)
            .Concat(inProgress)
            .DistinctBy(m => m.Id)
            .ToList();

        return MissionSnapshotBuilder.Build(
            missions,
            Array.Empty<MissionControllerEvent>(),
            Array.Empty<MissionRuntime>(),
            new MissionRuntimeSnapshot(RuntimeSnapshotSource.Inferred, now),
            now);
    }

    private async Task<IReadOnlyList<MissionRecord>> LoadByStatusAsync(
        string collectionPath,
        string status,
        DateTimeOffset now)
    {
        ICloudSyncQuerySnapshot snapshot = await _gateway.Collection(collectionPath)
            .WhereEqualTo("status", CloudSyncValue.Of(status))
            .GetDocumentsAsync()
            .ConfigureAwait(false);

        var records = new List<MissionRecord>(snapshot.Documents.Count);
        foreach (ICloudSyncDocumentSnapshot doc in snapshot.Documents)
        {
            if (MissionFirestoreMapping.TryToMissionRecord(doc.DocumentId, doc.Data, now) is { } record)
            {
                records.Add(record);
            }
        }

        return records;
    }
}

/// <summary>Maps between Firestore mission documents and portable <see cref="MissionRecord"/>s.</summary>
internal static class MissionFirestoreMapping
{
    public static CloudSyncFields ToDispatchFields(
        MissionDispatchRequest request,
        string missionId,
        string title,
        string createdAtIso)
    {
        var pairs = new List<KeyValuePair<string, CloudSyncValue>>
        {
            new("id", CloudSyncValue.Of(missionId)),
            new("missionId", CloudSyncValue.Of(missionId)),
            new("title", CloudSyncValue.Of(title)),
            new("prompt", CloudSyncValue.Of(request.Prompt.Trim())),
            new("missionKind", CloudSyncValue.Of(MissionKindInfo.RawValue(request.Kind))),
            new("requestedRuntime", CloudSyncValue.Of(request.RuntimeId)),
            new("depth", CloudSyncValue.Of(DepthRaw(request.Depth))),
            new("approvalMode", CloudSyncValue.Of(MissionApprovalModeInfo.RawValue(request.ApprovalMode))),
            new("commandsAllowed", CloudSyncValue.Of(request.CommandsAllowed)),
            new("fileEditsAllowed", CloudSyncValue.Of(request.FileEditsAllowed)),
            new("source", CloudSyncValue.Of("windows")),
            new("sourceSurface", CloudSyncValue.Of(request.SourceSurface ?? "mission-control")),
            new("deliveryMode", CloudSyncValue.Of("action_only")),
            new("status", CloudSyncValue.Of("pending")),
            new("createdAt", CloudSyncValue.Of(createdAtIso)),
            new("updatedAt", CloudSyncValue.ServerTimestamp.Instance),
            new("schemaVersion", CloudSyncValue.Of(1L)),
            new("payloadSummary", CloudSyncValue.Of(title)),
        };

        if (!string.IsNullOrWhiteSpace(request.TargetProject))
        {
            pairs.Add(new KeyValuePair<string, CloudSyncValue>("targetProject", CloudSyncValue.Of(request.TargetProject.Trim())));
        }

        return CloudSyncFields.From(pairs);
    }

    public static MissionRecord? TryToMissionRecord(string documentId, CloudSyncFields data, DateTimeOffset fallbackNow)
    {
        string id = ReadString(data, "missionId") ?? ReadString(data, "id") ?? documentId;
        string title = ReadString(data, "title")
            ?? ReadString(data, "payloadSummary")
            ?? id;
        string project = ReadString(data, "targetProject") ?? "scratch";
        string status = (ReadString(data, "status") ?? "pending").ToLowerInvariant();
        string approvalStatus = (ReadString(data, "approvalStatus") ?? "none").ToLowerInvariant();

        DateTimeOffset updatedAt = ReadTimestamp(data, "updatedAt")
            ?? ReadTimestamp(data, "createdAt")
            ?? fallbackNow;

        return new MissionRecord(
            id: id,
            title: title,
            projectName: project,
            state: MapState(status),
            approval: MapApproval(status, approvalStatus),
            updatedAt: updatedAt,
            activeWorkerName: ReadString(data, "requestedRuntime"),
            packetSummary: ReadString(data, "prompt"),
            latestAuditSummary: ReadString(data, "approvalSummary"));
    }

    public static FirestoreMissionDispatchDoc? ToDispatchDoc(CloudSyncFields data)
    {
        string? missionId = ReadString(data, "missionId") ?? ReadString(data, "id");
        string? status = ReadString(data, "status");
        string? createdAt = ReadString(data, "createdAt");
        if (missionId is null || status is null || createdAt is null)
        {
            return null;
        }

        return new FirestoreMissionDispatchDoc
        {
            MissionId = missionId,
            Status = status,
            CreatedAt = createdAt,
            UpdatedAt = ReadString(data, "updatedAt"),
            PayloadSummary = ReadString(data, "payloadSummary"),
        };
    }

    private static string DepthRaw(MissionDepth depth) => depth switch
    {
        MissionDepth.Light => "light",
        MissionDepth.Standard => "standard",
        MissionDepth.Deep => "deep",
        _ => "standard",
    };

    private static MissionRecordState MapState(string status) => status switch
    {
        "pending" or "queued" or "planned" => MissionRecordState.Planned,
        "running" or "claimed" or "in_progress" => MissionRecordState.Running,
        "waiting_for_approval" => MissionRecordState.Running,
        "partial" => MissionRecordState.Partial,
        "blocked" => MissionRecordState.Blocked,
        "completed" or "succeeded" or "done" => MissionRecordState.Completed,
        "failed" or "rejected" or "canceled" or "cancelled" => MissionRecordState.Blocked,
        _ => MissionRecordState.Planned,
    };

    private static MissionApprovalState MapApproval(string status, string approvalStatus) =>
        status == "waiting_for_approval" || approvalStatus == "pending"
            ? MissionApprovalState.Pending
            : MissionApprovalState.None;

    private static string? ReadString(CloudSyncFields data, string key) =>
        data[key] is CloudSyncValue.StringValue s ? s.Value : null;

    private static DateTimeOffset? ReadTimestamp(CloudSyncFields data, string key)
    {
        if (data[key] is CloudSyncValue.TimestampValue ts)
        {
            return ts.Value;
        }

        if (data[key] is CloudSyncValue.StringValue s
            && DateTimeOffset.TryParse(s.Value, CultureInfo.InvariantCulture, DateTimeStyles.RoundtripKind, out DateTimeOffset parsed))
        {
            return parsed;
        }

        return null;
    }
}