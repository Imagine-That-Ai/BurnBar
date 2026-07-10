import { Timestamp } from "firebase-admin/firestore";
import type { DocumentData } from "firebase-admin/firestore";
import { describe, expect, it } from "vitest";

import { __testing__ } from "../computerUseMetering.js";

describe("computer use immediate metering", () => {
  it("applies a source delta exactly once in one transaction", async () => {
    const documents = new Map<string, DocumentData>([
      [
        "users/alice/computer_use_actions/action-1",
        {
          status: "executed",
          toolKind: "browser_click",
          approvedBy: "mac",
        },
      ],
    ]);
    const ref = (path: string) => ({ path });
    const snapshot = (path: string) => {
      const data = documents.get(path);
      return {
        exists: data !== undefined,
        data: () => data,
        get: (field: string) => data?.[field],
      };
    };
    const firestore = {
      doc: (path: string) => ref(path),
      runTransaction: async <T>(
        body: (transaction: {
          get: (reference: ReturnType<typeof ref>) => Promise<ReturnType<typeof snapshot>>;
          set: (reference: ReturnType<typeof ref>, data: DocumentData, options: { merge: false }) => void;
          update: (reference: ReturnType<typeof ref>, data: DocumentData) => void;
        }) => Promise<T>,
      ) =>
        body({
          get: async (reference) => snapshot(reference.path),
          set: (reference, data) => documents.set(reference.path, { ...data }),
          update: (reference, data) =>
            documents.set(reference.path, {
              ...documents.get(reference.path),
              ...data,
            }),
        }),
    };
    const sourceRef = ref("users/alice/computer_use_actions/action-1");
    const options = {
      firestore,
      sourceRef,
      uid: "alice",
      eventId: "event-1",
      markerPrefix: "quotaMetered" as const,
      occurredAt: new Date("2026-07-10T12:00:00Z"),
      delta: __testing__.actionQuotaDelta({
        status: "executed",
        toolKind: "browser_click",
        approvedBy: "mac",
      }),
    };

    await expect(__testing__.applyDeltaOnce(options)).resolves.toBe(true);
    await expect(__testing__.applyDeltaOnce(options)).resolves.toBe(false);
    expect(documents.get("users/alice/computer_use_quota_usage/2026-07-10")).toMatchObject({
      browserActionsExecuted: 1,
    });
    expect(documents.get(sourceRef.path)?.quotaMeteredEventId).toBe("event-1");
  });

  it("classifies executed browser and phone actions without payload data", () => {
    expect(
      __testing__.actionQuotaDelta({
        status: "executed",
        toolKind: "browser_click",
        approvedBy: "phone",
        visionTokensCostUSD: 0.25,
      }),
    ).toMatchObject({
      browserActionsExecuted: 1,
      browserActionsRejected: 0,
      phoneControlIntentsExecuted: 1,
      visionModelSpendUSD: 0.25,
    });
  });

  it("counts terminal failures as rejected and clamps untrusted spend", () => {
    expect(
      __testing__.actionQuotaDelta({
        status: "error",
        toolKind: "mac_input_click",
        approvedBy: "mac",
        visionTokensCostUSD: 900,
      }),
    ).toMatchObject({
      systemActionsExecuted: 0,
      systemActionsRejected: 1,
      visionModelSpendUSD: 25,
    });
  });

  it("advances every counter monotonically", () => {
    const next = __testing__.nextQuotaUsage(
      {
        browserActionsExecuted: 4,
        systemActionsExecuted: 7,
        sessionsStarted: 2,
        visionModelSpendUSD: 1.5,
      },
      "2026-07-10",
      __testing__.actionQuotaDelta({ status: "executed", toolKind: "browser_click", approvedBy: "mac" }),
      new Date("2026-07-10T12:00:00Z"),
    );
    expect(next.browserActionsExecuted).toBe(5);
    expect(next.systemActionsExecuted).toBe(7);
    expect(next.sessionsStarted).toBe(2);
    expect(next.visionModelSpendUSD).toBe(1.5);
    expect(next.updatedAt).toBeInstanceOf(Timestamp);
  });

  it("derives quota days from server event time in UTC", () => {
    expect(__testing__.dayKeyUTC(new Date("2026-07-10T23:59:59.999Z"))).toBe("2026-07-10");
    expect(__testing__.dayKeyUTC(new Date("2026-07-11T00:00:00.000Z"))).toBe("2026-07-11");
  });
});
