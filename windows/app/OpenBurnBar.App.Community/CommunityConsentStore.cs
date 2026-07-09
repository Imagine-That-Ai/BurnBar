using System.Text.Json;
using System.Text.Json.Serialization;

namespace OpenBurnBar.App.Community;

/// <summary>
/// Local tri-state consent ladder persisted under %LOCALAPPDATA%\OpenBurnBar\community-consent.json.
/// Mirrors the shared IA; server callables remain authoritative for egress.
/// </summary>
public sealed class CommunityConsentStore
{
    private static readonly JsonSerializerOptions JsonOptions = new()
    {
        PropertyNamingPolicy = JsonNamingPolicy.CamelCase,
        WriteIndented = true,
        DefaultIgnoreCondition = JsonIgnoreCondition.WhenWritingNull,
    };

    private readonly string _path;
    private CommunityConsentState _state;

    public CommunityConsentStore(string? filePath = null)
    {
        _path = filePath ?? DefaultPath();
        _state = Load(_path);
    }

    public CommunityConsentState State => _state;

    public static string DefaultPath()
    {
        var root = Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData);
        return Path.Combine(root, "OpenBurnBar", "community-consent.json");
    }

    public void Save()
    {
        try
        {
            var dir = Path.GetDirectoryName(_path);
            if (!string.IsNullOrEmpty(dir))
            {
                Directory.CreateDirectory(dir);
            }

            var dto = CommunityConsentDto.FromState(_state with { UpdatedAt = DateTimeOffset.UtcNow });
            File.WriteAllText(_path, JsonSerializer.Serialize(dto, JsonOptions));
            _state = dto.ToState();
        }
        catch
        {
            // best-effort local mirror
        }
    }

    public void Replace(CommunityConsentState state)
    {
        _state = state;
        Save();
    }

    public static CommunityConsentState DefaultState() => new(
        L1Analytics: ConsentTriState.Unset,
        L2Rankings: ConsentTriState.Unset,
        L2Tiers: new CommunityTierConsent(),
        L3LookingGlass: ConsentTriState.Unset,
        LocationConsent: ConsentTriState.Unset,
        UpdatedAt: DateTimeOffset.MinValue);

    private static CommunityConsentState Load(string path)
    {
        try
        {
            if (!File.Exists(path))
            {
                return DefaultState();
            }

            var json = File.ReadAllText(path);
            var dto = JsonSerializer.Deserialize<CommunityConsentDto>(json, JsonOptions);
            return dto?.ToState() ?? DefaultState();
        }
        catch
        {
            return DefaultState();
        }
    }

    private sealed class CommunityConsentDto
    {
        public string L1Analytics { get; set; } = "unset";
        public string L2Rankings { get; set; } = "unset";
        public string L3LookingGlass { get; set; } = "unset";
        public string LocationConsent { get; set; } = "unset";
        public string? L2World { get; set; }
        public string? L2Country { get; set; }
        public string? L2Region { get; set; }
        public string? L2City { get; set; }
        public string? UpdatedAt { get; set; }

        public static CommunityConsentDto FromState(CommunityConsentState state) => new()
        {
            L1Analytics = state.L1Analytics.Raw(),
            L2Rankings = state.L2Rankings.Raw(),
            L3LookingGlass = state.L3LookingGlass.Raw(),
            LocationConsent = state.LocationConsent.Raw(),
            L2World = state.L2Tiers.World.Raw(),
            L2Country = state.L2Tiers.Country.Raw(),
            L2Region = state.L2Tiers.Region.Raw(),
            L2City = state.L2Tiers.City.Raw(),
            UpdatedAt = state.UpdatedAt.ToString("o"),
        };

        public CommunityConsentState ToState()
        {
            var tiers = new CommunityTierConsent(
                World: ConsentTriStateExtensions.Parse(L2World),
                Country: ConsentTriStateExtensions.Parse(L2Country),
                Region: ConsentTriStateExtensions.Parse(L2Region),
                City: ConsentTriStateExtensions.Parse(L2City));

            DateTimeOffset updated = DateTimeOffset.MinValue;
            if (!string.IsNullOrWhiteSpace(UpdatedAt))
            {
                _ = DateTimeOffset.TryParse(UpdatedAt, out updated);
            }

            return new CommunityConsentState(
                L1Analytics: ConsentTriStateExtensions.Parse(L1Analytics),
                L2Rankings: ConsentTriStateExtensions.Parse(L2Rankings),
                L2Tiers: tiers,
                L3LookingGlass: ConsentTriStateExtensions.Parse(L3LookingGlass),
                LocationConsent: ConsentTriStateExtensions.Parse(LocationConsent),
                UpdatedAt: updated);
        }
    }
}