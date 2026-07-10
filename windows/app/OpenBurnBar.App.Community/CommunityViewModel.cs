using System.ComponentModel;
using System.Runtime.CompilerServices;

namespace OpenBurnBar.App.Community;

/// <summary>
/// MVVM state for the Community surface — personal hero, leaderboards, consent center.
/// Hosts may inject signed-in Firestore snapshots through <see cref="ApplyLiveData"/>;
/// otherwise the surface renders explicit preview/empty states without fabricated ranks.
/// </summary>
public sealed class CommunityViewModel : INotifyPropertyChanged
{
    private readonly CommunityConsentStore _consentStore;
    private CommunityTimeWindow _window = CommunityTimeWindow.ThirtyDay;
    private CommunityLiveData _liveData = new();
    private long _heroTokens;
    private double _heroCostUsd;
    private double _trendDeltaPct;
    private string _modelMixSummary = "—";
    private string _statusMessage = string.Empty;
    private bool _isPreviewData;

    public CommunityViewModel(CommunityConsentStore? consentStore = null, CommunityLiveData? liveData = null)
    {
        _consentStore = consentStore ?? new CommunityConsentStore();
        _liveData = liveData ?? new CommunityLiveData();
        ReloadFromStore();
        RefreshDerived();
    }

    public event PropertyChangedEventHandler? PropertyChanged;

    public CommunityConsentState Consent => _consentStore.State;

    public CommunityTimeWindow Window
    {
        get => _window;
        set
        {
            if (_window == value) return;
            _window = value;
            OnPropertyChanged();
            RefreshDerived();
        }
    }

    public long HeroTokens
    {
        get => _heroTokens;
        private set { if (_heroTokens == value) return; _heroTokens = value; OnPropertyChanged(); }
    }

    public double HeroCostUsd
    {
        get => _heroCostUsd;
        private set { if (Math.Abs(_heroCostUsd - value) < 0.0001) return; _heroCostUsd = value; OnPropertyChanged(); }
    }

    public double TrendDeltaPct
    {
        get => _trendDeltaPct;
        private set { if (Math.Abs(_trendDeltaPct - value) < 0.0001) return; _trendDeltaPct = value; OnPropertyChanged(); }
    }

    public string ModelMixSummary
    {
        get => _modelMixSummary;
        private set { if (_modelMixSummary == value) return; _modelMixSummary = value; OnPropertyChanged(); }
    }

    public string StatusMessage
    {
        get => _statusMessage;
        private set { if (_statusMessage == value) return; _statusMessage = value; OnPropertyChanged(); }
    }

    public bool IsPreviewData
    {
        get => _isPreviewData;
        private set { if (_isPreviewData == value) return; _isPreviewData = value; OnPropertyChanged(); }
    }

    public string LookingGlassExportMessage { get; private set; } =
        "Looking Glass export is not wired on Windows yet. Grant L3 for when signed-in export is available; leaderboards never use traces.";

    public IReadOnlyList<CommunityLeaderboardCard> Leaderboards { get; private set; } = Array.Empty<CommunityLeaderboardCard>();

    public PercentileBands PercentileStrip { get; private set; } = new(0, 0, 0, 0);

    public IReadOnlyList<double> PeerCohortTokens { get; private set; } = Array.Empty<double>();

    public IReadOnlyList<PurposeSlice> PurposeBreakdown { get; private set; } = Array.Empty<PurposeSlice>();

    public string ConsentPreviewSummary { get; private set; } = string.Empty;
    public string CityConfidenceCopy { get; private set; } = string.Empty;

    public bool ShowInviteEmptyState { get; private set; } = true;

    public void CycleL1() => SetConsent(c => c with { L1Analytics = c.L1Analytics.Cycle() });

    public void CycleL2Rankings() => SetConsent(c => c with { L2Rankings = c.L2Rankings.Cycle() });

    public void CycleL3() => SetConsent(c => c with { L3LookingGlass = c.L3LookingGlass.Cycle() });

    public void CycleLocation() => SetConsent(c => c with { LocationConsent = c.LocationConsent.Cycle() });

    public void SetManualCityInput(string? value) =>
        SetConsent(c => c with { ManualCityInput = string.IsNullOrEmpty(value) ? null : value });

