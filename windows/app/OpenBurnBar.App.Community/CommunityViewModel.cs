using System.ComponentModel;
using System.Runtime.CompilerServices;

namespace OpenBurnBar.App.Community;

/// <summary>
/// MVVM state for the Community surface — personal hero, leaderboards, consent center.
/// Live Firestore leaderboards are not wired on Windows yet; opted-in users see explicit preview/empty states.
/// </summary>
public sealed class CommunityViewModel : INotifyPropertyChanged
{
    private readonly CommunityConsentStore _consentStore;
    private CommunityTimeWindow _window = CommunityTimeWindow.ThirtyDay;
    private long _heroTokens;
    private double _heroCostUsd;
    private double _trendDeltaPct;
    private string _modelMixSummary = "—";
    private string _statusMessage = string.Empty;
    private bool _isPreviewData;

    public CommunityViewModel(CommunityConsentStore? consentStore = null)
    {
        _consentStore = consentStore ?? new CommunityConsentStore();
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
        SetConsent(c => c with { ManualCityInput = string.IsNullOrWhiteSpace(value) ? null : value.Trim() });

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
            return;
        }

        HeroTokens = 0;
        HeroCostUsd = 0;
        TrendDeltaPct = 0;
        ModelMixSummary = "Preview only — live leaderboards sync after community preferences save.";
        StatusMessage = "Preview layout only — no live leaderboard or cohort data is shown on this surface yet.";
        Leaderboards = BuildPreviewCards();
        PercentileStrip = new(0, 0, 0, 0);
        PeerCohortTokens = Array.Empty<double>();
        PurposeBreakdown = Array.Empty<PurposeSlice>();
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