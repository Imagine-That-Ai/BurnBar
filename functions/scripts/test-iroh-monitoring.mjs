import assert from "node:assert/strict";

const {
  previousUtcDay,
  summarizeIrohAuditEvents,
  utcDayWindow,
} = await import("../lib/irohMonitoring.js");

const window = utcDayWindow(new Date("2026-05-14T17:20:00.000Z"));
assert.equal(window.date, "2026-05-14");
assert.equal(window.start.toISOString(), "2026-05-14T00:00:00.000Z");
assert.equal(window.end.toISOString(), "2026-05-15T00:00:00.000Z");
assert.equal(previousUtcDay(new Date("2026-05-15T00:05:00.000Z")).toISOString(), "2026-05-14T00:00:00.000Z");

const rollup = summarizeIrohAuditEvents([
  {
    uid: "user-a",
    connectionId: "conn-1",
    eventType: "iroh_stream_opened",
    transport: "iroh-direct",
    rttMillis: 10,
  },
  {
    uid: "user-a",
    connectionId: "conn-1",
    eventType: "iroh_stream_closed",
    transport: "iroh-direct",
    rttMillis: 20,
  },
  {
    uid: "user-b",
    connectionId: "conn-2",
    eventType: "iroh_stream_opened",
    transport: "iroh-relay",
    rttMillis: 40,
  },
  {
    uid: "user-b",
    connectionId: "conn-2",
    eventType: "iroh_fallback_to_wss",
    transport: "wss",
    rttMillis: 90,
  },
  {
    uid: "user-c",
    connectionId: "conn-3",
    eventType: "iroh_fallback_to_firestore",
    transport: "firestore",
    rttMillis: 120,
  },
  {
    uid: "user-b",
    connectionId: "conn-2",
    eventType: "iroh_pairing_rejected",
  },
], window, new Date("2026-05-15T08:15:00.000Z"));

assert.equal(rollup.id, "2026-05-14");
assert.equal(rollup.totalEvents, 6);
assert.equal(rollup.uniqueUsers, 3);
assert.equal(rollup.uniqueConnections, 3);
assert.equal(rollup.streamOpens, 2);
assert.equal(rollup.streamCloses, 1);
assert.equal(rollup.streamFailures, 0);
assert.equal(rollup.wssFallbacks, 1);
assert.equal(rollup.firestoreFallbacks, 1);
assert.equal(rollup.eventCounts.iroh_pairing_rejected, 1);
assert.equal(rollup.eventCounts.iroh_fallback_to_firestore, 1);
assert.equal(rollup.transportCounts["iroh-direct"], 2);
assert.equal(rollup.transportCounts["iroh-relay"], 1);
assert.equal(rollup.transportCounts.wss, 1);
assert.equal(rollup.transportCounts.firestore, 1);
assert.equal(rollup.successRate, 1 / 3);
assert.equal(rollup.fallbackRate, 2 / 3);
assert.equal(rollup.directShare, 2 / 3);
assert.equal(rollup.relayShare, 1 / 3);
assert.deepEqual(rollup.rttMillis, {
  count: 5,
  p50: 40,
  p95: 120,
  p99: 120,
});

console.log("iroh monitoring rollup ok");
