import Foundation

/// City key canonicalization — ports `functions/src/community/geo.ts` (`asciiFold`, `slugifyCity`, `canonicalizeCityKey`).
public enum CommunityCityGeo {
    /// Characters NFD does not reduce to ASCII — replaced before decomposition (ports `geo.ts`).
    private static let nonDecomposable: [Character: String] = [
        "\u{00D8}": "O", "\u{00F8}": "o",
        "\u{0141}": "L", "\u{0142}": "l",
        "\u{00D0}": "D", "\u{00F0}": "d",
        "\u{00DE}": "T", "\u{00FE}": "t",
        "\u{00DF}": "ss",
        "\u{0130}": "I", "\u{0131}": "i",
        "\u{0110}": "D", "\u{0111}": "d",
        "\u{014A}": "N", "\u{014B}": "n",
        "\u{017D}": "Z", "\u{017E}": "z",
        "\u{0160}": "S", "\u{0161}": "s",
        "\u{015A}": "S", "\u{015B}": "s",
        "\u{017B}": "Z", "\u{017C}": "z",
        "\u{0106}": "C", "\u{0107}": "c",
        "\u{010C}": "C", "\u{010D}": "c",
        "\u{0158}": "R", "\u{0159}": "r",
        "\u{016E}": "U", "\u{016F}": "u",
        "\u{0147}": "N", "\u{0148}": "n",
        "\u{010E}": "D", "\u{010F}": "d",
        "\u{0164}": "T", "\u{0165}": "t"
    ]

    private static let combiningMarks = CharacterSet(charactersIn: "\u{0300}"..."\u{036F}")

    /// Non-decomposable replacement, then NFD + strip combining marks (U+0300–U+036F).
    public static func asciiFold(_ input: String) -> String {
        var replaced = ""
        replaced.reserveCapacity(input.count)
        for ch in input {
            if let mapped = nonDecomposable[ch] {
                replaced.append(contentsOf: mapped)
            } else {
                replaced.append(ch)
            }
        }
        let nfd = (replaced as NSString).decomposedStringWithCanonicalMapping
        return String(nfd.unicodeScalars.filter { !combiningMarks.contains($0) })
    }

    /// Slugify: fold → lowercase → `[^a-z0-9]+` → `-` → trim `-` → max 40 chars → trim trailing `-`.
    public static func slugifyCity(_ cityName: String) -> String {
        let folded = asciiFold(cityName).lowercased()
        var slug = ""
        var lastHyphen = false
        for scalar in folded.unicodeScalars {
            if (scalar >= "a" && scalar <= "z") || (scalar >= "0" && scalar <= "9") {
                slug.unicodeScalars.append(scalar)
                lastHyphen = false
            } else if !lastHyphen {
                slug.append("-")
                lastHyphen = true
            }
        }
        while slug.hasPrefix("-") { slug.removeFirst() }
        while slug.hasSuffix("-") { slug.removeLast() }
        if slug.count > 40 {
            slug = String(slug.prefix(40))
            while slug.hasSuffix("-") { slug.removeLast() }
        }
        return slug
    }

    /// Canonical city tier key: `{countryCode}-{regionCode}-{citySlug}`.
    public static func canonicalizeCityKey(
        cityName: String,
        countryCode: String,
        regionCode: String
    ) -> String {
        let country = countryCode.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        var region = regionCode.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        let prefix = "\(country)-"
        if region.hasPrefix(prefix) {
            region.removeFirst(prefix.count)
        }
        let slug = slugifyCity(cityName)
        return "\(country)-\(region)-\(slug)"
    }

    /// Profile region key: `{countryCode}-{regionCode}` (ISO subdivision without country prefix in the middle segment).
    public static func regionKey(countryCode: String, regionCode: String) -> String {
        let country = countryCode.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        let region = regionCode.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        return "\(country)-\(region)"
    }
}
