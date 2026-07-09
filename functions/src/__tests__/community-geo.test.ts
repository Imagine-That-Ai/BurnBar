import { describe, expect, it } from "vitest";
import { deriveGeoKeys, populateGeoKeys, canonicalizeCityKey, normalizeGeoKey } from "../community/geo.js";

describe("deriveGeoKeys", () => {
  it("resolves US-CA from America/Los_Angeles + en-US", () => {
    const keys = deriveGeoKeys("America/Los_Angeles", "en-US");
    expect(keys.countryCode).toBe("US");
    expect(keys.regionKey).toBe("US-CA");
    expect(keys.cityKey).toBeUndefined();
  });

  it("resolves JP from Asia/Tokyo + ja-JP", () => {
    const keys = deriveGeoKeys("Asia/Tokyo", "ja-JP");
    expect(keys.countryCode).toBe("JP");
  });

  it("prefers timezone country over locale country for travelers", () => {
    // User in London with US locale
    const keys = deriveGeoKeys("Europe/London", "en-US");
    expect(keys.countryCode).toBe("GB");
  });

  it("falls back to locale when timezone not in map", () => {
    const keys = deriveGeoKeys("America/Guatemala", "es-GT");
    expect(keys.countryCode).toBe("GT");
  });

  it("parses locale regions before POSIX and Unicode extension subtags", () => {
    expect(deriveGeoKeys("Atlantic/Canary", "en_US_POSIX").countryCode).toBe("US");
    expect(deriveGeoKeys("Atlantic/Canary", "zh-Hant-TW").countryCode).toBe("TW");
    expect(deriveGeoKeys("Atlantic/Canary", "en-US-u-ca-gregory").countryCode).toBe("US");
    expect(deriveGeoKeys("Atlantic/Canary", "en-u-ca-gregory").countryCode).toBeUndefined();
  });

  it("returns undefined country for unknown timezone and locale without region", () => {
    const keys = deriveGeoKeys("Atlantic/Canary", "es");
    expect(keys.countryCode).toBeUndefined();
  });

  it("cityKey is always undefined from locale/timezone", () => {
    const keys = deriveGeoKeys("America/New_York", "en-US");
    expect(keys.cityKey).toBeUndefined();
  });
});

describe("populateGeoKeys", () => {
  it("sets countryCode when country tier consented", () => {
    const profile = populateGeoKeys(
      {},
      { countryCode: "US", regionKey: "US-CA" },
      {
        country: true,
        region: false,
        city: false,
      },
    );
    expect(profile.countryCode).toBe("US");
    expect(profile.regionKey).toBeUndefined();
  });

  it("sets regionKey when region tier consented", () => {
    const profile = populateGeoKeys(
      {},
      { countryCode: "US", regionKey: "US-CA" },
      {
        country: true,
        region: true,
        city: false,
      },
    );
    expect(profile.countryCode).toBe("US");
    expect(profile.regionKey).toBe("US-CA");
  });

  it("omits keys when tier not consented", () => {
    const profile = populateGeoKeys(
      {},
      { countryCode: "US", regionKey: "US-CA" },
      {
        country: false,
        region: false,
        city: false,
      },
    );
    expect(profile.countryCode).toBeUndefined();
    expect(profile.regionKey).toBeUndefined();
  });
});

