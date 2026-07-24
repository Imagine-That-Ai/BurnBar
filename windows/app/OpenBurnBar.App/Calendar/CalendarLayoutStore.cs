using OpenBurnBar.App.Presentation.Calendar;
using OpenBurnBar.App.Settings.Winui;

namespace OpenBurnBar.App.Calendar;

/// <summary>
/// Persists the Calendar analytics-card layout (order / visibility / S·M·L spans)
/// through the app's settings persistence — the same key-value JSON store every
/// other surface uses (<c>WindowsSettingsPersistence</c>). The portable
/// <see cref="CalendarPageLayout"/> owns the forward-compatible JSON contract;
/// this is the thin binding, the Windows peer of the macOS
/// <c>UserDefaults[CalendarPageLayout.storageKey]</c> read/write.
/// </summary>
internal sealed class CalendarLayoutStore
{
    /// <summary>Settings key; the exact macOS <c>calendarPageLayout.v1</c> storage key.</summary>
    internal const string Key = "calendarPageLayout.v1";

    private readonly WindowsSettingsPersistence _persistence;

    public CalendarLayoutStore(WindowsSettingsPersistence persistence)
    {
        _persistence = persistence;
    }

    public CalendarPageLayout Load() =>
        CalendarPageLayout.Decode(_persistence.Read(Key, string.Empty));

    public void Save(CalendarPageLayout layout) =>
        _persistence.Write(Key, layout.Encode());
}
