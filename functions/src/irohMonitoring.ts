/**
 * @fileoverview Production monitoring rollups for Hermes iroh transport.
 *
 * Apps write per-user audit events to `users/{uid}/iroh_audit_events/*`.
 * This worker turns that raw stream into one operator-owned daily document so
 * rollout gates can be checked without browsing every user subcollection.
 */

import { getFirestore } from "firebase-admin/firestore";
import { onSchedule } from "firebase-functions/v2/scheduler";
import type { Firestore, QueryDocumentSnapshot } from "firebase-admin/firestore";
import type { IrohTransportAuditEventDoc, IrohTransportDailyRollupDoc } from "./types.js";
import { isRecord, numberField, recordField, stringField } from "./guards.js";

const IROH_ROLLUP_SCHEMA_VERSION = 1;
const IROH_AUDIT_COLLECTION = "iroh_audit_events";
const IROH_ROLLUP_COLLECTION = "ops/iroh_transport_daily_rollups/days";

type IrohAuditEventType = IrohTransportAuditEventDoc["eventType"];
type IrohTransport = NonNullable<IrohTransportAuditEventDoc["transport"]>;

export interface IrohAuditRollupInput {
  uid: string;
  connectionId: string;
  eventType: IrohAuditEventType;
  transport?: IrohTransport;
  rttMillis?: number;
}

const EVENT_TYPES: IrohAuditEventType[] = [
  "iroh_stream_opened",
  "iroh_stream_closed",
  "iroh_stream_failed",
  "iroh_pairing_published",
  "iroh_pairing_verified",
  "iroh_pairing_rejected",
  "iroh_fallback_to_wss",
  "iroh_fallback_to_firestore",
];

const TRANSPORTS: IrohTransport[] = ["iroh-direct", "iroh-relay", "wss", "firestore"];

function isIrohAuditEventType(value: unknown): value is IrohAuditEventType {
  return EVENT_TYPES.some((eventType) => eventType === value);
}

function isIrohTransport(value: unknown): value is IrohTransport {
  return TRANSPORTS.some((transport) => transport === value);
}

function emptyEventCounts(): Record<IrohAuditEventType, number> {
  const counts: Partial<Record<IrohAuditEventType, number>> = {};
  for (const eventType of EVENT_TYPES) {
    counts[eventType] = 0;
  }
  if (!isCompleteEventCounts(counts)) {
    throw new Error("Failed to initialize iroh event counts.");
  }
  return counts;
}

function isCompleteEventCounts(
  value: Partial<Record<IrohAuditEventType, number>>,
): value is Record<IrohAuditEventType, number> {
  return EVENT_TYPES.every((eventType) => typeof value[eventType] === "number");
}

function emptyTransportCounts(): Record<IrohTransport, number> {
  const counts: Partial<Record<IrohTransport, number>> = {};
  for (const transport of TRANSPORTS) {
    counts[transport] = 0;
  }
  if (!isCompleteTransportCounts(counts)) {
    throw new Error("Failed to initialize iroh transport counts.");
  }
  return counts;
}

function isCompleteTransportCounts(
  value: Partial<Record<IrohTransport, number>>,
): value is Record<IrohTransport, number> {
  return TRANSPORTS.every((transport) => typeof value[transport] === "number");
}

function percentile(sorted: number[], percentileValue: number): number | undefined {
  if (sorted.length === 0) {
    return undefined;
  }
  const index = Math.min(sorted.length - 1, Math.max(0, Math.ceil((percentileValue / 100) * sorted.length) - 1));
  return sorted[index];
}

function rate(numerator: number, denominator: number): number {
  return denominator > 0 ? numerator / denominator : 0;
}

export function utcDayWindow(date: Date): { date: string; start: Date; end: Date } {
  const dateId = date.toISOString().slice(0, 10);
  const start = new Date(`${dateId}T00:00:00.000Z`);
  const end = new Date(start.getTime() + 24 * 60 * 60 * 1000);
  return { date: dateId, start, end };
}

export function previousUtcDay(now: Date): Date {
  return new Date(Date.UTC(now.getUTCFullYear(), now.getUTCMonth(), now.getUTCDate() - 1));
}

