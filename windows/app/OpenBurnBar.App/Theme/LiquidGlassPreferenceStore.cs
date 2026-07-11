using System;
using System.Collections.Generic;

namespace OpenBurnBar.App.Theme;

/// <summary>
/// Persistence seam mirroring macOS <c>UserDefaults</c> for Liquid Glass + kernel
/// backdrop keys. Production uses <see cref="RegistryLiquidGlassPreferenceStore"/>;
/// tests use <see cref="InMemoryPreferenceStore"/>. Pure System — no WinUI dependency
/// so the theme unit suite can link this file on macOS.
/// </summary>
public interface ILiquidGlassPreferenceStore
{
    double GetDouble(string key, double defaultValue);
    void SetDouble(string key, double value);
    bool GetBool(string key, bool defaultValue);
    void SetBool(string key, bool value);
    string GetString(string key, string defaultValue);
    void SetString(string key, string value);
}

/// <summary>Default in-memory preference store (UserDefaults analog for tests + headless).</summary>
public sealed class InMemoryPreferenceStore : ILiquidGlassPreferenceStore
{
    private readonly Dictionary<string, object> _values = new();

    public double GetDouble(string key, double defaultValue) =>
        _values.TryGetValue(key, out var v) && v is double d ? d : defaultValue;

    public void SetDouble(string key, double value) => _values[key] = value;

    public bool GetBool(string key, bool defaultValue) =>
        _values.TryGetValue(key, out var v) && v is bool b ? b : defaultValue;

    public void SetBool(string key, bool value) => _values[key] = value;

    public string GetString(string key, string defaultValue) =>
        _values.TryGetValue(key, out var v) && v is string s ? s : defaultValue;

    public void SetString(string key, string value) => _values[key] = value ?? string.Empty;

    /// <summary>Whether a key has been explicitly written (tests use this to prove persistence).</summary>
    public bool Contains(string key) => _values.ContainsKey(key);
}
