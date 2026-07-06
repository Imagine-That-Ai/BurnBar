using System;
using System.Collections.Generic;
using System.Globalization;
using System.Linq;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;

namespace OpenBurnBar.App.CursorConnector;

// ── Routed-client config sync ────────────────────────────────────────────────
//
// Faithful Windows peer of RoutedClientConfigSyncService (in
// CursorConnectorModels.swift). It writes the OpenBurnBar gateway into the config
// files of two external agent clients — Factory (~/.factory/settings.json +
// config.json) and OpenCode (~/.config/opencode/opencode.json) — idempotently:
// prior OpenBurnBar entries are recognised + removed before re-adding, existing
// files are backed up once per second-stamp, and JSONC comments are stripped
// before parsing. File access rides IConnectorFileSystem; the backup stamp rides
// IConnectorClock — both provable without touching a real home directory.

/// <summary>Filesystem seam for the routed-client config writer.</summary>
public interface IConnectorFileSystem
{
    /// <summary>Whether a file exists at <paramref name="path"/>.</summary>
    bool FileExists(string path);

    /// <summary>Reads the whole file.</summary>
    string ReadAllText(string path);

    /// <summary>Writes (overwriting) the whole file.</summary>
    void WriteAllText(string path, string content);

    /// <summary>Ensures the directory (and parents) exist.</summary>
    void CreateDirectory(string path);

    /// <summary>Copies <paramref name="source"/> to <paramref name="destination"/>.</summary>
    void CopyFile(string source, string destination);
}

/// <summary>Syncs the OpenBurnBar gateway into external agent-client config.</summary>
public sealed class RoutedClientConfigSyncService
{
    private readonly IConnectorFileSystem _fileSystem;
    private readonly IConnectorClock _clock;
    private readonly string _homeDirectory;

    /// <summary>Creates the service rooted at a home directory.</summary>
    public RoutedClientConfigSyncService(IConnectorFileSystem fileSystem, string homeDirectory, IConnectorClock? clock = null)
    {
        _fileSystem = fileSystem ?? throw new ArgumentNullException(nameof(fileSystem));
        _homeDirectory = homeDirectory ?? throw new ArgumentNullException(nameof(homeDirectory));
        _clock = clock ?? SystemConnectorClock.Instance;
    }

    /// <summary>Swift <c>applyFactoryGatewayConfig(_:)</c>; returns the written paths.</summary>
    public IReadOnlyList<string> ApplyFactoryGatewayConfig(RoutedClientGatewayConfig config)
    {
        var models = NormalizedModels(config.Models);
        if (models.Count == 0)
        {
            throw new ConnectorConfigException("Choose at least one routed model before syncing Factory.");
        }

        var (settingsPath, configPath) = FactoryGatewayConfigPaths();
        UpdateFactorySettingsJson(settingsPath, config, models);
        UpdateFactoryConfigJson(configPath, config, models);
        return new[] { settingsPath, configPath };
    }

    /// <summary>Swift <c>factoryGatewayConfigURLs()</c>.</summary>
    public (string Settings, string Config) FactoryGatewayConfigPaths() =>
        (Join(".factory", "settings.json"), Join(".factory", "config.json"));

    /// <summary>Swift <c>isFactoryGatewayConfigPresent()</c>.</summary>
    public bool IsFactoryGatewayConfigPresent()
    {
        var (settingsPath, configPath) = FactoryGatewayConfigPaths();
        var settingsRoot = TryLoadJsonObject(settingsPath);
        var configRoot = TryLoadJsonObject(configPath);
        var settingsModels = ArrayOfObjects(settingsRoot, "customModels");
        var configModels = ArrayOfObjects(configRoot, "custom_models");
        return settingsModels.Any(IsOpenBurnBarFactoryEntry) || configModels.Any(IsOpenBurnBarFactoryEntry);
    }