export function summarizeIrohAuditEvents(
  events: IrohAuditRollupInput[],
  window: { date: string; start: Date; end: Date },
  generatedAt: Date = new Date(),
): IrohTransportDailyRollupDoc {
  const eventCounts = emptyEventCounts();
  const transportCounts = emptyTransportCounts();
  const users = new Set<string>();
  const connections = new Set<string>();
  const rtts: number[] = [];

  for (const event of events) {
    users.add(event.uid);
    connections.add(`${event.uid}/${event.connectionId}`);
    eventCounts[event.eventType] += 1;
    if (event.transport) {
      transportCounts[event.transport] += 1;
    }
    if (typeof event.rttMillis === "number" && Number.isFinite(event.rttMillis) && event.rttMillis >= 0) {
      rtts.push(Math.round(event.rttMillis));
    }
  }

  rtts.sort((left, right) => left - right);

  const streamCloses = eventCounts.iroh_stream_closed;
  const streamFailures = eventCounts.iroh_stream_failed;
  const wssFallbacks = eventCounts.iroh_fallback_to_wss;
  const firestoreFallbacks = eventCounts.iroh_fallback_to_firestore;
  const totalFallbacks = wssFallbacks + firestoreFallbacks;
  const terminalEvents = streamCloses + streamFailures + totalFallbacks;
  const irohTransports = transportCounts["iroh-direct"] + transportCounts["iroh-relay"];

  return {
    id: window.date,
    date: window.date,
    windowStart: window.start.toISOString(),
    windowEnd: window.end.toISOString(),
    generatedAt: generatedAt.toISOString(),
    totalEvents: events.length,
    uniqueUsers: users.size,
    uniqueConnections: connections.size,
    eventCounts,
    transportCounts,
    streamOpens: eventCounts.iroh_stream_opened,
    streamCloses,
    streamFailures,
    wssFallbacks,
    firestoreFallbacks,
    successRate: rate(streamCloses, terminalEvents),
    fallbackRate: rate(totalFallbacks, terminalEvents),
    directShare: rate(transportCounts["iroh-direct"], irohTransports),
    relayShare: rate(transportCounts["iroh-relay"], irohTransports),
    rttMillis: {
      count: rtts.length,
      p50: percentile(rtts, 50),
      p95: percentile(rtts, 95),
      p99: percentile(rtts, 99),
    },
    schemaVersion: IROH_ROLLUP_SCHEMA_VERSION,
  };
}

function uidFromPath(path: string): string {
  const parts = path.split("/");
  return parts[0] === "users" && parts.length >= 4 ? parts[1] : "unknown";
}

function eventFromSnapshot(doc: QueryDocumentSnapshot): IrohAuditRollupInput | null {
  const data = doc.data();
  const connectionId = stringField(data, "connectionId");
  const eventType = recordField(data, "eventType");
  if (!connectionId || !isIrohAuditEventType(eventType)) {
    return null;
  }
  const transportRaw = recordField(data, "transport");
  const transport = isIrohTransport(transportRaw) ? transportRaw : undefined;
  return {
    uid: uidFromPath(doc.ref.path),
    connectionId,
    eventType,
    transport,
    rttMillis: numberField(data, "rttMillis"),
  };
}

export async function buildAndPersistIrohDailyRollup(
  db: Firestore,
  day: Date = previousUtcDay(new Date()),
  generatedAt: Date = new Date(),
): Promise<IrohTransportDailyRollupDoc> {
  const window = utcDayWindow(day);
  const snapshot = await db
    .collectionGroup(IROH_AUDIT_COLLECTION)
    .where("observedAt", ">=", window.start.toISOString())
    .where("observedAt", "<", window.end.toISOString())
    .get();

  const events = snapshot.docs.map(eventFromSnapshot).filter((event): event is IrohAuditRollupInput => event !== null);
  const rollup = summarizeIrohAuditEvents(events, window, generatedAt);

  await db.collection(IROH_ROLLUP_COLLECTION).doc(rollup.id).set(rollup, { merge: true });

  return rollup;
}

export const rollupIrohTransportDaily = onSchedule(
  {
    schedule: "15 8 * * *",
    timeZone: "Etc/UTC",
    region: "us-central1",
  },
  async (_event) => {
    await buildAndPersistIrohDailyRollup(getFirestore());
  },
);
