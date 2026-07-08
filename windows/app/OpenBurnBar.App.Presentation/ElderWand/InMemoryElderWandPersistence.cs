using System;
using System.Collections.Generic;

namespace OpenBurnBar.App.Presentation.ElderWand;

/// <summary>
/// In-memory <see cref="IElderWandPresetPersistence"/> — the reusable dev-host / non-test analog of
/// the string-keyed <c>SettingsPersistenceCoordinator</c>. Mirrors the
/// <see cref="OpenBurnBar.App.Presentation.Switcher.InMemorySwitcherProfileStore"/> +
/// <c>InMemoryBudgetRuleStore</c> pattern: the same contract the encrypted Windows settings store
/// implements, so the <see cref="ElderWandSettingsModel"/> runs unchanged against it under
/// <c>dotnet test</c> on macOS and when hosted before the storage seam lands.
/// </summary>
public sealed class InMemoryElderWandPersistence : IElderWandPresetPersistence
{
    private readonly Dictionary<string, string> _store = new(StringComparer.Ordinal);

    /// <summary>Create an empty store, or seed it with initial key/value pairs.</summary>
    public InMemoryElderWandPersistence(IEnumerable<KeyValuePair<string, string>>? seed = null)
    {
        if (seed is null)
        {
            return;
        }

        foreach (var pair in seed)
        {
            _store[pair.Key] = pair.Value;
        }
    }

    /// <inheritdoc />
    public string? ReadString(string key) =>
        _store.TryGetValue(key, out var value) ? value : null;

    /// <inheritdoc />
    public void WriteString(string key, string value) =>
        _store[key ?? throw new ArgumentNullException(nameof(key))] = value;
}