    /// <summary>Swift <c>applyOpenCodeGatewayConfig(_:)</c>; returns the written path.</summary>
    public string ApplyOpenCodeGatewayConfig(RoutedClientGatewayConfig config)
    {
        var models = NormalizedModels(config.Models);
        if (models.Count == 0)
        {
            throw new ConnectorConfigException("Choose at least one routed model before syncing OpenCode.");
        }

        var configPath = Join(".config", "opencode", "opencode.json");
        var root = LoadJsonObject(configPath);
        var providers = root["provider"] as JsonObject ?? new JsonObject();
        providers["openburnbar"] = OpenCodeProviderObject(config, models);
        root["provider"] = providers;
        if (root["model"] is null)
        {
            root["model"] = $"openburnbar/{models[0]}";
        }

        WriteJsonObject(root, configPath, backupExisting: true);
        return configPath;
    }

    private void UpdateFactorySettingsJson(string path, RoutedClientGatewayConfig config, IReadOnlyList<string> models)
    {
        var root = LoadJsonObject(path);
        var customModels = TakeArray(root, "customModels");
        RemoveOpenBurnBarEntries(customModels);
        var startIndex = customModels.Count;
        for (var offset = 0; offset < models.Count; offset++)
        {
            var model = models[offset];
            customModels.Add(new JsonObject
            {
                ["model"] = model,
                ["id"] = FactoryCustomModelId(model, startIndex + offset),
                ["index"] = startIndex + offset,
                ["baseUrl"] = config.BaseURL,
                ["apiKey"] = config.EffectiveAPIKey,
                ["displayName"] = $"OpenBurnBar {model}",
                ["maxOutputTokens"] = 8192,
                ["provider"] = "generic-chat-completion-api",
            });
        }

        root["customModels"] = customModels;
        WriteJsonObject(root, path, backupExisting: true);
    }

    private void UpdateFactoryConfigJson(string path, RoutedClientGatewayConfig config, IReadOnlyList<string> models)
    {
        var root = LoadJsonObject(path);
        var customModels = TakeArray(root, "custom_models");
        RemoveOpenBurnBarEntries(customModels);
        foreach (var model in models)
        {
            customModels.Add(new JsonObject
            {
                ["model_display_name"] = $"OpenBurnBar {model}",
                ["model"] = model,
                ["base_url"] = config.BaseURL,
                ["api_key"] = config.EffectiveAPIKey,
                ["max_output_tokens"] = 8192,
                ["provider"] = "generic-chat-completion-api",
            });
        }

        root["custom_models"] = customModels;
        WriteJsonObject(root, path, backupExisting: true);
    }

    private static void RemoveOpenBurnBarEntries(JsonArray array)
    {
        for (var i = array.Count - 1; i >= 0; i--)
        {
            if (array[i] is JsonObject entry && IsOpenBurnBarFactoryEntry(entry))
            {
                array.RemoveAt(i);
            }
        }
    }

    /// <summary>Swift <c>isOpenBurnBarFactoryEntry(_:)</c>.</summary>
    public static bool IsOpenBurnBarFactoryEntry(JsonObject entry)
    {
        var provider = LowerString(entry, "provider");
        var id = LowerString(entry, "id");
        var displayName = LowerString(entry, "displayName") ?? LowerString(entry, "model_display_name");
        var model = LowerString(entry, "model");
        var baseUrl = RawString(entry, "baseUrl") ?? RawString(entry, "base_url");
        var isGatewayEntry = baseUrl is not null && IsLocalGatewayUrl(baseUrl);

        return provider == "openburnbar"
            || (id?.StartsWith("custom:openburnbar", StringComparison.Ordinal) ?? false)
            || (id?.StartsWith("openburnbar:", StringComparison.Ordinal) ?? false)
            || (id?.Contains("vibeproxy", StringComparison.Ordinal) ?? false)
            || (displayName?.StartsWith("openburnbar ", StringComparison.Ordinal) ?? false)
            || (displayName?.Contains("vibeproxy", StringComparison.Ordinal) ?? false)
            || (model?.StartsWith("openburnbar:", StringComparison.Ordinal) ?? false)
            || ((provider == "openai" || provider == "anthropic" || provider == "generic-chat-completion-api")
                && isGatewayEntry);
    }