    public void CycleTier(GeographyTier tier)
    {
        var tiers = Consent.L2Tiers;
        var updated = tier switch
        {
            GeographyTier.World => tiers with { World = tiers.World.Cycle() },
            GeographyTier.Country => tiers with { Country = tiers.Country.Cycle() },
            GeographyTier.Region => tiers with { Region = tiers.Region.Cycle() },
            _ => tiers with { City = tiers.City.Cycle() },
        };
        SetConsent(c => c with { L2Tiers = updated });
    }


    public void ApplyLiveData(CommunityLiveData liveData)
    {
        _liveData = liveData;
        RefreshDerived();
    }
    public void RevokeAllParticipation()
    {
        var declined = ConsentTriState.Declined;
        var tiers = new CommunityTierConsent(declined, declined, declined, declined);
        SetConsent(_ => new CommunityConsentState(
            declined,
            declined,
            tiers,
            declined,
            declined,
            DateTimeOffset.UtcNow,
            ManualCityInput: null));
        StatusMessage = "Participation paused locally. Sync revoke via your signed-in account when online.";
    }

    private void SetConsent(Func<CommunityConsentState, CommunityConsentState> mutate)
    {
        var next = mutate(Consent);
        _consentStore.Replace(next);
        OnPropertyChanged(nameof(Consent));
        RefreshDerived();
    }

    private void ReloadFromStore() => OnPropertyChanged(nameof(Consent));

    private void RefreshDerived()
    {
        var l2Active = Consent.L2Rankings.IsActive();
        IsPreviewData = l2Active;
        ShowInviteEmptyState = !l2Active;
        ConsentPreviewSummary = BuildConsentPreview();
        CityConfidenceCopy = BuildCityConfidenceCopy();
        LookingGlassExportMessage = Consent.L3LookingGlass.IsActive()
            ? "Looking Glass export is not wired on Windows yet. Grant L3 for when signed-in export is available; leaderboards never use traces."
            : "Looking Glass export: grant L3 to create a private bundle; leaderboard rankings never use traces.";

        if (!l2Active)
        {
            HeroTokens = 0;
            HeroCostUsd = 0;
            TrendDeltaPct = 0;
            ModelMixSummary = "Opt in to L2 rankings to preview your share snapshot.";
            Leaderboards = BuildThresholdOnlyCards();
            PercentileStrip = new(0, 0, 0, 0);
            PeerCohortTokens = Array.Empty<double>();
            PurposeBreakdown = Array.Empty<PurposeSlice>();
            StatusMessage = string.Empty;
            return;
        }

        var leaderboards = BuildLiveCards();
        var primary = leaderboards.FirstOrDefault(card => !card.BelowThreshold && card.Entries.Count > 0) ?? leaderboards.FirstOrDefault();
        var usage = UsageForCurrentWindow(_liveData.ShareSnapshot);
        var hasLiveData = _liveData.ShareSnapshot is not null || leaderboards.Any(card => card.Entries.Count > 0 || card.CohortSize > 0);

        HeroTokens = usage.TotalTokens;
        HeroCostUsd = usage.CostUsd;
        TrendDeltaPct = 0;
        ModelMixSummary = hasLiveData
            ? SummarizeModelMix(_liveData.ShareSnapshot?.ModelMix)
            : "Preview only — live leaderboards sync after community preferences save.";
        StatusMessage = hasLiveData
            ? "Live community data synced. Public boards remain anonymous and threshold-gated."
            : "Preview layout only — no live leaderboard or cohort data is shown on this surface yet.";
        IsPreviewData = !hasLiveData;
        Leaderboards = leaderboards;
        PercentileStrip = primary?.Percentiles ?? new PercentileBands(0, 0, 0, 0);
        PeerCohortTokens = primary is { BelowThreshold: false }
            ? primary.Entries.Select(entry => (double)entry.TotalTokens).ToArray()
            : Array.Empty<double>();
        PurposeBreakdown = BuildPurposeBreakdown(_liveData.ShareSnapshot);
    }

    private IReadOnlyList<CommunityLeaderboardCard> BuildThresholdOnlyCards()
    {
        var cards = new List<CommunityLeaderboardCard>();
        foreach (var tier in CommunityTierOrder.Display)
        {
            cards.Add(new CommunityLeaderboardCard(
                tier,
                CommunityGeoDisplay.ResolveLabel(Consent, tier),
                CommunityGeoDisplay.ResolveConfidenceCopy(Consent, tier),
                Array.Empty<LeaderboardEntry>(),
                new PercentileBands(0, 0, 0, 0),
                0,
                BelowThreshold: true,
                KThreshold: 10,
                YourRank: null,
                YourMovement: null));
        }

        return cards;
    }

