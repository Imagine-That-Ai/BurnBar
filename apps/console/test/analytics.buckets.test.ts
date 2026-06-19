import { describe, expect, it } from "vitest";

import {
  bucketAmountUSD,
  bucketCount,
  bucketDurationMs,
  bucketDurationSeconds,
  bucketPercent,
  bucketSizeBytes,
} from "../lib/analytics/buckets";

/**
 * Bucket labels must be BYTE-IDENTICAL to AnalyticsBuckets.swift and the website.
 * These cases pin every label string and every boundary so a drift in any of the
 * three ports is caught here.
 */
describe("bucketDurationMs", () => {
  it("labels and boundaries", () => {
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
    expect(bucketDurationMs(1_000_000)).toBe(">30s");
  });
});

describe("bucketCount", () => {
  it("labels and boundaries", () => {
    expect(bucketCount(-3)).toBe("0");
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
  it("labels and boundaries", () => {
    expect(bucketAmountUSD(0)).toBe("0");
    expect(bucketAmountUSD(-5)).toBe("0");
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
  it("labels and boundaries", () => {
    expect(bucketPercent(0)).toBe("0-10");
    expect(bucketPercent(9.9)).toBe("0-10");
    expect(bucketPercent(10)).toBe("10-25");
    expect(bucketPercent(24.9)).toBe("10-25");
    expect(bucketPercent(25)).toBe("25-50");
    expect(bucketPercent(49.9)).toBe("25-50");
    expect(bucketPercent(50)).toBe("50-75");
    expect(bucketPercent(74.9)).toBe("50-75");
    expect(bucketPercent(75)).toBe("75-90");
    expect(bucketPercent(89.9)).toBe("75-90");
    expect(bucketPercent(90)).toBe("90-100");
    expect(bucketPercent(100)).toBe("90-100");
  });
});

describe("bucketSizeBytes", () => {
  it("labels and boundaries", () => {
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
  it("labels and boundaries", () => {
    expect(bucketDurationSeconds(0)).toBe("<5s");
    expect(bucketDurationSeconds(4.9)).toBe("<5s");
    expect(bucketDurationSeconds(5)).toBe("5-30s");
    expect(bucketDurationSeconds(29.9)).toBe("5-30s");
    expect(bucketDurationSeconds(30)).toBe("30s-2m");
    expect(bucketDurationSeconds(119)).toBe("30s-2m");
    expect(bucketDurationSeconds(120)).toBe("2-10m");
    expect(bucketDurationSeconds(599)).toBe("2-10m");
    expect(bucketDurationSeconds(600)).toBe("10-60m");
    expect(bucketDurationSeconds(3_599)).toBe("10-60m");
    expect(bucketDurationSeconds(3_600)).toBe(">60m");
  });
});
