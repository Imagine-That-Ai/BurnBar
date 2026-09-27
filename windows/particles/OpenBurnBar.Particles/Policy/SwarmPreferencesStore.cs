// File-backed swarm prefs for the Windows resolve site. Shape mirrors the
// Android `SwarmBackgroundPreferencesStore` (process-wide singleton prefs,
// eager read, fire-and-forget writes) with the Windows persistence posture
// of `AppStatePersistence`: plain System.IO under the app-data dir (not
// WinRT ApplicationData) so it works unpackaged and stays unit-testable
// off-Windows. All failures degrade to in-memory defaults.
//
// Default split (the Android precedent, verbatim rationale): a MISSING file
// resolves to UnsetDefault (everywhere/always) because the Windows swarm
// surfaces have always been on — the historical look is preserved until the
// user picks otherwise. A PRESENT file decodes through the cross-platform
// `SwarmBackgroundPreferences.From` codec, whose corrupt-payload default
// stays disabled per the iOS contract, so a torn write self-heals instead
// of half-applying. Writes go through tmp+move so a crash mid-save cannot
// leave a torn file behind.

using System;
using System.IO;

namespace OpenBurnBar.Particles.Policy;

/// <summary>
/// Loads and saves <see cref="SwarmBackgroundPreferences"/> as a JSON file.
/// Inject the path in tests; production passes the app-data path.
/// </summary>
public sealed class SwarmPreferencesStore
{
    /// <summary>File name under the app-data dir (<c>RuntimePaths</c>).</summary>
    public const string FileName = "swarm-background.json";

    /// <summary>
    /// Effective prefs when no file exists yet: everywhere/always (the
    /// Windows historical always-on look) with every other field at its
    /// codec default. The JSON codec default stays disabled per the iOS
    /// cross-platform contract; this default applies only to the unset file.
    /// </summary>
    public static readonly SwarmBackgroundPreferences UnsetDefault = new(
        SwarmBackgroundLocation.Everywhere, SwarmBackgroundCondition.Always);

    private readonly string _path;
    private SwarmBackgroundPreferences _preferences;

    /// <summary>Create a store rooted at the given file path.</summary>
    public SwarmPreferencesStore(string filePath)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(filePath);
        _path = filePath;
        _preferences = Load(_path);
    }

    /// <summary>The current in-memory prefs. Mutate via <see cref="Update"/>.</summary>
    public SwarmBackgroundPreferences Preferences => _preferences;

    /// <summary>Replace the in-memory prefs and persist them (best-effort).</summary>
    public void Update(SwarmBackgroundPreferences preferences)
    {
        ArgumentNullException.ThrowIfNull(preferences);
        _preferences = preferences;
        Save(_path, _preferences);
    }

    /// <summary>Re-read the file (a settings surface calls this after an external edit).</summary>
    public void Reload() => _preferences = Load(_path);

    private static SwarmBackgroundPreferences Load(string path)
    {
        bool exists;
        try
        {
            exists = File.Exists(path);
        }
        catch (Exception)
        {
            return UnsetDefault;
        }

        if (!exists)
        {
            return UnsetDefault;
        }

        try
        {
            return SwarmBackgroundPreferences.From(File.ReadAllText(path));
        }
        catch (Exception)
        {
            // Present but unreadable → the codec default, like a corrupt payload.
            return new SwarmBackgroundPreferences();
        }
    }

    private static void Save(string path, SwarmBackgroundPreferences preferences)
    {
        string? temporary = null;
        try
        {
            string? directory = Path.GetDirectoryName(path);
            if (!string.IsNullOrEmpty(directory))
            {
                Directory.CreateDirectory(directory);
            }

            temporary = path + ".tmp-" + Guid.NewGuid().ToString("N");
            File.WriteAllText(temporary, preferences.ToJsonString());
            File.Move(temporary, path, overwrite: true);
            temporary = null;
        }
        catch (Exception)
        {
            // Prefs are non-critical; never let a persistence failure crash the host.
        }
        finally
        {
            if (temporary is not null)
            {
                try
                {
                    File.Delete(temporary);
                }
                catch (Exception)
                {
                    // Best-effort cleanup only.
                }
            }
        }
    }
}
