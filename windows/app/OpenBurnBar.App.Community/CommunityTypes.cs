namespace OpenBurnBar.App.Community;

public enum ConsentTriState
{
    Unset,
    Granted,
    Declined,
}

public enum GeographyTier
{
    City,
    Region,
    Country,
    World,
}

public enum CommunityTimeWindow
{
    Today,
    SevenDay,
    ThirtyDay,
    NinetyDay,
    All,
}

public enum RankMovement
{
    Up,
    Down,
    Same,
    New,
}

public sealed record CommunityTierConsent(
    ConsentTriState World = ConsentTriState.Unset,
    ConsentTriState Country = ConsentTriState.Unset,
    ConsentTriState Region = ConsentTriState.Unset,
    ConsentTriState City = ConsentTriState.Unset);

public sealed record CommunityConsentState(
    ConsentTriState L1Analytics,
    ConsentTriState L2Rankings,
    CommunityTierConsent L2Tiers,
    ConsentTriState L3LookingGlass,
    ConsentTriState LocationConsent,
    DateTimeOffset UpdatedAt,
    string? ManualCityInput = null);

public sealed record CommunityUsageTotal(long TotalTokens, double CostUsd);
public sealed record CommunityWindowTotals(
    CommunityUsageTotal Today,
    CommunityUsageTotal SevenDay,
    CommunityUsageTotal ThirtyDay,
    CommunityUsageTotal NinetyDay,
    CommunityUsageTotal AllTime);

public sealed record CommunityShareSnapshotDoc(
    CommunityWindowTotals Windows,
    IReadOnlyDictionary<string, double> ModelMix,
    IReadOnlyDictionary<string, double> PurposeMix);


public sealed record LeaderboardEntry(
    int Rank,
    string AnonId,
    long TotalTokens,
    double CostUsd,
    RankMovement Movement,
    string? Handle = null);

public sealed record PercentileBands(double P50, double P75, double P90, double P99);

public sealed record CommunityLeaderboardCard(
    GeographyTier Tier,
    string GeoLabel,
    string GeoConfidenceCopy,
    IReadOnlyList<LeaderboardEntry> Entries,
    PercentileBands Percentiles,
    int CohortSize,
    bool BelowThreshold,
    int KThreshold,
    int? YourRank,
    RankMovement? YourMovement);

public sealed record PurposeSlice(string Category, double Share);

public sealed record CommunityLiveData(
    CommunityShareSnapshotDoc? ShareSnapshot = null,
    IReadOnlyList<CommunityLeaderboardCard>? Leaderboards = null);

public static class CommunityTierOrder
{
    public static IReadOnlyList<GeographyTier> Display { get; } =
        new[] { GeographyTier.City, GeographyTier.Region, GeographyTier.Country, GeographyTier.World };
}

public static class ConsentTriStateExtensions
{
    public static string Raw(this ConsentTriState state) => state switch
    {
        ConsentTriState.Granted => "granted",
        ConsentTriState.Declined => "declined",
        _ => "unset",
    };

    public static ConsentTriState Parse(string? raw) => raw?.ToLowerInvariant() switch
    {
        "granted" => ConsentTriState.Granted,
        "declined" => ConsentTriState.Declined,
        _ => ConsentTriState.Unset,
    };

    public static bool IsActive(this ConsentTriState state) => state == ConsentTriState.Granted;

    public static ConsentTriState Cycle(this ConsentTriState state) => state switch
    {
        ConsentTriState.Unset => ConsentTriState.Granted,
        ConsentTriState.Granted => ConsentTriState.Declined,
        _ => ConsentTriState.Unset,
    };

    public static string Label(this ConsentTriState state) => state switch
    {
        ConsentTriState.Granted => "Granted",
        ConsentTriState.Declined => "Declined",
        _ => "Unset",
    };
}

public static class GeographyTierExtensions
{
    public static string DisplayName(this GeographyTier tier) => tier switch
    {
        GeographyTier.City => "City",
        GeographyTier.Region => "Region",
        GeographyTier.Country => "Country",
        _ => "World",
    };
}