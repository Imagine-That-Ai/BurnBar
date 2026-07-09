using System.ComponentModel;
using System.Runtime.CompilerServices;

namespace OpenBurnBar.App.Community;

/// <summary>
/// MVVM state for the Community surface — personal hero, leaderboards, consent center.
/// Sample leaderboard data is shown only when L2 rankings consent is active locally;
/// below-threshold boards never surface individual rows.
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
    private bool _useSamplePreview;

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

    public bool UseSamplePreview
    {
        get => _useSamplePreview;
        private set { if (_useSamplePreview == value) return; _useSamplePreview = value; OnPropertyChanged(); }
    }

    public IReadOnlyList<CommunityLeaderboardCard> Leaderboards { get; private set; } = Array.Empty<CommunityLeaderboardCard>();

    public PercentileBands PercentileStrip { get; private set; } = new(0, 0, 0, 0);

    public IReadOnlyList<double> PeerCohortTokens { get; private set; } = Array.Empty<double>();

    public IReadOnlyList<PurposeSlice> PurposeBreakdown { get; private set; } = Array.Empty<PurposeSlice>();

    public string ConsentPreviewSummary { get; private set; } = string.Empty;

    public bool ShowInviteEmptyState { get; private set; } = true;

    public void CycleL1() => SetConsent(c => c with { L1Analytics = c.L1Analytics.Cycle() });

    public void CycleL2Rankings() => SetConsent(c => c with { L2Rankings = c.L2Rankings.Cycle() });

    public void CycleL3() => SetConsent(c => c with { L3LookingGlass = c.L3LookingGlass.Cycle() });

    public void CycleLocation() => SetConsent(c => c with { LocationConsent = c.LocationConsent.Cycle() });

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
            DateTimeOffset.UtcNow));
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
        UseSamplePreview = l2Active;
        ShowInviteEmptyState = !l2Active;

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
            ConsentPreviewSummary = BuildConsentPreview();
            return;
        }

        HeroTokens = Window switch
        {
            CommunityTimeWindow.Today => 42_000,
            CommunityTimeWindow.SevenDay => 310_000,
            CommunityTimeWindow.NinetyDay => 1_450_000,
            CommunityTimeWindow.All => 3_200_000,
            _ => 890_000,
        };
        HeroCostUsd = Math.Round(HeroTokens * 0.0000028, 2);
        TrendDeltaPct = 12.4;
        ModelMixSummary = "claude-3.5-sonnet 42% · gpt-4o 31% · deepseek 27%";

        Leaderboards = BuildSampleLeaderboards();
        PercentileStrip = ResolvePercentileStrip(Leaderboards);
        PeerCohortTokens = new[] { 120_000d, 185_000, 240_000, 310_000, 420_000, 580_000 };
        PurposeBreakdown = BuildPurposeBreakdown();
        ConsentPreviewSummary = BuildConsentPreview();
        StatusMessage = string.Empty;
    }

    private IReadOnlyList<CommunityLeaderboardCard> BuildThresholdOnlyCards()
    {
        var cards = new List<CommunityLeaderboardCard>();
        foreach (var tier in CommunityTierOrder.Display)
        {
            var needs = tier == GeographyTier.City ? 10 : 10;
            cards.Add(new CommunityLeaderboardCard(
                tier,
                SampleGeoLabel(tier),
                Array.Empty<LeaderboardEntry>(),
                new PercentileBands(0, 0, 0, 0),
                0,
                BelowThreshold: true,
                KThreshold: needs,
                YourRank: null,
                YourMovement: null));
        }

        return cards;
    }

    private IReadOnlyList<CommunityLeaderboardCard> BuildSampleLeaderboards()
    {
        var cards = new List<CommunityLeaderboardCard>();
        foreach (var tier in CommunityTierOrder.Display)
        {
            var below = tier == GeographyTier.City && !Consent.LocationConsent.IsActive();
            if (below)
            {
                cards.Add(new CommunityLeaderboardCard(
                    tier,
                    SampleGeoLabel(tier),
                    Array.Empty<LeaderboardEntry>(),
                    new PercentileBands(0, 0, 0, 0),
                    0,
                    true,
                    10,
                    null,
                    null));
                continue;
            }

            var entries = SampleEntries(tier);
            cards.Add(new CommunityLeaderboardCard(
                tier,
                SampleGeoLabel(tier),
                entries,
                new PercentileBands(180_000, 320_000, 510_000, 920_000),
                CohortSize: 48,
                BelowThreshold: false,
                KThreshold: 10,
                YourRank: 12,
                YourMovement: RankMovement.Up));
        }

        return cards;
    }

    private static PercentileBands ResolvePercentileStrip(IReadOnlyList<CommunityLeaderboardCard> cards)
    {
        foreach (var tier in CommunityTierOrder.Display)
        {
            var card = cards.FirstOrDefault(c => c.Tier == tier);
            if (card is null || card.BelowThreshold)
            {
                continue;
            }

            return card.Percentiles;
        }

        return new PercentileBands(0, 0, 0, 0);
    }

    private static IReadOnlyList<LeaderboardEntry> SampleEntries(GeographyTier tier)
    {
        var prefix = tier switch
        {
            GeographyTier.City => "city",
            GeographyTier.Region => "region",
            GeographyTier.Country => "country",
            _ => "world",
        };

        return new[]
        {
            new LeaderboardEntry(1, $"{prefix}-a1", 1_200_000, 3.4, RankMovement.Same, "ember-fox"),
            new LeaderboardEntry(2, $"{prefix}-b2", 980_000, 2.8, RankMovement.Up, "quiet-orbit"),
            new LeaderboardEntry(3, $"{prefix}-c3", 860_000, 2.1, RankMovement.Down, "glass-pine"),
        };
    }

    private static string SampleGeoLabel(GeographyTier tier) => tier switch
    {
        GeographyTier.City => "San Francisco",
        GeographyTier.Region => "California",
        GeographyTier.Country => "United States",
        _ => "Global",
    };

    private IReadOnlyList<PurposeSlice> BuildPurposeBreakdown()
    {
        var demo = new ClassifierSignals(
            FileExtensions: new[] { "swift", "ts" },
            Keywords: new[] { "refactor", "ui" },
            Model: "claude-3.5-sonnet",
            AppSurface: "editor");

        var primary = ModelPurposeClassifier.ClassifyPurpose(demo);
        return new[]
        {
            new PurposeSlice(ModelPurposeClassifier.CategoryRaw(primary.Category), 0.34),
            new PurposeSlice("logic", 0.28),
            new PurposeSlice("backend", 0.18),
            new PurposeSlice("writing", 0.12),
            new PurposeSlice("other", 0.08),
        };
    }

    private string BuildConsentPreview()
    {
        var c = Consent;
        return $"L1 {c.L1Analytics.Label()} · L2 {c.L2Rankings.Label()} · L3 {c.L3LookingGlass.Label()} · Location {c.LocationConsent.Label()}";
    }

    private void OnPropertyChanged([CallerMemberName] string? name = null) =>
        PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(name));
}