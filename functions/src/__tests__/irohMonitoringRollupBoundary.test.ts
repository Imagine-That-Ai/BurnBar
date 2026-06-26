import { describe, expect, it } from "vitest";

import {
  markIrohAuditEventRollupEligible,
  parseIrohAuditEventForRollup,
  summarizeIrohAuditEvents,
  utcDayWindow,
} from "../irohMonitoring.js";

const EVENT_PATH = "users/user-1/iroh_audit_events/event-1";

function auditEvent(overrides: Record<string, unknown> = {}): Record<string, unknown> {
  return {
    id: "event-1",
    connectionId: "conn-1",
    eventType: "iroh_stream_closed",
    observedAt: "2026-06-02T00:00:00.000Z",
    transport: "iroh-direct",
    rttMillis: 42,
    schemaVersion: 1,
    ...overrides,
  };
}

describe("iroh transport rollup trust boundary", () => {
  it("ignores client-writable audit events unless the server marks them rollup eligible", () => {
    expect(parseIrohAuditEventForRollup(auditEvent(), EVENT_PATH)).toBeNull();
    expect(parseIrohAuditEventForRollup(auditEvent({ rollupEligible: false }), EVENT_PATH)).toBeNull();

    const parsed = parseIrohAuditEventForRollup(auditEvent({ rollupEligible: true }), EVENT_PATH);

    expect(parsed).toEqual({
      uid: "user-1",
      connectionId: "conn-1",
      eventType: "iroh_stream_closed",
      transport: "iroh-direct",
      rttMillis: 42,
    });
  });

  it("summarizes only parsed eligible events", () => {
    const candidates = [
      parseIrohAuditEventForRollup(auditEvent(), EVENT_PATH),
      parseIrohAuditEventForRollup(auditEvent({ rollupEligible: true }), EVENT_PATH),
    ].filter((event) => event !== null);

    const rollup = summarizeIrohAuditEvents(
      candidates,
      utcDayWindow(new Date("2026-06-02T12:00:00.000Z")),
      new Date("2026-06-03T00:00:00.000Z"),
    );

    expect(rollup.totalEvents).toBe(1);
    expect(rollup.uniqueUsers).toBe(1);
    expect(rollup.eventCounts.iroh_stream_closed).toBe(1);
    expect(rollup.transportCounts["iroh-direct"]).toBe(1);
  });

  it("exports the server-side eligibility marker", () => {
    expect(markIrohAuditEventRollupEligible).toBeDefined();
  });
});
