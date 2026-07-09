package com.openburnbar.data.community

import java.text.Normalizer
import java.util.Locale
import java.util.regex.Pattern

/**
 * Ports [functions/src/community/geo.ts] city key canonicalization
 * (`asciiFold`, `slugifyCity`, `canonicalizeCityKey`).
 */
object CommunityCityKey {
    private val NON_SLUG = Pattern.compile("[^a-z0-9]+")
    private val EDGE_DASHES = Pattern.compile("^-+|-+$")

    /** Characters NFD does not reduce to ASCII — replaced before decomposition (ports geo.ts). */
    private val NON_DECOMPOSABLE: Map<Char, String> =
        mapOf(
            '\u00D8' to "O", '\u00F8' to "o",
            '\u0141' to "L", '\u0142' to "l",
            '\u00D0' to "D", '\u00F0' to "d",
            '\u00DE' to "T", '\u00FE' to "t",
            '\u00DF' to "ss",
            '\u0130' to "I", '\u0131' to "i",
            '\u0110' to "D", '\u0111' to "d",
            '\u014A' to "N", '\u014B' to "n",
            '\u017D' to "Z", '\u017E' to "z",
            '\u0160' to "S", '\u0161' to "s",
            '\u015A' to "S", '\u015B' to "s",
            '\u017B' to "Z", '\u017C' to "z",
            '\u0106' to "C", '\u0107' to "c",
            '\u010C' to "C", '\u010D' to "c",
            '\u0158' to "R", '\u0159' to "r",
            '\u016E' to "U", '\u016F' to "u",
            '\u0147' to "N", '\u0148' to "n",
            '\u010E' to "D", '\u010F' to "d",
            '\u0164' to "T", '\u0165' to "t",
        )

    fun asciiFold(input: String): String {
        val replaced = buildString(input.length) {
            for (ch in input) {
                append(NON_DECOMPOSABLE[ch] ?: ch)
            }
        }
        val normalized = Normalizer.normalize(replaced, Normalizer.Form.NFD)
        val sb = StringBuilder(normalized.length)
        for (ch in normalized) {
            if (Character.getType(ch) != Character.NON_SPACING_MARK.toInt()) {
                sb.append(ch)
            }
        }
        return sb.toString()
    }

    fun slugifyCity(cityName: String): String {
        var slug =
            NON_SLUG
                .matcher(asciiFold(cityName).lowercase(Locale.ROOT))
                .replaceAll("-")
        slug = EDGE_DASHES.matcher(slug).replaceAll("")
        if (slug.length > 40) {
            slug = slug.take(40).trimEnd('-')
        }
        return slug
    }

    fun canonicalizeCityKey(cityName: String, countryCode: String, regionCode: String): String {
        val cc = countryCode.trim().uppercase(Locale.ROOT)
        var rc = regionCode.trim().uppercase(Locale.ROOT)
        if (rc.startsWith("$cc-")) {
            rc = rc.substring(cc.length + 1)
        }
        return "$cc-$rc-${slugifyCity(cityName)}"
    }
}
