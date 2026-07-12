using System;
using Microsoft.Win32;

namespace OpenBurnBar.App.Theme;

/// <summary>
/// Production <see cref="ILiquidGlassPreferenceStore"/> backed by
/// <c>HKCU\Software\OpenBurnBar\LiquidGlass</c> — the Windows analog of macOS
/// <c>UserDefaults</c> for the shared Liquid Glass + kernel backdrop keys.
/// Best-effort: registry failures degrade to defaults without throwing so chrome
/// state never crashes the shell.
/// </summary>
public sealed class RegistryLiquidGlassPreferenceStore : ILiquidGlassPreferenceStore
{
    public const string RegistryPath = @"Software\OpenBurnBar\LiquidGlass";

    private readonly string _path;

    public RegistryLiquidGlassPreferenceStore(string? registryPath = null)
    {
        _path = string.IsNullOrWhiteSpace(registryPath) ? RegistryPath : registryPath;
    }

    public double GetDouble(string key, double defaultValue)
    {
        try
        {
            using var keyNode = Registry.CurrentUser.OpenSubKey(_path);
            object? raw = keyNode?.GetValue(key);
            if (raw is null)
            {
                return defaultValue;
            }

            if (raw is double d)
            {
                return d;
            }

            if (raw is int i)
            {
                return i;
            }

            if (raw is string s && double.TryParse(s, System.Globalization.NumberStyles.Float,
                    System.Globalization.CultureInfo.InvariantCulture, out double parsed))
            {
                return parsed;
            }
        }
        catch (Exception)
        {
            // Best-effort chrome state.
        }

        return defaultValue;
    }

    public void SetDouble(string key, double value)
    {
        try
        {
            using var keyNode = Registry.CurrentUser.CreateSubKey(_path);
            keyNode?.SetValue(key, value.ToString(System.Globalization.CultureInfo.InvariantCulture), RegistryValueKind.String);
        }
        catch (Exception)
        {
            // Best-effort chrome state.
        }
    }

    public bool GetBool(string key, bool defaultValue)
    {
        try
        {
            using var keyNode = Registry.CurrentUser.OpenSubKey(_path);
            object? raw = keyNode?.GetValue(key);
            if (raw is null)
            {
                return defaultValue;
            }

            if (raw is int i)
            {
                return i != 0;
            }

            if (raw is string s)
            {
                if (bool.TryParse(s, out bool b))
                {
                    return b;
                }

                if (s == "1")
                {
                    return true;
                }

                if (s == "0")
                {
                    return false;
                }
            }
        }
        catch (Exception)
        {
            // Best-effort chrome state.
        }

        return defaultValue;
    }

    public void SetBool(string key, bool value)
    {
        try
        {
            using var keyNode = Registry.CurrentUser.CreateSubKey(_path);
            keyNode?.SetValue(key, value ? 1 : 0, RegistryValueKind.DWord);
        }
        catch (Exception)
        {
            // Best-effort chrome state.
        }
    }

    public string GetString(string key, string defaultValue)
    {
        try
        {
            using var keyNode = Registry.CurrentUser.OpenSubKey(_path);
            object? raw = keyNode?.GetValue(key);
            if (raw is string s && !string.IsNullOrEmpty(s))
            {
                return s;
            }
        }
        catch (Exception)
        {
            // Best-effort chrome state.
        }

        return defaultValue;
    }

    public void SetString(string key, string value)
    {
        try
        {
            using var keyNode = Registry.CurrentUser.CreateSubKey(_path);
            keyNode?.SetValue(key, value ?? string.Empty, RegistryValueKind.String);
        }
        catch (Exception)
        {
            // Best-effort chrome state.
        }
    }
}
