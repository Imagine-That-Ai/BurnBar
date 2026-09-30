import { describe, expect, it } from "vitest";

import { parseIrohAuditEventForRollup } from "../../../functions-media/src/domains/relay/irohMonitoring.js";

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
});
