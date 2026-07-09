import { readFileSync } from "node:fs";

import { expect } from "vitest";

import type { ClassifierSignals, PurposeCorrection } from "../../community/classifier.js";
import type { CommunityFirestore } from "../../community/firestoreTypes.js";
import { pathKeyedFirestore } from "../bola/callableBolaHarness.js";

type GoldenFixture = {
  name: string;
  signals: ClassifierSignals;
  expected?: string;
  minConfidence?: number;
  expectedFingerprint?: string;
  corrections?: PurposeCorrection[];
};

function isRecordValue(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

export function communityDb(store: Map<string, Record<string, unknown>>): CommunityFirestore {
  const db: CommunityFirestore = pathKeyedFirestore(store);
  return db;
}

export function requireRecord(value: unknown, context: string): Record<string, unknown> {
  expect(isRecordValue(value), context).toBe(true);
  if (!isRecordValue(value)) throw new Error(`${context} must be an object.`);
  return value;
}

export function requireStringField(value: Record<string, unknown>, key: string): string {
  const field = value[key];
  expect(typeof field, key).toBe("string");
  if (typeof field !== "string") throw new Error(`${key} must be a string.`);
  return field;
}

export function requireNumberField(value: Record<string, unknown>, key: string): number {
  const field = value[key];
  expect(typeof field, key).toBe("number");
  if (typeof field !== "number") throw new Error(`${key} must be a number.`);
  return field;
}

function isClassifierSignals(value: unknown): value is ClassifierSignals {
  return isRecordValue(value);
}

function isPurposeCorrectionArray(value: unknown): value is PurposeCorrection[] {
  return Array.isArray(value) && value.every(isRecordValue);
}

export function loadGoldenFixtures(goldensPath: string): GoldenFixture[] {
  const parsed: unknown = JSON.parse(readFileSync(goldensPath, "utf8"));
  if (!Array.isArray(parsed)) throw new Error("Classifier goldens must be an array.");
  return parsed.map((item) => {
    const row = requireRecord(item, "golden fixture");
    const name = requireStringField(row, "name");
    if (!isClassifierSignals(row.signals)) throw new Error(`Golden ${name} has invalid signals.`);
    const expected = row.expected;
    if (expected !== undefined && typeof expected !== "string") throw new Error(`Golden ${name} expected is invalid.`);
    const minConfidence = row.minConfidence;
    if (minConfidence !== undefined && typeof minConfidence !== "number") {
      throw new Error(`Golden ${name} minConfidence is invalid.`);
    }
    const expectedFingerprint = row.expectedFingerprint;
    if (expectedFingerprint !== undefined && typeof expectedFingerprint !== "string") {
      throw new Error(`Golden ${name} expectedFingerprint is invalid.`);
    }
    const corrections = row.corrections;
    if (corrections !== undefined && !isPurposeCorrectionArray(corrections)) {
      throw new Error(`Golden ${name} corrections are invalid.`);
    }
    return { name, signals: row.signals, expected, minConfidence, expectedFingerprint, corrections };
  });
}
