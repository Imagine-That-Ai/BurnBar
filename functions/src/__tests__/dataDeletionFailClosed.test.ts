/**
 * B-SEC-3 fail-closed: deleteDomainData refuses (propagates the error) when its
 * REQUIRED pre-delete audit intent cannot be persisted. A domain deletion is an
 * irreversible privacy operation, so a server must never delete data while
 * silently dropping the audit record (codex-gpt-5 FINDING-006).
 */
import { describe, expect, it, vi, beforeEach } from "vitest";

// Silence firebase-functions logger output during the test run.
vi.mock("firebase-functions/logger", () => ({
  info: vi.fn(),
  error: vi.fn(),
  warn: vi.fn(),
  debug: vi.fn(),
}));

// App Check / ownership are enforced via env; disable for the in-process call.
process.env.ENFORCE_APP_CHECK = "false";

// Empty Firestore: recursiveDelete is a no-op and collection count returns zero.
const emptyCollection = {
  count: () => ({ get: async () => ({ data: () => ({ count: 0 }) }) }),
};
vi.mock("../adminRuntime.js", () => ({
  db: {
    collection: () => emptyCollection,
    recursiveDelete: vi.fn(async () => undefined),
  },
  auth: {},
}));

// Empty Storage: no objects to enumerate.
vi.mock("firebase-admin/storage", () => ({
  getStorage: () => ({ bucket: () => ({ getFiles: async () => [[]], deleteFiles: vi.fn() }) }),
}));

// The fail-closed audit intent rejects, simulating a Firestore append failure.
const { appendAuditEventRequired, appendAuditEvent } = vi.hoisted(() => ({
  appendAuditEventRequired: vi.fn(async () => {
    throw new Error("audit intent append failed");
  }),
  appendAuditEvent: vi.fn(async () => undefined),
}));
vi.mock("../callables/auditLog.js", () => ({
  appendAuditEventRequired,
  appendAuditEvent,
  auditActorLabel: () => "user",
  AUDIT_ACTIONS: {
    domainDeleteIntent: "data.delete.intent",
    domainDeleteComplete: "data.delete.complete",
  },
}));

import { deleteDomainData } from "../callables/dataDeletion.js";

function authedRequest() {
  return {
    auth: { uid: "u1", token: {} },
    app: { appId: "1:1234567890:ios:openburnbar-test" },
    rawRequest: { headers: {} },
    data: { domainId: "session_logs", confirm: true },
  };
}

describe("deleteDomainData — fail-closed on required audit intent", () => {
  beforeEach(() => {
    appendAuditEventRequired.mockClear();
    appendAuditEvent.mockClear();
  });

  it("propagates the error when the required audit intent fails", async () => {
    // @ts-expect-error reason: onCall harness exposes .run for tests
    await expect(deleteDomainData.run(authedRequest())).rejects.toThrow(/audit intent append failed/);
    expect(appendAuditEventRequired).toHaveBeenCalledTimes(1);
    expect(appendAuditEventRequired).toHaveBeenCalledWith(
      "u1",
      expect.objectContaining({ action: "data.delete.intent", domain: "session_logs" }),
    );
    // Completion audit must NOT be attempted because deletion never ran.
    expect(appendAuditEvent).not.toHaveBeenCalled();
  });
});
