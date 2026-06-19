/**
 * Proves the backend bucket boundaries are BYTE-IDENTICAL to the canonical
 * boundaries shared with macOS (`AnalyticsBuckets.swift`), the website
 * (`buckets.ts`), and `docs/analytics/event-taxonomy.md`. Boundary cases hit
 * each edge so a one-off drift fails loudly.
 */
import { describe, expect, it } from "vitest";

import {
  bucketDurationMs,
  bucketCount,
  bucketAmountUSD,
  bucketPercent,
  bucketSizeBytes,
  bucketDurationSeconds,
} from "../analytics/buckets.js";

describe("bucketDurationMs", () => {
  it("maps each band", () => {
    expect(bucketDurationMs(0)).toBe("<100ms");
    expect(bucketDurationMs(99)).toBe("<100ms");
    expect(bucketDurationMs(100)).toBe("100-500ms");
    expect(bucketDurationMs(499)).toBe("100-500ms");
    expect(bucketDurationMs(500)).toBe("500ms-1s");
    expect(bucketDurationMs(999)).toBe("500ms-1s");
    expect(bucketDurationMs(1_000)).toBe("1-3s");
    expect(bucketDurationMs(2_999)).toBe("1-3s");
    expect(bucketDurationMs(3_000)).toBe("3-10s");
    expect(bucketDurationMs(9_999)).toBe("3-10s");
    expect(bucketDurationMs(10_000)).toBe("10-30s");
    expect(bucketDurationMs(29_999)).toBe("10-30s");
    expect(bucketDurationMs(30_000)).toBe(">30s");
  });
});

describe("bucketCount", () => {
  it("clamps and maps each band", () => {
    expect(bucketCount(-5)).toBe("0");
    expect(bucketCount(0)).toBe("0");
    expect(bucketCount(1)).toBe("1");
    expect(bucketCount(2)).toBe("2-5");
    expect(bucketCount(5)).toBe("2-5");
    expect(bucketCount(6)).toBe("6-20");
    expect(bucketCount(20)).toBe("6-20");
    expect(bucketCount(21)).toBe("21-100");
    expect(bucketCount(100)).toBe("21-100");
    expect(bucketCount(101)).toBe("101-500");
    expect(bucketCount(500)).toBe("101-500");
    expect(bucketCount(501)).toBe(">500");
  });
});

describe("bucketAmountUSD", () => {
  it("maps each band", () => {
    expect(bucketAmountUSD(-1)).toBe("0");
    expect(bucketAmountUSD(0)).toBe("0");
    expect(bucketAmountUSD(0.5)).toBe("<1");
    expect(bucketAmountUSD(1)).toBe("1-10");
    expect(bucketAmountUSD(9.99)).toBe("1-10");
    expect(bucketAmountUSD(10)).toBe("10-50");
    expect(bucketAmountUSD(49.99)).toBe("10-50");
    expect(bucketAmountUSD(50)).toBe("50-100");
    expect(bucketAmountUSD(99.99)).toBe("50-100");
    expect(bucketAmountUSD(100)).toBe("100-500");
    expect(bucketAmountUSD(499.99)).toBe("100-500");
    expect(bucketAmountUSD(500)).toBe(">500");
  });
});

describe("bucketPercent", () => {
  it("maps each band", () => {
    expect(bucketPercent(0)).toBe("0-10");
    expect(bucketPercent(9.99)).toBe("0-10");
    expect(bucketPercent(10)).toBe("10-25");
    expect(bucketPercent(24.99)).toBe("10-25");
    expect(bucketPercent(25)).toBe("25-50");
    expect(bucketPercent(49.99)).toBe("25-50");
    expect(bucketPercent(50)).toBe("50-75");
    expect(bucketPercent(74.99)).toBe("50-75");
    expect(bucketPercent(75)).toBe("75-90");
    expect(bucketPercent(89.99)).toBe("75-90");
    expect(bucketPercent(90)).toBe("90-100");
    expect(bucketPercent(100)).toBe("90-100");
  });
});

describe("bucketSizeBytes", () => {
  it("maps each band", () => {
    expect(bucketSizeBytes(0)).toBe("<1KB");
    expect(bucketSizeBytes(999)).toBe("<1KB");
    expect(bucketSizeBytes(1_000)).toBe("1-100KB");
    expect(bucketSizeBytes(99_999)).toBe("1-100KB");
    expect(bucketSizeBytes(100_000)).toBe("100KB-1MB");
    expect(bucketSizeBytes(999_999)).toBe("100KB-1MB");
    expect(bucketSizeBytes(1_000_000)).toBe("1-10MB");
    expect(bucketSizeBytes(9_999_999)).toBe("1-10MB");
    expect(bucketSizeBytes(10_000_000)).toBe("10-100MB");
    expect(bucketSizeBytes(99_999_999)).toBe("10-100MB");
    expect(bucketSizeBytes(100_000_000)).toBe(">100MB");
  });
});

describe("bucketDurationSeconds", () => {
  it("maps each band", () => {
    expect(bucketDurationSeconds(0)).toBe("<5s");
    expect(bucketDurationSeconds(4.99)).toBe("<5s");
    expect(bucketDurationSeconds(5)).toBe("5-30s");
    expect(bucketDurationSeconds(29.99)).toBe("5-30s");
    expect(bucketDurationSeconds(30)).toBe("30s-2m");
    expect(bucketDurationSeconds(119.99)).toBe("30s-2m");
    expect(bucketDurationSeconds(120)).toBe("2-10m");
    expect(bucketDurationSeconds(599.99)).toBe("2-10m");
    expect(bucketDurationSeconds(600)).toBe("10-60m");
    expect(bucketDurationSeconds(3_599.99)).toBe("10-60m");
    expect(bucketDurationSeconds(3_600)).toBe(">60m");
  });
});
