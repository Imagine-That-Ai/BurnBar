using System.Text.Json.Serialization;

namespace OpenBurnBar.CloudSync.Models;

// Port of OpenBurnBarFirestoreModels/MediaAnalyticsModels.swift — Domain: media-analytics.
// The byte-count / seconds fields are Swift `Double` -> C# `double`.

public sealed record FirestoreMediaQuotaUsageDoc
{
    [JsonPropertyName("id")] public required string Id { get; init; }
    [JsonPropertyName("schemaVersion")] public required long SchemaVersion { get; init; }
    [JsonPropertyName("bytesUploadedFile")] public required double BytesUploadedFile { get; init; }
    [JsonPropertyName("bytesDownloadedFile")] public required double BytesDownloadedFile { get; init; }
    [JsonPropertyName("screenShareSecondsUsed")] public required double ScreenShareSecondsUsed { get; init; }
    [JsonPropertyName("videoCallSecondsUsed")] public required double VideoCallSecondsUsed { get; init; }
}