describe("canonicalizeCityKey", () => {
  it("produces canonical key for San Francisco", () => {
    expect(canonicalizeCityKey("San Francisco", "US", "CA")).toBe("US-CA-san-francisco");
  });

  it("ASCII-folds diacritics: München → munchen", () => {
    expect(canonicalizeCityKey("München", "DE", "BY")).toBe("DE-BY-munchen");
  });

  it("ASCII-folds diacritics: São Paulo → sao-paulo", () => {
    expect(canonicalizeCityKey("São Paulo", "BR", "SP")).toBe("BR-SP-sao-paulo");
  });

  it("replaces non-alphanumeric runs with single hyphen", () => {
    expect(canonicalizeCityKey("New York City", "US", "NY")).toBe("US-NY-new-york-city");
  });

  it("strips commas from city names", () => {
    expect(canonicalizeCityKey("San Francisco, CA", "US", "CA")).toBe("US-CA-san-francisco-ca");
  });

  it("truncates to 40 chars", () => {
    const long = "A".repeat(60);
    const key = canonicalizeCityKey(long, "US", "CA");
    expect(key.length).toBeLessThanOrEqual(40 + 6); // "US-CA-" prefix + 40-char slug
    expect(key.startsWith("US-CA-")).toBe(true);
  });

  it("is doc-ID-safe: no slash, space, or underscore", () => {
    const key = canonicalizeCityKey("St. John's", "CA", "NL");
    expect(key).not.toMatch(/[/\s_]/);
    expect(key).toBe("CA-NL-st-john-s");
  });

  it("cross-platform determinism: same input always same output", () => {
    const a = canonicalizeCityKey("Zürich", "CH", "ZH");
    const b = canonicalizeCityKey("Zürich", "CH", "ZH");
    expect(a).toBe(b);
    expect(a).toBe("CH-ZH-zurich");
  });

  it("strips prefixed country from regionCode (US-CA → CA)", () => {
    expect(canonicalizeCityKey("Oakland", "US", "US-CA")).toBe("US-CA-oakland");
    expect(canonicalizeCityKey("Oakland", "US", "CA")).toBe("US-CA-oakland");
  });

  it("trims trailing hyphen after slug truncation at 40 chars", () => {
    const slug = "a".repeat(40);
    const key = canonicalizeCityKey(slug, "US", "CA");
    expect(key).toBe("US-CA-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa");
    expect(key.endsWith("-")).toBe(false);
  });
});

describe("normalizeGeoKey", () => {
  it("preserves case for well-formed keys", () => {
    expect(normalizeGeoKey("US")).toBe("US");
    expect(normalizeGeoKey("US-CA")).toBe("US-CA");
    expect(normalizeGeoKey("US-CA-san-francisco")).toBe("US-CA-san-francisco");
  });

  it("strips slashes + dots (path injection defense)", () => {
    // Allowlist strips dots, slashes, and any non-[a-zA-Z0-9-] char.
    expect(normalizeGeoKey("US/../../etc")).toBe("USetc");
    expect(normalizeGeoKey("US/CA")).toBe("USCA");
  });

  it("strips underscores (delimiter collision)", () => {
    expect(normalizeGeoKey("US_CA")).toBe("USCA");
  });

  it("strips whitespace", () => {
    expect(normalizeGeoKey(" US CA ")).toBe("USCA");
  });

  it("strips control characters", () => {
    expect(normalizeGeoKey("US\x00\x1fCA")).toBe("USCA");
  });

  it("ASCII-folds diacritics but preserves case", () => {
    expect(normalizeGeoKey("São")).toBe("Sao");
    expect(normalizeGeoKey("München")).toBe("Munchen");
  });

  it("collapses consecutive hyphens", () => {
    expect(normalizeGeoKey("US--CA")).toBe("US-CA");
  });

  it("strips leading/trailing hyphens", () => {
    expect(normalizeGeoKey("-US-CA-")).toBe("US-CA");
  });

  it("returns undefined for empty/whitespace input", () => {
    expect(normalizeGeoKey("")).toBeUndefined();
    expect(normalizeGeoKey("   ")).toBeUndefined();
    expect(normalizeGeoKey(undefined)).toBeUndefined();
  });

  it("is idempotent: normalize(normalize(x)) === normalize(x)", () => {
    const key = "US-CA-san-francisco";
    expect(normalizeGeoKey(normalizeGeoKey(key))).toBe(normalizeGeoKey(key));
  });
});

import { readFileSync } from "node:fs";
import { resolve } from "node:path";

const goldens: Array<{
  name: string;
  cityName: string;
  countryCode: string;
  regionCode: string;
  expected: string;
}> = JSON.parse(readFileSync(resolve(__dirname, "../../../tests/fixtures/city-key-goldens.json"), "utf-8"));

describe("city-key-goldens (cross-platform parity)", () => {
  for (const golden of goldens) {
    it(`${golden.name}: "${golden.cityName}" → ${golden.expected}`, () => {
      const result = canonicalizeCityKey(golden.cityName, golden.countryCode, golden.regionCode);
      expect(result).toBe(golden.expected);
    });
  }
});
