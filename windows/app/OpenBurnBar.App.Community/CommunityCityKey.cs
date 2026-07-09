using System.Globalization;
using System.Text;
using System.Text.RegularExpressions;

namespace OpenBurnBar.App.Community;

/// <summary>
/// Ports <c>functions/src/community/geo.ts</c> city key canonicalization (asciiFold, slugifyCity, canonicalizeCityKey).
/// </summary>
public static class CommunityCityKey
{
    private static readonly Regex CombiningMarks = new(@"[\u0300-\u036f]+", RegexOptions.Compiled);
    private static readonly Regex NonSlug = new(@"[^a-z0-9]+", RegexOptions.Compiled);
    private static readonly Regex EdgeDashes = new(@"^-+|-+$", RegexOptions.Compiled);

    /// <summary>Characters NFD does not reduce to ASCII — replaced before FormD (ports geo.ts).</summary>
    private static readonly Dictionary<char, string> NonDecomposable = new()
    {
        ['\u00D8'] = "O", ['\u00F8'] = "o",
        ['\u0141'] = "L", ['\u0142'] = "l",
        ['\u00D0'] = "D", ['\u00F0'] = "d",
        ['\u00DE'] = "T", ['\u00FE'] = "t",
        ['\u00DF'] = "ss",
        ['\u0130'] = "I", ['\u0131'] = "i",
        ['\u0110'] = "D", ['\u0111'] = "d",
        ['\u014A'] = "N", ['\u014B'] = "n",
        ['\u017D'] = "Z", ['\u017E'] = "z",
        ['\u0160'] = "S", ['\u0161'] = "s",
        ['\u015A'] = "S", ['\u015B'] = "s",
        ['\u017B'] = "Z", ['\u017C'] = "z",
        ['\u0106'] = "C", ['\u0107'] = "c",
        ['\u010C'] = "C", ['\u010D'] = "c",
        ['\u0158'] = "R", ['\u0159'] = "r",
        ['\u016E'] = "U", ['\u016F'] = "u",
        ['\u0147'] = "N", ['\u0148'] = "n",
        ['\u010E'] = "D", ['\u010F'] = "d",
        ['\u0164'] = "T", ['\u0165'] = "t",
    };

    public static string AsciiFold(string input)
    {
        var replaced = new StringBuilder(input.Length);
        foreach (var ch in input)
        {
            if (NonDecomposable.TryGetValue(ch, out var mapped))
            {
                replaced.Append(mapped);
            }
            else
            {
                replaced.Append(ch);
            }
        }

        return CombiningMarks.Replace(replaced.ToString().Normalize(NormalizationForm.FormD), "");
    }

    public static string SlugifyCity(string cityName)
    {
        var folded = AsciiFold(cityName).ToLowerInvariant();
        var slug = NonSlug.Replace(folded, "-");
        slug = EdgeDashes.Replace(slug, "");
        if (slug.Length > 40)
        {
            slug = slug[..40].TrimEnd('-');
        }

        return slug;
    }

    public static string CanonicalizeCityKey(string cityName, string countryCode, string regionCode)
    {
        var cc = countryCode.Trim().ToUpperInvariant();
        var rc = regionCode.Trim().ToUpperInvariant();
        if (rc.StartsWith($"{cc}-", StringComparison.Ordinal))
        {
            rc = rc[(cc.Length + 1)..];
        }

        return $"{cc}-{rc}-{SlugifyCity(cityName)}";
    }
}