    private IReadOnlyList<CommunityLeaderboardCard> BuildLiveCards()
    {
        var fallback = BuildPreviewCards();
        var byTier = (_liveData.Leaderboards ?? Array.Empty<CommunityLeaderboardCard>())
            .GroupBy(card => card.Tier)
            .ToDictionary(group => group.Key, group => group.First());
        return CommunityTierOrder.Display
            .Select((tier, index) => byTier.TryGetValue(tier, out var card) ? card : fallback[index])
            .ToArray();
    }

    private IReadOnlyList<CommunityLeaderboardCard> BuildPreviewCards()
    {
        var cards = new List<CommunityLeaderboardCard>();
        foreach (var tier in CommunityTierOrder.Display)
        {
            cards.Add(new CommunityLeaderboardCard(
                tier,
                CommunityGeoDisplay.ResolveLabel(Consent, tier),
                CommunityGeoDisplay.ResolveConfidenceCopy(Consent, tier),
                Array.Empty<LeaderboardEntry>(),
                new PercentileBands(0, 0, 0, 0),
                0,
                BelowThreshold: true,
                KThreshold: 10,
                YourRank: null,
                YourMovement: null));
        }

        return cards;
    }

    private CommunityUsageTotal UsageForCurrentWindow(CommunityShareSnapshotDoc? snapshot)
    {
        if (snapshot is null) return new CommunityUsageTotal(0, 0);
        return Window switch
        {
            CommunityTimeWindow.Today => snapshot.Windows.Today,
            CommunityTimeWindow.SevenDay => snapshot.Windows.SevenDay,
            CommunityTimeWindow.ThirtyDay => snapshot.Windows.ThirtyDay,
            CommunityTimeWindow.NinetyDay => snapshot.Windows.NinetyDay,
            _ => snapshot.Windows.AllTime,
        };
    }

    private static string SummarizeModelMix(IReadOnlyDictionary<string, double>? modelMix)
    {
        var entries = (modelMix ?? new Dictionary<string, double>())
            .Where(pair => double.IsFinite(pair.Value) && pair.Value > 0)
            .OrderByDescending(pair => pair.Value)
            .Take(2)
            .Select(pair => $"{pair.Key} {Math.Round(pair.Value * 100)}%");
        var summary = string.Join(" · ", entries);
        return string.IsNullOrWhiteSpace(summary)
            ? "Live share snapshot synced; model mix appears after usage accrues."
            : $"Top models: {summary}";
    }

    private static IReadOnlyList<PurposeSlice> BuildPurposeBreakdown(CommunityShareSnapshotDoc? snapshot)
    {
        if (snapshot is null) return Array.Empty<PurposeSlice>();
        var entries = snapshot.PurposeMix
            .Where(pair => double.IsFinite(pair.Value) && pair.Value > 0)
            .OrderByDescending(pair => pair.Value)
            .ToArray();
        var total = entries.Sum(pair => pair.Value);
        if (total <= 0) return Array.Empty<PurposeSlice>();
        return entries.Select(pair => new PurposeSlice(pair.Key, pair.Value / total)).ToArray();
    }

    private string BuildConsentPreview()
    {
        var c = Consent;
        return $"L1 {c.L1Analytics.Label()} · L2 {c.L2Rankings.Label()} · L3 {c.L3LookingGlass.Label()} · Location {c.LocationConsent.Label()}";
    }

    private string BuildCityConfidenceCopy()
    {
        var c = Consent;
        if (!c.L2Rankings.IsActive() || !c.L2Tiers.City.IsActive())
        {
            return "City confidence: no city lookup. Country and region can use locale/timezone; world ranking needs no location.";
        }

        if (!c.LocationConsent.IsActive())
        {
            return "City confidence: city rank is paused until approximate location is granted; broader tiers still use locale/timezone.";
        }

        if (!string.IsNullOrWhiteSpace(c.ManualCityInput))
        {
            return "City confidence: manual city label only; BurnBar stores the canonical city key, never raw coordinates.";
        }

        return "City confidence: Windows approximate location resolves on save; BurnBar stores only the city key, never raw coordinates.";
    }

    private void OnPropertyChanged([CallerMemberName] string? name = null) =>
        PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(name));
}
