import { describe, expect, it } from "vitest";

import { parseProviderAccountDoc, parseUsageEventDoc } from "../guards.js";

/**
 * Characterization tests pinning the CURRENT observable behavior of
 * parseProviderAccountDoc and parseUsageEventDoc prior to refactoring.
 * These assert exact return values for representative valid/invalid inputs.
 */

describe("parseProviderAccountDoc (characterization)", () => {
  it("returns a fully-populated doc for a valid record with all optional fields", () => {
    const raw = {
      id: "acct-1",
      providerID: "openai",
      label: "My OpenAI",
      status: "connected",
      credentialKind: "token",
      storageScope: "cloud_refreshable",
      redactedLabel: "My•••AI",
      isDefault: true,
      sortKey: 3,
      schemaVersion: 2,
      createdAt: "2026-01-01T00:00:00.000Z",
      updatedAt: "2026-01-02T00:00:00.000Z",
      identityHint: "alberto",
      sourceDeviceID: "device-7",
      linkedSwitcherProfileID: "profile-9",
      lastValidatedAt: "2026-01-03T00:00:00.000Z",
      lastRefreshAt: "2026-01-04T00:00:00.000Z",
      lastErrorCode: "AUTH_EXPIRED",
      endpointProfileID: "endpoint-2",
      region: "global",
      tokenPlanTier: "pro",
      tokenPlanBillingCycle: "annual",
      authMethodID: "method-5",
    };

    expect(parseProviderAccountDoc(raw)).toEqual({
      id: "acct-1",
      providerID: "openai",
      label: "My OpenAI",
      status: "connected",
      credentialKind: "token",
      storageScope: "cloud_refreshable",
      redactedLabel: "My•••AI",
      isDefault: true,
      sortKey: 3,
      schemaVersion: 2,
      createdAt: "2026-01-01T00:00:00.000Z",
      updatedAt: "2026-01-02T00:00:00.000Z",
      identityHint: "alberto",
      sourceDeviceID: "device-7",
      linkedSwitcherProfileID: "profile-9",
      lastValidatedAt: "2026-01-03T00:00:00.000Z",
      lastRefreshAt: "2026-01-04T00:00:00.000Z",
      lastErrorCode: "AUTH_EXPIRED",
      endpointProfileID: "endpoint-2",
      region: "global",
      tokenPlanTier: "pro",
      tokenPlanBillingCycle: "annual",
      authMethodID: "method-5",
    });
  });

  it("returns a doc with optional fields undefined for a minimal valid record with invalid enum-ish extras", () => {
    const raw = {
      id: "acct-2",
      providerID: "claude-code",
      label: "Min",
      status: "disconnected",
      credentialKind: "session",
      storageScope: "local_only",
      redactedLabel: "M•n",
      isDefault: false,
      sortKey: 0,
      schemaVersion: 1,
      createdAt: "2026-02-01T00:00:00.000Z",
      updatedAt: "2026-02-02T00:00:00.000Z",
      // invalid enum values must coerce to undefined, not pass through
      region: "us",
      tokenPlanTier: "ultra",
      tokenPlanBillingCycle: "weekly",
      identityHint: 42,
    };

    expect(parseProviderAccountDoc(raw)).toEqual({
      id: "acct-2",
      providerID: "claude-code",
      label: "Min",
      status: "disconnected",
      credentialKind: "session",
      storageScope: "local_only",
      redactedLabel: "M•n",
      isDefault: false,
      sortKey: 0,
      schemaVersion: 1,
      createdAt: "2026-02-01T00:00:00.000Z",
      updatedAt: "2026-02-02T00:00:00.000Z",
      identityHint: undefined,
      sourceDeviceID: undefined,
      linkedSwitcherProfileID: undefined,
      lastValidatedAt: undefined,
      lastRefreshAt: undefined,
      lastErrorCode: undefined,
      endpointProfileID: undefined,
      region: undefined,
      tokenPlanTier: undefined,
      tokenPlanBillingCycle: undefined,
      authMethodID: undefined,
    });
  });

  it("normalizes legacy Firestore Timestamp date fields to ISO strings", () => {
    const timestamp = (iso: string) => ({
      toDate: () => new Date(iso),
    });
    const raw = {
      id: "minimax_default",
      providerID: "minimax",
      label: "MiniMax",
      status: "connected",
      credentialKind: "bearer",
      storageScope: "cloud_refreshable",
      redactedLabel: "minimax_***",
      isDefault: true,
      sortKey: 0,
      schemaVersion: 1,
      createdAt: timestamp("2026-05-28T11:27:54.279Z"),
      updatedAt: timestamp("2026-05-30T22:20:10.235Z"),
      lastValidatedAt: timestamp("2026-05-07T04:39:32.412Z"),
      lastRefreshAt: timestamp("2026-06-18T16:25:03.517Z"),
    };

    expect(parseProviderAccountDoc(raw)).toMatchObject({
      id: "minimax_default",
      createdAt: "2026-05-28T11:27:54.279Z",
      updatedAt: "2026-05-30T22:20:10.235Z",
      lastValidatedAt: "2026-05-07T04:39:32.412Z",
      lastRefreshAt: "2026-06-18T16:25:03.517Z",
    });
  });

  it("returns undefined for a non-record input", () => {
    expect(parseProviderAccountDoc(null)).toBeUndefined();
    expect(parseProviderAccountDoc("nope")).toBeUndefined();
    expect(parseProviderAccountDoc([1, 2, 3])).toBeUndefined();
  });

  it("returns undefined when a required field is missing or wrong-typed", () => {
    const base = {
      id: "acct-3",
      providerID: "openai",
      label: "X",
      status: "connected",
      credentialKind: "token",
      storageScope: "cloud_refreshable",
      redactedLabel: "X",
      isDefault: true,
      sortKey: 1,
      schemaVersion: 1,
      createdAt: "2026-01-01T00:00:00.000Z",
      updatedAt: "2026-01-01T00:00:00.000Z",
    };
    expect(parseProviderAccountDoc({ ...base, status: "bogus" })).toBeUndefined();
    expect(parseProviderAccountDoc({ ...base, credentialKind: "nope" })).toBeUndefined();
    expect(parseProviderAccountDoc({ ...base, storageScope: "nope" })).toBeUndefined();
    expect(parseProviderAccountDoc({ ...base, isDefault: "yes" })).toBeUndefined();
    expect(parseProviderAccountDoc({ ...base, sortKey: "3" })).toBeUndefined();
    expect(parseProviderAccountDoc({ ...base, createdAt: { notATimestamp: true } })).toBeUndefined();
    expect(parseProviderAccountDoc({ ...base, updatedAt: { notATimestamp: true } })).toBeUndefined();
  });
});

