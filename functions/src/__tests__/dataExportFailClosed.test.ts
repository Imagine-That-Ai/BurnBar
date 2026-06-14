/**
 * B-SEC-3 fail-closed: exportUserData refuses (propagates the error) when its
 * REQUIRED audit write fails. A data export is an irreversible disclosure, so a
 * server must never be able to disclose data while silently dropping the audit
 * record. This proves the export call site uses `appendAuditEventRequired`
 * (no try/catch) rather than the best-effort variant.
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

// Empty Firestore: every domain collection read returns no docs.
const emptyCollection = {
  limit: () => ({ get: async () => ({ docs: [] }) }),
};
vi.mock("../adminRuntime.js", () => ({
  db: { collection: () => emptyCollection },
  auth: {},
}));

// Empty Storage: no sealed refs to enumerate.
vi.mock("firebase-admin/storage", () => ({
  getStorage: () => ({ bucket: () => ({ getFiles: async () => [[]] }) }),
}));

// The fail-closed audit write rejects, simulating a Firestore append failure.
// `vi.hoisted` keeps the spy reachable from the hoisted `vi.mock` factory.
const { appendAuditEventRequired } = vi.hoisted(() => ({
  appendAuditEventRequired: vi.fn(async () => {
    throw new Error("audit append failed");
  }),
}));
vi.mock("../callables/auditLog.js", () => ({
  appendAuditEventRequired,
  appendAuditEvent: vi.fn(async () => undefined),
  auditActorLabel: () => "user",
  AUDIT_ACTIONS: { dataExport: "data.export" },
}));

import { exportUserData } from "../callables/dataExport.js";



function authedRequest() {
  return {
    auth: { uid: "u1", token: {} },
    app: { appId: "test-app" },
    rawRequest: { headers: {} },
    data: { domains: [] },
  };
}

describe("exportUserData — fail-closed on required audit write", () => {
  beforeEach(() => {
    appendAuditEventRequired.mockClear();
  });

  it("propagates the error when the required audit write fails", async () => {
    // @ts-expect-error onCall harness exposes .run for tests
    await expect(exportUserData.run(authedRequest())).rejects.toThrow(/audit append failed/);
    expect(appendAuditEventRequired).toHaveBeenCalledTimes(1);
  });
});
