/**
 * @fileoverview Aggregate-only telemetry for the CloudVault Signal migration.
 *
 * Privacy contract:
 * - Never persist uid, document id/path, payload, ciphertext, key ids, or hashes.
 * - Producer is reduced to one of four fixed platform buckets.
 * - Counters are sharded randomly to avoid a hot global document.
 * - Only the ten private conversations_chat collections are observed.
 */

import { randomInt } from "node:crypto";

import { FieldValue, getFirestore } from "firebase-admin/firestore";
import { onDocumentWritten } from "firebase-functions/v2/firestore";

import { isRecord } from "./guards.js";
import { logInfo } from "./logging.js";
import { FUNCTIONS_REGION } from "./runtimeOptions.js";
import { runFirestoreTrigger } from "./scheduledOps.js";

export const SIGNAL_MIGRATION_COLLECTIONS = [
  "conversations",
  "chat_threads",
  "mobile_assistant_chats",
  "cli_sessions",
  "cli_agent_mission_requests",
  "text_snippets",
  "rollback_requests",
  "approval_policies",
  "agent_identities",
  "subscription_topics",
] as const;

type SignalMigrationCollection = (typeof SIGNAL_MIGRATION_COLLECTIONS)[number];
type SignalMigrationProducer = "ios" | "macos" | "android" | "unknown";

const TELEMETRY_SCHEMA_VERSION = 1;
const COUNTER_SHARDS = 16;

interface SignalMigrationObservation {
  collection: SignalMigrationCollection;
  producer: SignalMigrationProducer;
  operation: "create" | "update" | "delete";
  signalSealed: boolean;
  legacySealed: boolean;
  mixedEnvelope: boolean;
  plaintextOnly: boolean;
}

function normalizedSource(data: Record<string, unknown> | undefined): string {
  const candidates = [data?.source, data?.clientPlatform, data?.platform];
  return candidates
    .filter((value): value is string => typeof value === "string")
    .join(" ")
    .trim()
    .toLowerCase();
}

export function classifySignalMigrationProducer(
  data: Record<string, unknown> | undefined,
): SignalMigrationProducer {
  const source = normalizedSource(data);
  if (/\b(android|kotlin)\b/u.test(source)) return "android";
  if (/\b(macos|mac|darwin|agentlens)\b/u.test(source)) return "macos";
  if (/\b(ios|iphone|ipad|swift-mobile)\b/u.test(source)) return "ios";
  return "unknown";
}

function containsLegacySeal(data: Record<string, unknown>): boolean {
  return Object.entries(data).some(([field, value]) => {
    if (value == null) return false;
    return (
      field.startsWith("sealed") ||
      field === "encryptedPayload" ||
      field === "encryptedTranscript" ||
      field === "contentEnvelope"
    );
  });
}

export function classifySignalMigrationWrite(
  collection: SignalMigrationCollection,
  before: Record<string, unknown> | undefined,
  after: Record<string, unknown> | undefined,
): SignalMigrationObservation {
  const operation = after ? (before ? "update" : "create") : "delete";
  const signalSealed = after ? isRecord(after.signalEnvelope) : false;
  const legacySealed = after ? containsLegacySeal(after) : false;
  return {
    collection,
    producer: classifySignalMigrationProducer(after ?? before),
    operation,
    signalSealed,
    legacySealed,
    mixedEnvelope: signalSealed && legacySealed,
    plaintextOnly: operation !== "delete" && !signalSealed && !legacySealed,
  };
}

/**
 * Build the exact persisted aggregate shape. This function accepts only a
 * pre-classified observation, making it impossible to accidentally spread raw
 * document data into the telemetry write.
 */
export function signalMigrationCounterWrite(
  observation: SignalMigrationObservation,
  day: string,
): Record<string, unknown> {
  return {
    schemaVersion: TELEMETRY_SCHEMA_VERSION,
    day,
    collection: observation.collection,
    producer: observation.producer,
    totalWrites: FieldValue.increment(1),
    createWrites: FieldValue.increment(observation.operation === "create" ? 1 : 0),
    updateWrites: FieldValue.increment(observation.operation === "update" ? 1 : 0),
    deleteWrites: FieldValue.increment(observation.operation === "delete" ? 1 : 0),
    signalSealedWrites: FieldValue.increment(observation.signalSealed ? 1 : 0),
    legacySealedWrites: FieldValue.increment(observation.legacySealed ? 1 : 0),
    mixedEnvelopeWrites: FieldValue.increment(observation.mixedEnvelope ? 1 : 0),
    plaintextOnlyWrites: FieldValue.increment(observation.plaintextOnly ? 1 : 0),
    lastObservedAt: FieldValue.serverTimestamp(),
  };
}

function dayUTC(date = new Date()): string {
  return date.toISOString().slice(0, 10);
}

async function recordSignalMigrationObservation(
  collection: SignalMigrationCollection,
  before: Record<string, unknown> | undefined,
  after: Record<string, unknown> | undefined,
): Promise<void> {
  const observation = classifySignalMigrationWrite(collection, before, after);
  const day = dayUTC();
  const shard = randomInt(COUNTER_SHARDS);
  const counterID = `${collection}_${observation.producer}_${String(shard).padStart(2, "0")}`;
  await getFirestore()
    .doc(`ops_signal_migration_daily/${day}/counters/${counterID}`)
    .set(signalMigrationCounterWrite(observation, day), { merge: true });
  logInfo({
    event: "signal_migration.aggregate_recorded",
    collection,
    producer: observation.producer,
    operation: observation.operation,
    signal_sealed: observation.signalSealed,
  });
}

function signalMigrationTrigger(collection: SignalMigrationCollection) {
  return onDocumentWritten(
    {
      document: `users/{uid}/${collection}/{documentId}`,
      region: FUNCTIONS_REGION,
      maxInstances: 20,
    },
    async (event) =>
      runFirestoreTrigger(`onSignalMigration_${collection}`, async () => {
        const before = event.data?.before.exists ? event.data.before.data() : undefined;
        const after = event.data?.after.exists ? event.data.after.data() : undefined;
        await recordSignalMigrationObservation(collection, before, after);
      }),
  );
}

export const onSignalMigrationConversationWritten = signalMigrationTrigger("conversations");
export const onSignalMigrationChatThreadWritten = signalMigrationTrigger("chat_threads");
export const onSignalMigrationMobileAssistantChatWritten = signalMigrationTrigger("mobile_assistant_chats");
export const onSignalMigrationCliSessionWritten = signalMigrationTrigger("cli_sessions");
export const onSignalMigrationMissionRequestWritten = signalMigrationTrigger("cli_agent_mission_requests");
export const onSignalMigrationTextSnippetWritten = signalMigrationTrigger("text_snippets");
export const onSignalMigrationRollbackRequestWritten = signalMigrationTrigger("rollback_requests");
export const onSignalMigrationApprovalPolicyWritten = signalMigrationTrigger("approval_policies");
export const onSignalMigrationAgentIdentityWritten = signalMigrationTrigger("agent_identities");
export const onSignalMigrationSubscriptionTopicWritten = signalMigrationTrigger("subscription_topics");
