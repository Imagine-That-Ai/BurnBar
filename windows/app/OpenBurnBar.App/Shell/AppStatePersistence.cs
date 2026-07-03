using System;
using System.Collections.Generic;
using System.IO;
using System.Text.Json;
using System.Text.Json.Serialization;

namespace OpenBurnBar.App.Shell;

/// <summary>
/// The serialized shell UI state (appearance + flyout layout) persisted between runs.
/// This is <b>app-local UI chrome state only</b> — it is deliberately separate from the
/// Mac-DB storage read seam (#1198, <c>windows/storage/</c>), which owns real user data.
/// </summary>
public sealed class AppStateModel
{
    /// <summary>Persisted <see cref="Theme.AppearanceMode"/> as its lowercase string form.</summary>
    [JsonPropertyName("appearanceMode")]
    public string AppearanceMode { get; set; } = "system";

    /// <summary>
    /// Reduced-transparency override. <c>null</c> = follow the OS
    /// (<c>UISettings.AdvancedEffectsEnabled</c>); <c>true/false</c> = explicit user choice.
    /// </summary>
    [JsonPropertyName("reduceTransparency")]
    public bool? ReduceTransparency { get; set; }

    /// <summary>Last flyout width in DIPs (0 = use the default).</summary>
    [JsonPropertyName("flyoutWidth")]
    public double FlyoutWidth { get; set; }

    /// <summary>Last flyout height in DIPs (0 = use the default).</summary>
    [JsonPropertyName("flyoutHeight")]
    public double FlyoutHeight { get; set; }

    /// <summary>User-reordered flyout module keys, most-important first (empty = catalog default).</summary>
    [JsonPropertyName("flyoutModuleOrder")]
    public List<string> FlyoutModuleOrder { get; set; } = new();
}

/// <summary>
/// Loads and saves <see cref="AppStateModel"/> as a JSON file under LocalApplicationData.
/// Uses plain <see cref="System.IO"/> (not WinRT <c>ApplicationData</c>) so it works for the
/// unpackaged shell (<c>WindowsPackageType=None</c>) and stays unit-testable off-Windows.
/// All failures degrade to in-memory defaults — persistence is best-effort chrome state.
/// </summary>
public sealed class AppStatePersistence
{
    private static readonly JsonSerializerOptions JsonOptions = new()
    {
        WriteIndented = true,
        DefaultIgnoreCondition = JsonIgnoreCondition.WhenWritingNull,
    };

    private readonly string _path;
    private AppStateModel _state;

    /// <summary>Create a store rooted at the given file path (defaults to the per-user app folder).</summary>
    public AppStatePersistence(string? filePath = null)
    {
        _path = filePath ?? DefaultPath();
        _state = Load(_path);
    }

    /// <summary>The current in-memory state. Mutate then call <see cref="Save"/>.</summary>
    public AppStateModel State => _state;

    /// <summary>The default JSON location: <c>%LOCALAPPDATA%\OpenBurnBar\shell-state.json</c>.</summary>
    public static string DefaultPath()
    {
        var root = Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData);
        return Path.Combine(root, "OpenBurnBar", "shell-state.json");
    }

    /// <summary>Persist the current state; swallows IO/serialization errors (best-effort).</summary>
    public void Save()
    {
        try
        {
            var dir = Path.GetDirectoryName(_path);
            if (!string.IsNullOrEmpty(dir))
            {
                Directory.CreateDirectory(dir);
            }

            var json = JsonSerializer.Serialize(_state, JsonOptions);
            File.WriteAllText(_path, json);
        }
        catch (Exception)
        {
            // Chrome state is non-critical; never let a persistence failure crash the shell.
        }
    }

    private static AppStateModel Load(string path)
    {
        try
        {
            if (File.Exists(path))
            {
                var json = File.ReadAllText(path);
                var model = JsonSerializer.Deserialize<AppStateModel>(json, JsonOptions);
                if (model is not null)
                {
                    return model;
                }
            }
        }
        catch (Exception)
        {
            // Corrupt or unreadable state file → fall back to defaults.
        }

        return new AppStateModel();
    }
}
