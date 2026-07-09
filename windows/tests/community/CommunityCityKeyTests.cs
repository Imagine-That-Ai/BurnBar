using OpenBurnBar.App.Community;
using Xunit;

namespace OpenBurnBar.App.Community.Tests;

public sealed class CommunityCityKeyTests
{
    private record Golden(string Name, string CityName, string CountryCode, string RegionCode, string Expected);

    // Mirrors tests/fixtures/city-key-goldens.json — every platform must produce
    // byte-identical output for all 15 entries, including non-decomposable chars.
    private static readonly Golden[] Goldens =
    [
        new("ascii-clean", "San Francisco", "US", "CA", "US-CA-san-francisco"),
        new("decomposable-umlaut", "München", "DE", "BY", "DE-BY-munchen"),
        new("decomposable-tilde", "São Paulo", "BR", "SP", "BR-SP-sao-paulo"),
        new("decomposable-caron", "České Budějovice", "CZ", "JC", "CZ-JC-ceske-budejovice"),
        new("non-decomposable-oslash", "Tromsø", "NO", "19", "NO-19-tromso"),
        new("non-decomposable-l-slash", "Łódź", "PL", "LD", "PL-LD-lodz"),
        new("non-decomposable-dotted-i", "İstanbul", "TR", "34", "TR-34-istanbul"),
        new("non-decomposable-eth", "Reykjavík", "IS", "1", "IS-1-reykjavik"),
        new("non-decomposable-thorn", "Þorlákshöfn", "IS", "23", "IS-23-torlakshofn"),
        new("eszett", "Straße", "DE", "BY", "DE-BY-strasse"),
        new("non-decomposable-d-stroke", "Hà Nội", "VN", "HN", "VN-HN-ha-noi"),
        new("cjk-japanese-empty-slug", "東京", "JP", "13", "JP-13-"),
        new("doc-id-unsafe-chars", "St. John's / Québec", "CA", "QC", "CA-QC-st-john-s-quebec"),
        new("hyphenated-name", "Winston-Salem", "US", "NC", "US-NC-winston-salem"),
        new("long-name-truncation", "Llanfairpwllgwyngyllgogerychwyrndrobwllllantysiliogogogoch", "GB", "WLS", "GB-WLS-llanfairpwllgwyngyllgogerychwyrndrobwlll"),
    ];

    [Theory]
    [MemberData(nameof(GoldenData))]
    public void CanonicalizeCityKey_AllGoldens(string name, string cityName, string countryCode, string regionCode, string expected)
    {
        Assert.Equal(expected, CommunityCityKey.CanonicalizeCityKey(cityName, countryCode, regionCode));
    }

    public static IEnumerable<object[]> GoldenData() =>
        Goldens.Select(g => new object[] { g.Name, g.CityName, g.CountryCode, g.RegionCode, g.Expected });

    [Fact]
    public void SlugifyCity_TruncatesTo40()
    {
        var longName = new string('a', 50);
        Assert.Equal(40, CommunityCityKey.SlugifyCity(longName).Length);
    }
}
