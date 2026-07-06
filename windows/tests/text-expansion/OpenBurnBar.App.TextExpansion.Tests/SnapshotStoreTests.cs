using System;
using Xunit;

namespace OpenBurnBar.App.TextExpansion.Tests;

/// <summary>
/// JSON snapshot round-trip + byte-shape compatibility with the Swift
/// <c>TextExpansionSnapshotStore</c> Codable encoding
/// (OpenBurnBarCore/.../TextExpansion/TextExpansionSnapshotStore.swift). A snapshot
/// written on macOS must decode here and vice-versa: exact key names, the
/// <c>static</c>/<c>llm_rewrite</c> mode strings, the surface raw values, and ISO-8601
/// dates.
/// </summary>
public sealed class SnapshotStoreTests
{
    [Fact]
    public void EncodeThenDecode_RoundTripsAllFields()
    {
        var created = new DateTimeOffset(2026, 7, 1, 9, 30, 0, TimeSpan.Zero);
        var updated = new DateTimeOffset(2026, 7, 2, 10, 0, 0, TimeSpan.Zero);
        var synced = new DateTimeOffset(2026, 7, 2, 10, 5, 0, TimeSpan.Zero);

        var snippet = new TextExpansionSnippet(
            title: "Contextual",
            trigger: "ctx",
            body: "Make this fit.",
            id: "s1",
            mode: TextExpansionMode.LlmRewrite,
            isEnabled: true,
            scope: new TextExpansionScope(
                surfaces: new[] { TextExpansionSurface.InAppThread, TextExpansionSurface.MacGlobal },
                bundleIdentifiers: new[] { "com.apple.TextEdit" },
                threadIds: new[] { "abc" }),
            revision: 3,
            createdAt: created,
            updatedAt: updated,
            syncedAt: synced,
            sourceDeviceId: "device-7");
        var snapshot = new TextExpansionSnapshot(new[] { snippet }, schemaVersion: 1, exportedAt: updated);

        string json = TextExpansionSnapshotStore.Encode(snapshot);
        var decoded = TextExpansionSnapshotStore.Decode(json);

        var round = Assert.Single(decoded.Snippets);
        Assert.Equal("s1", round.Id);
        Assert.Equal("Contextual", round.Title);
        Assert.Equal("ctx", round.Trigger);
        Assert.Equal("Make this fit.", round.Body);
        Assert.Equal(TextExpansionMode.LlmRewrite, round.Mode);
        Assert.True(round.IsEnabled);
        Assert.Equal(3, round.Revision);
        Assert.Equal(created, round.CreatedAt);
        Assert.Equal(updated, round.UpdatedAt);
        Assert.Equal(synced, round.SyncedAt);
        Assert.Null(round.DeletedAt);
        Assert.Equal("device-7", round.SourceDeviceId);
        Assert.Equal(
            new[] { TextExpansionSurface.InAppThread, TextExpansionSurface.MacGlobal },
            round.Scope.Surfaces);
        Assert.Equal(new[] { "com.apple.TextEdit" }, round.Scope.BundleIdentifiers);
        Assert.Equal(new[] { "abc" }, round.Scope.ThreadIds);
    }

    [Fact]
    public void EncodedJson_UsesSwiftKeyNamesAndRawValues()
    {
        var snippet = new TextExpansionSnippet(
            title: "T", trigger: "ctx", body: "b", mode: TextExpansionMode.LlmRewrite,
            scope: new TextExpansionScope(
                surfaces: new[] { TextExpansionSurface.InAppThread },
                threadIds: new[] { "abc" }),
            sourceDeviceId: "device-7");
        string json = TextExpansionSnapshotStore.Encode(new TextExpansionSnapshot(new[] { snippet }));

        Assert.Contains("\"mode\":\"llm_rewrite\"", json);
        Assert.Contains("\"isEnabled\":true", json);
        Assert.Contains("\"threadIDs\"", json);           // Swift capitalizes IDs
        Assert.Contains("\"sourceDeviceID\"", json);       // Swift capitalizes ID
        Assert.Contains("\"in_app_thread\"", json);
        Assert.Contains("\"schemaVersion\":1", json);
    }

    [Fact]
    public void Decode_ParsesSwiftShapedJson()
    {
        // A snapshot as produced by the Swift JSONEncoder (.iso8601 dates, snake_case
        // enum raw values, capitalized ID keys).
        const string swiftJson =
            """
            {
              "schemaVersion": 1,
              "exportedAt": "2026-07-06T12:00:00Z",
              "snippets": [
                {
                  "id": "s1",
                  "title": "Contextual",
                  "trigger": "ctx",
                  "body": "Make this fit.",
                  "mode": "llm_rewrite",
                  "isEnabled": true,
                  "scope": {
                    "surfaces": ["in_app_thread", "mac_global"],
                    "bundleIdentifiers": [],
                    "threadIDs": ["abc"]
                  },
                  "revision": 3,
                  "createdAt": "2026-07-01T09:30:00Z",
                  "updatedAt": "2026-07-02T10:00:00Z",
                  "deletedAt": null,
                  "syncedAt": "2026-07-02T10:05:00Z",
                  "sourceDeviceID": "device-7"
                }
              ]
            }
            """;

        var decoded = TextExpansionSnapshotStore.Decode(swiftJson);
        var s = Assert.Single(decoded.Snippets);
        Assert.Equal("ctx", s.Trigger);
        Assert.Equal(TextExpansionMode.LlmRewrite, s.Mode);
        Assert.Equal(3, s.Revision);
        Assert.Equal("device-7", s.SourceDeviceId);
        Assert.Null(s.DeletedAt);
        Assert.NotNull(s.SyncedAt);
        Assert.Equal(
            new[] { TextExpansionSurface.InAppThread, TextExpansionSurface.MacGlobal },
            s.Scope.Surfaces);
        Assert.Equal(new[] { "abc" }, s.Scope.ThreadIds);
        Assert.Empty(s.Scope.BundleIdentifiers);
    }
}
