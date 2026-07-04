using System.Collections.Generic;
using System.Linq;

namespace OpenBurnBar.App.Presentation.MissionControl;

// PORTED (faithful) from MissionRuntimeConstellation
// (OpenBurnBarCore/.../MissionControl/MissionRuntimeConstellation.swift). A display-ready row
// item for the runtime constellation: the AUTO card is always first, then each advertised
// runtime, each carrying its selection + "preferred for {kind}" state and the exact card-body
// subtitle the Swift renders. Pure so the constellation's copy is unit-testable on macOS.

/// <summary>One card in the runtime constellation.</summary>
public sealed class MissionRuntimeCardItem
{
    public MissionRuntimeCardItem(
        string id,
        string displayName,
        string callSign,
        string providerKey,
        RuntimeAvailability availability,
        bool isAuto,
        bool isSelected,
        bool isPreferred,
        string preferredLabel,
        string subtitle)
    {
        Id = id;
        DisplayName = displayName;
        CallSign = callSign;
        ProviderKey = providerKey;
        Availability = availability;
        IsAuto = isAuto;
        IsSelected = isSelected;
        IsPreferred = isPreferred;
        PreferredLabel = preferredLabel;
        Subtitle = subtitle;
    }

    public string Id { get; }
    public string DisplayName { get; }
    public string CallSign { get; }
    public string ProviderKey { get; }
    public RuntimeAvailability Availability { get; }
    public bool IsAuto { get; }
    public bool IsSelected { get; }
    public bool IsPreferred { get; }
    public string PreferredLabel { get; }
    public string Subtitle { get; }

    /// <summary>Whether the "preferred for {kind}" hint should show (preferred, unselected,
    /// non-auto). Mirrors the Swift <c>isPreferred &amp;&amp; !isSelected &amp;&amp; !isAuto</c> gate.</summary>
    public bool ShowsPreferredHint => IsPreferred && !IsSelected && !IsAuto;

    /// <summary>Build the constellation rows for the current runtimes + selection + kind.</summary>
    public static IReadOnlyList<MissionRuntimeCardItem> Build(
        IReadOnlyList<MissionRuntime> runtimes,
        string selectedRuntimeId,
        MissionKind kind)
    {
        var items = new List<MissionRuntimeCardItem>();

        string? preferredFirst = MissionKindInfo.PreferredRuntimes(kind).FirstOrDefault();
        string kindName = MissionKindInfo.DisplayName(kind);

        items.Add(Card(MissionRuntime.Auto, isAuto: true, selectedRuntimeId, preferredFirst, kindName));
        foreach (MissionRuntime runtime in runtimes)
        {
            items.Add(Card(runtime, isAuto: false, selectedRuntimeId, preferredFirst, kindName));
        }

        return items;
    }

    private static MissionRuntimeCardItem Card(
        MissionRuntime runtime,
        bool isAuto,
        string selectedRuntimeId,
        string? preferredFirst,
        string kindName)
    {
        bool isSelected = runtime.Id == selectedRuntimeId;
        bool isPreferred = !isAuto && preferredFirst == runtime.Id;

        return new MissionRuntimeCardItem(
            id: runtime.Id,
            displayName: runtime.DisplayName,
            callSign: runtime.CallSign,
            providerKey: runtime.ProviderKey,
            availability: runtime.Availability,
            isAuto: isAuto,
            isSelected: isSelected,
            isPreferred: isPreferred,
            preferredLabel: $"Preferred for {kindName}",
            subtitle: BuildSubtitle(runtime, isAuto));
    }

    /// <summary>The card-body line. Mirrors the Swift card: tagline, else median history, else
    /// "No recent history" (non-auto).</summary>
    private static string BuildSubtitle(MissionRuntime runtime, bool isAuto)
    {
        if (!string.IsNullOrEmpty(runtime.Tagline))
        {
            return runtime.Tagline!;
        }

        if (runtime.RecentMedianBurnUsd is double median && runtime.RecentSampleSize > 0)
        {
            string cost = MissionFormatting.Cost(median, median < 1);
            return $"{cost} median · n={runtime.RecentSampleSize}";
        }

        return isAuto ? string.Empty : "No recent history";
    }
}
