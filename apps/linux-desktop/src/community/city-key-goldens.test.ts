import { describe, expect, it } from "vitest";
import { readFileSync } from "node:fs";
import { resolve, dirname } from "node:path";
import { fileURLToPath } from "node:url";
import { canonicalizeCityKey } from "./geoCityKey";

const __dirname2 = dirname(fileURLToPath(import.meta.url));
const goldens: Array<{
  name: string;
  cityName: string;
  countryCode: string;
  regionCode: string;
  expected: string;
}> = JSON.parse(readFileSync(resolve(__dirname2, "city-key-goldens.json"), "utf-8"));

describe("city-key-goldens (cross-platform parity)", () => {
  for (const golden of goldens) {
    it(`${golden.name}: "${golden.cityName}" → ${golden.expected}`, () => {
      expect(canonicalizeCityKey(golden.cityName, golden.countryCode, golden.regionCode)).toBe(
        golden.expected,
      );
    });
  }

  it("truncation-trailing-hyphen: slug does not end with hyphen", () => {
    const slug = canonicalizeCityKey(
      "alpha-beta-gamma-delta-epsilon-zeta-eta-theta-iota-kappa",
      "US",
      "CA",
    );
    expect(slug).toBe("US-CA-alpha-beta-gamma-delta-epsilon-zeta-eta");
    expect(slug.endsWith("-")).toBe(false);
  });

  it("prefixed-region-code: US-CA with country US", () => {
    expect(canonicalizeCityKey("San Francisco", "US", "US-CA")).toBe("US-CA-san-francisco");
  });
});
