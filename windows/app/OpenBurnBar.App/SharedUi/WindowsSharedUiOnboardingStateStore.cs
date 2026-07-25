using OpenBurnBar.App.Settings.Winui;

namespace OpenBurnBar.App.SharedUi;

/// <summary>
/// Persists the onboarding privacy choices (telemetry / cloud sync) in the
/// shared Windows settings store — the same settings.json the native surfaces
/// use — so the SharedUi onboarding machine and the config snapshot read the
/// one honest set of booleans.
/// </summary>
internal sealed class WindowsSharedUiOnboardingStateStore : ISharedUiOnboardingStateStore
{
    private const string Key = "sharedUiOnboarding";

    private readonly WindowsSettingsPersistence _persistence;

    public WindowsSharedUiOnboardingStateStore(WindowsSettingsPersistence persistence) =>
        _persistence = persistence;

    public (bool TelemetryEnabled, bool CloudSyncEnabled, int Revision) Load()
    {
        var state = _persistence.Read(Key, PersistedState.Default);
        return (state.TelemetryEnabled, state.CloudSyncEnabled, state.Revision);
    }

    public void Save(bool telemetryEnabled, bool cloudSyncEnabled, int revision) =>
        _persistence.Write(Key, new PersistedState(telemetryEnabled, cloudSyncEnabled, revision));

    private sealed record PersistedState(bool TelemetryEnabled, bool CloudSyncEnabled, int Revision)
    {
        public static PersistedState Default { get; } = new(false, false, 0);
    }
}
