using System;
using System.Collections.Generic;
using System.Linq;
using System.Text.Json;
using System.Text.Json.Nodes;
using OpenBurnBar.App.Quota.Acquisition;

namespace OpenBurnBar.App.CursorConnector;

// ── Cursor settings applier ──────────────────────────────────────────────────
//
// Faithful Windows peer of CursorConnectorManager.backupAndApplyCursorSettings /
// restoreCursorSettings. On connect the Mac snapshots Cursor's editor settings
// (the `applicationUser` reactive-storage blob's aiSettings + the
// `cursorAuth/openAIKey`), then rewrites them to point Cursor at the local
// gateway; on disconnect (or connect failure) it restores the snapshot verbatim.
//
// State.vscdb access rides ICursorStateStore (the deferred .Windows half opens
// the real ItemTable with the same Microsoft.Data.Sqlite stack as the landed
// CursorStateDbReader). This applier also COMPOSES that landed reader —
// ReadAccountIdentity delegates to CursorStateDbReader.TryRead — rather than
// duplicating a second state.vscdb reader.

/// <summary>Snapshots/applies/restores Cursor's editor settings for the connector.</summary>
public sealed class CursorSettingsApplier
{
    /// <summary>Swift reactive-storage <c>applicationUser</c> key.</summary>
    public const string ApplicationUserKey =
        "src.vs.platform.reactivestorage.browser.reactiveStorageServiceImpl.persistentStorage.applicationUser";

    /// <summary>Swift <c>cursorAuth/openAIKey</c> key.</summary>
    public const string OpenAIKeyKey = "cursorAuth/openAIKey";

    private static readonly JsonSerializerOptions CompactOptions = new() { WriteIndented = false };

    private readonly ICursorStateStore _store;

    /// <summary>Creates an applier over the given state store.</summary>
    public CursorSettingsApplier(ICursorStateStore store)
    {
        _store = store ?? throw new ArgumentNullException(nameof(store));
    }

    /// <summary>
    /// Swift <c>backupAndApplyCursorSettings</c>: snapshot the current editor
    /// settings, then rewrite them to the gateway. Returns the snapshot to persist
    /// into <see cref="CursorConnectorConfig.CursorSnapshot"/>.
    /// </summary>
    public CursorSetupSnapshot ApplyGatewaySettings(string publicBaseUrl, IReadOnlyList<string> exposedModels, string sessionToken)
    {
        var parsed = ReadApplicationUser();
        var currentAuth = _store.TryReadItem(OpenAIKeyKey);
        var ai = parsed[ "aiSettings" ] as JsonObject ?? new JsonObject();

        var snapshot = new CursorSetupSnapshot
        {
            UseOpenAIKey = AsBool(parsed["useOpenAIKey"]),
            OpenAIBaseUrl = AsString(parsed["openAIBaseUrl"]),
            UserAddedModels = AsStringList(ai["userAddedModels"]),
            OpenAIKey = currentAuth,
        };

        parsed["useOpenAIKey"] = true;
        parsed["openAIBaseUrl"] = publicBaseUrl;
        ai["userAddedModels"] = ToJsonArray(exposedModels);
        parsed["aiSettings"] = ai;

        _store.WriteItem(ApplicationUserKey, parsed.ToJsonString(CompactOptions));
        _store.WriteItem(OpenAIKeyKey, sessionToken);
        return snapshot;
    }

    /// <summary>Swift <c>restoreCursorSettings</c>: put the snapshot back verbatim.</summary>
    public void RestoreSettings(CursorSetupSnapshot? snapshot)
    {
        if (snapshot is null)
        {
            return;
        }

        var parsed = ReadApplicationUser();
        var ai = parsed["aiSettings"] as JsonObject ?? new JsonObject();
        parsed["useOpenAIKey"] = snapshot.UseOpenAIKey is { } useKey ? JsonValue.Create(useKey) : null;
        parsed["openAIBaseUrl"] = snapshot.OpenAIBaseUrl is { } baseUrl ? JsonValue.Create(baseUrl) : null;
        ai["userAddedModels"] = ToJsonArray(snapshot.UserAddedModels);
        parsed["aiSettings"] = ai;

        _store.WriteItem(ApplicationUserKey, parsed.ToJsonString(CompactOptions));
        if (snapshot.OpenAIKey is { } openAIKey)
        {
            _store.WriteItem(OpenAIKeyKey, openAIKey);
        }
    }

    /// <summary>
    /// Compose with the landed reader: surface the connected Cursor account
    /// identity (auth JWT + email + membership) from the same state.vscdb, reusing
    /// <see cref="CursorStateDbReader"/> rather than a second ItemTable reader.
    /// </summary>
    public static CursorStateCredentials? ReadAccountIdentity(string stateDbPath) =>
        CursorStateDbReader.TryRead(stateDbPath);

    private JsonObject ReadApplicationUser()
    {
        var currentJson = _store.TryReadItem(ApplicationUserKey);
        if (currentJson is null)
        {
            // Swift readSQLiteValue throws when the required key is absent.
            throw new ConnectorConfigException($"Cursor setting {ApplicationUserKey} was not found");
        }

        try
        {
            return JsonNode.Parse(currentJson) as JsonObject ?? new JsonObject();
        }
        catch (JsonException)
        {
            // Swift `as? [String: Any] ?? [:]` — a non-object parse degrades to empty.
            return new JsonObject();
        }
    }

    private static bool? AsBool(JsonNode? node) =>
        node is JsonValue value && value.TryGetValue(out bool result) ? result : null;

    private static string? AsString(JsonNode? node) =>
        node is JsonValue value && value.TryGetValue(out string? result) ? result : null;

    private static List<string> AsStringList(JsonNode? node) =>
        node is JsonArray array
            ? array.Select(item => item is JsonValue value && value.TryGetValue(out string? str) ? str : null)
                .Where(str => str is not null)
                .Select(str => str!)
                .ToList()
            : new List<string>();

    private static JsonArray ToJsonArray(IReadOnlyList<string> values)
    {
        var array = new JsonArray();
        foreach (var value in values)
        {
            array.Add(value);
        }

        return array;
    }
}
