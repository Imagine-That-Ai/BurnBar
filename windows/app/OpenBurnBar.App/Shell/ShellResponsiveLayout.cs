namespace OpenBurnBar.App.Shell;

/// <summary>Deterministic shell breakpoints shared by WinUI and portable tests.</summary>
internal readonly record struct ShellResponsiveLayout(
    bool ShowBrandWordmark,
    bool ShowPaletteLabel,
    bool ShowPaletteShortcut,
    bool ShowTabLabels)
{
    internal const double CompactHeaderBreakpoint = 760;
    internal const double CompactTabsBreakpoint = 700;

    internal static ShellResponsiveLayout ForWidth(double width)
    {
        bool compactHeader = width < CompactHeaderBreakpoint;
        return new ShellResponsiveLayout(
            ShowBrandWordmark: !compactHeader,
            ShowPaletteLabel: !compactHeader,
            ShowPaletteShortcut: !compactHeader,
            ShowTabLabels: width >= CompactTabsBreakpoint);
    }
}