describe("parseUsageEventDoc (characterization)", () => {
  it("builds a full doc and synthesizes recordedAt from explicit recordedAt", () => {
    const raw = {
      provider: "openai",
      recordedAt: "2026-03-01T00:00:00.000Z",
      schemaVersion: 4,
      providerID: "openai",
      providerAccountID: "acct-9",
      providerAccountLabel: "Acct 9",
      providerAccountSource: "server_private",
      model: "gpt-x",
      sessionId: "sess-1",
      deviceId: "dev-1",
      sourceDeviceId: "dev-src",
      inputTokens: 10,
      outputTokens: 20,
      cacheCreationTokens: 1,
      cacheReadTokens: 2,
      reasoningTokens: 3,
      totalTokens: 36,
      costUsd: 0.5,
      cost: 0.4,
      provenanceConfidence: "high",
      timestamp: "ts-raw",
      startTime: "start-raw",
      endTime: "end-raw",
      createdAt: "created-raw",
      updatedAt: "updated-raw",
    };

    expect(parseUsageEventDoc(raw)).toEqual({
      provider: "openai",
      recordedAt: "2026-03-01T00:00:00.000Z",
      schemaVersion: 4,
      providerID: "openai",
      providerAccountID: "acct-9",
      providerAccountLabel: "Acct 9",
      providerAccountSource: "server_private",
      model: "gpt-x",
      sessionId: "sess-1",
      deviceId: "dev-1",
      sourceDeviceId: "dev-src",
      inputTokens: 10,
      outputTokens: 20,
      cacheCreationTokens: 1,
      cacheReadTokens: 2,
      reasoningTokens: 3,
      totalTokens: 36,
      costUsd: 0.5,
      cost: 0.4,
      provenanceConfidence: "high",
      timestamp: "ts-raw",
      startTime: "start-raw",
      endTime: "end-raw",
      createdAt: "created-raw",
      updatedAt: "updated-raw",
    });
  });

  it("defaults schemaVersion to 1 and synthesizes recordedAt from timestamp when recordedAt absent", () => {
    const raw = {
      provider: "claude-code",
      timestamp: "2026-04-01T12:00:00.000Z",
    };

    expect(parseUsageEventDoc(raw)).toEqual({
      provider: "claude-code",
      recordedAt: new Date("2026-04-01T12:00:00.000Z").toISOString(),
      schemaVersion: 1,
      timestamp: "2026-04-01T12:00:00.000Z",
    });
  });

  it("returns undefined when provider is invalid", () => {
    expect(parseUsageEventDoc({ provider: "not-a-provider", recordedAt: "2026-01-01T00:00:00.000Z" })).toBeUndefined();
  });

  it("returns undefined when no recordedAt can be synthesized", () => {
    expect(parseUsageEventDoc({ provider: "openai", schemaVersion: 2 })).toBeUndefined();
  });

  it("returns undefined for a non-record input", () => {
    expect(parseUsageEventDoc(null)).toBeUndefined();
    expect(parseUsageEventDoc(42)).toBeUndefined();
  });
});
