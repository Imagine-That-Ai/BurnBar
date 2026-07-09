import { describe, expect, it } from "vitest";
import { readFileSync } from "node:fs";
import { resolve } from "node:path";
import { canonicalizeCityKey, deriveGeoKeys } from "../lib/community/geoCityKey";

const goldens: Array<{
  name: string;
  cityName: string;
  countryCode: string;
  regionCode: string;
  expected: string;
}> = JSON.parse(
  readFileSync(resolve(__dirname, "../lib/community/city-key-goldens.json"), "utf-8"),
);

describe("city-key-goldens (cross-platform parity)", () => {
  for (const golden of goldens) {
    it(`${golden.name}: "${golden.cityName}" → ${golden.expected}`, () => {
      expect(canonicalizeCityKey(golden.cityName, golden.countryCode, golden.regionCode)).toBe(
        golden.expected,
      );
    });
  }
});

describe("deriveGeoKeys", () => {
  it("parses locale region before POSIX and Unicode extension subtags", () => {
    expect(deriveGeoKeys("Atlantic/Canary", "en_US_POSIX").countryCode).toBe("US");
    expect(deriveGeoKeys("Atlantic/Canary", "zh-Hant-TW").countryCode).toBe("TW");
    expect(deriveGeoKeys("Atlantic/Canary", "en-US-u-ca-gregory").countryCode).toBe("US");
    expect(deriveGeoKeys("Atlantic/Canary", "en-u-ca-gregory").countryCode).toBeUndefined();
  });
});