    /// <summary>Swift <c>isLocalGatewayURL(_:)</c> — loopback host on port 8317.</summary>
    public static bool IsLocalGatewayUrl(string rawValue)
    {
        if (!Uri.TryCreate(rawValue.Trim(), UriKind.Absolute, out var uri))
        {
            return false;
        }

        var host = uri.Host.ToLowerInvariant();
        return (host == "127.0.0.1" || host == "localhost") && uri.Port == 8317;
    }

    /// <summary>Swift <c>factoryCustomModelID(for:index:)</c>.</summary>
    public static string FactoryCustomModelId(string model, int index)
    {
        var builder = new StringBuilder(model.Length);
        foreach (var scalar in model)
        {
            var allowed = (scalar >= 'a' && scalar <= 'z')
                || (scalar >= 'A' && scalar <= 'Z')
                || (scalar >= '0' && scalar <= '9')
                || scalar == '.' || scalar == '-' || scalar == '_';
            builder.Append(allowed ? scalar : '-');
        }

        var sanitized = builder.ToString();
        var slug = sanitized.Trim('.', '-', '_').Length == 0 ? "model" : sanitized;
        return $"custom:OpenBurnBar-{slug}-{index}";
    }

    private static JsonObject OpenCodeProviderObject(RoutedClientGatewayConfig config, IReadOnlyList<string> models)
    {
        var options = new JsonObject { ["baseURL"] = config.BaseURL };
        if (config.EffectiveAPIKey.Length != 0)
        {
            options["apiKey"] = config.EffectiveAPIKey;
        }

        var modelMap = new JsonObject();
        foreach (var model in models)
        {
            modelMap[model] = new JsonObject { ["name"] = model };
        }

        return new JsonObject
        {
            ["npm"] = "@ai-sdk/openai-compatible",
            ["name"] = "OpenBurnBar Gateway",
            ["options"] = options,
            ["models"] = modelMap,
        };
    }

    /// <summary>Swift <c>normalizedModels(_:)</c> — trim, drop empties, ordinal-ci dedup.</summary>
    public static IReadOnlyList<string> NormalizedModels(IEnumerable<string> models)
    {
        var seen = new HashSet<string>(StringComparer.Ordinal);
        var result = new List<string>();
        foreach (var raw in models)
        {
            var model = raw.Trim();
            if (model.Length == 0)
            {
                continue;
            }

            if (seen.Add(model.ToLowerInvariant()))
            {
                result.Add(model);
            }
        }

        return result;
    }

    private JsonObject TryLoadJsonObject(string path)
    {
        try
        {
            return LoadJsonObject(path);
        }
        catch (ConnectorConfigException)
        {
            return new JsonObject();
        }
    }

    private JsonObject LoadJsonObject(string path)
    {
        if (!_fileSystem.FileExists(path))
        {
            return new JsonObject();
        }

        var stripped = StripJsonComments(_fileSystem.ReadAllText(path));
        try
        {
            if (JsonNode.Parse(stripped) is JsonObject obj)
            {
                return obj;
            }
        }
        catch (JsonException)
        {
            // Fall through to the parity error below.
        }

        throw new ConnectorConfigException($"Could not parse {LastPathComponent(path)} as JSON.");
    }

    private void WriteJsonObject(JsonObject obj, string path, bool backupExisting)
    {
        _fileSystem.CreateDirectory(DirectoryName(path));
        if (backupExisting && _fileSystem.FileExists(path))
        {
            var backupPath = path + $".openburnbar-backup-{BackupStamp()}";
            if (!_fileSystem.FileExists(backupPath))
            {
                _fileSystem.CopyFile(path, backupPath);
            }
        }

        _fileSystem.WriteAllText(path, SerializeSorted(obj));
    }

    private string BackupStamp() =>
        _clock.UtcNow.UtcDateTime.ToString("yyyyMMddHHmmss", CultureInfo.InvariantCulture);

