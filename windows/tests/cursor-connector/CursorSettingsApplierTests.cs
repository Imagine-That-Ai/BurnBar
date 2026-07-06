using System.Collections.Generic;
using System.Linq;
using System.Text.Json.Nodes;
using OpenBurnBar.App.CursorConnector;
using Xunit;

namespace OpenBurnBar.App.CursorConnector.Tests;

/// <summary>Backup/apply/restore parity for <see cref="CursorSettingsApplier"/>.</summary>
public sealed class CursorSettingsApplierTests
{
    private const string PriorApplicationUser =
        "{\"useOpenAIKey\":false,\"openAIBaseUrl\":\"https://old\",\"aiSettings\":{\"userAddedModels\":[\"m1\"]}}";

    private static FakeCursorStateStore SeededStore()
    {
        var store = new FakeCursorStateStore();
        store.Seed(CursorSettingsApplier.ApplicationUserKey, PriorApplicationUser);
        store.Seed(CursorSettingsApplier.OpenAIKeyKey, "old-key");
        return store;
    }

    [Fact]
    public void ApplyGatewaySettings_SnapshotsAndRewrites()
    {
        var store = SeededStore();
        var applier = new CursorSettingsApplier(store);

        var snapshot = applier.ApplyGatewaySettings(
            "https://new/v1",
            new List<string> { "glm-5", "gpt-oss:120b" },
            "session-tok");

        // Snapshot captured the pre-connect state.
        Assert.False(snapshot.UseOpenAIKey);
        Assert.Equal("https://old", snapshot.OpenAIBaseUrl);
        Assert.Equal(new[] { "m1" }, snapshot.UserAddedModels);
        Assert.Equal("old-key", snapshot.OpenAIKey);

        // The live state now points at the gateway.
        var applied = JsonNode.Parse(store.TryReadItem(CursorSettingsApplier.ApplicationUserKey)!)!.AsObject();
        Assert.True((bool)applied["useOpenAIKey"]!);
        Assert.Equal("https://new/v1", (string)applied["openAIBaseUrl"]!);
        Assert.Equal(
            new[] { "glm-5", "gpt-oss:120b" },
            applied["aiSettings"]!["userAddedModels"]!.AsArray().Select(node => (string)node!).ToArray());
        Assert.Equal("session-tok", store.TryReadItem(CursorSettingsApplier.OpenAIKeyKey));
    }

    [Fact]
    public void RestoreSettings_PutsSnapshotBack()
    {
        var store = SeededStore();
        var applier = new CursorSettingsApplier(store);
        var snapshot = applier.ApplyGatewaySettings("https://new/v1", new List<string> { "glm-5" }, "session-tok");

        applier.RestoreSettings(snapshot);

        var restored = JsonNode.Parse(store.TryReadItem(CursorSettingsApplier.ApplicationUserKey)!)!.AsObject();
        Assert.False((bool)restored["useOpenAIKey"]!);
        Assert.Equal("https://old", (string)restored["openAIBaseUrl"]!);
        Assert.Equal(
            new[] { "m1" },
            restored["aiSettings"]!["userAddedModels"]!.AsArray().Select(node => (string)node!).ToArray());
        Assert.Equal("old-key", store.TryReadItem(CursorSettingsApplier.OpenAIKeyKey));
    }

    [Fact]
    public void RestoreSettings_NullSnapshot_IsNoOp()
    {
        var store = SeededStore();
        var applier = new CursorSettingsApplier(store);

        applier.RestoreSettings(null);

        Assert.Empty(store.Writes);
    }

    [Fact]
    public void ApplyGatewaySettings_MissingApplicationUser_Throws()
    {
        var store = new FakeCursorStateStore();
        var applier = new CursorSettingsApplier(store);

        Assert.Throws<ConnectorConfigException>(() =>
            applier.ApplyGatewaySettings("https://new/v1", new List<string> { "glm-5" }, "tok"));
    }
}