    private static string SerializeSorted(JsonObject obj)
    {
        // Swift writes with .prettyPrinted + .sortedKeys.
        var sorted = SortKeys(obj) ?? new JsonObject();
        return sorted.ToJsonString(new JsonSerializerOptions { WriteIndented = true });
    }

    private static JsonNode? SortKeys(JsonNode? node)
    {
        switch (node)
        {
            case JsonObject obj:
                var sorted = new JsonObject();
                foreach (var key in obj.Select(pair => pair.Key).OrderBy(key => key, StringComparer.Ordinal))
                {
                    sorted[key] = SortKeys(obj[key]?.DeepClone());
                }

                return sorted;

            case JsonArray array:
                var copy = new JsonArray();
                foreach (var item in array)
                {
                    copy.Add(SortKeys(item?.DeepClone()));
                }

                return copy;

            default:
                return node?.DeepClone();
        }
    }

    private static JsonArray TakeArray(JsonObject root, string key) =>
        root[key] as JsonArray ?? new JsonArray();

    private static IReadOnlyList<JsonObject> ArrayOfObjects(JsonObject root, string key) =>
        (root[key] as JsonArray)?.OfType<JsonObject>().ToList() ?? new List<JsonObject>();

    private static string? RawString(JsonObject entry, string key) =>
        entry.TryGetPropertyValue(key, out var node) && node is JsonValue value && value.TryGetValue(out string? str)
            ? str
            : null;

    private static string? LowerString(JsonObject entry, string key) => RawString(entry, key)?.ToLowerInvariant();

    private string Join(params string[] parts)
    {
        var path = _homeDirectory;
        foreach (var part in parts)
        {
            path = path.TrimEnd('/') + "/" + part;
        }

        return path;
    }

    private static string DirectoryName(string path)
    {
        var index = path.LastIndexOf('/');
        return index <= 0 ? path : path.Substring(0, index);
    }

    private static string LastPathComponent(string path)
    {
        var index = path.LastIndexOf('/');
        return index < 0 ? path : path.Substring(index + 1);
    }

    /// <summary>Swift <c>stripJSONComments(_:)</c> — string-aware // and /* */ removal.</summary>
    public static string StripJsonComments(string source)
    {
        var result = new StringBuilder(source.Length);
        var inString = false;
        var escaped = false;
        var i = 0;
        while (i < source.Length)
        {
            var character = source[i];
            if (inString)
            {
                result.Append(character);
                if (escaped)
                {
                    escaped = false;
                }
                else if (character == '\\')
                {
                    escaped = true;
                }
                else if (character == '"')
                {
                    inString = false;
                }

                i++;
                continue;
            }

            if (character == '"')
            {
                inString = true;
                result.Append(character);
                i++;
                continue;
            }

            if (character == '/')
            {
                if (i + 1 >= source.Length)
                {
                    result.Append(character);
                    break;
                }

                var next = source[i + 1];
                if (next == '/')
                {
                    i += 2;
                    while (i < source.Length && source[i] != '\n')
                    {
                        i++;
                    }

                    result.Append('\n');
                    // Skip the newline itself (Swift's loop consumes it as the terminator).
                    if (i < source.Length)
                    {
                        i++;
                    }

                    continue;
                }

                if (next == '*')
                {
                    i += 2;
                    char? previous = null;
                    while (i < source.Length)
                    {
                        var skipped = source[i];
                        i++;
                        if (previous == '*' && skipped == '/')
                        {
                            break;
                        }

                        previous = skipped;
                    }

                    continue;
                }

                result.Append(character);
                result.Append(next);
                i += 2;
                continue;
            }

            result.Append(character);
            i++;
        }

        return result.ToString();
    }
}

/// <summary>Swift <c>NSError(domain: "RoutedClientConfigSync"/"CursorConnector")</c> peer.</summary>
public sealed class ConnectorConfigException : Exception
{
    /// <summary>Creates the exception with a user-facing message.</summary>
    public ConnectorConfigException(string message)
        : base(message)
    {
    }
}
