/**
 * @fileoverview AI Inbox P1 push notifications.
 *
 * The AI Inbox is produced on the Mac by the daemon and mirrored to
 * `users/{uid}/ai_inbox_items/{itemId}`. Its whole premise is "tell me what
 * happened while I wasn't watching", so the alert has to reach a phone whose
 * Mac is asleep — which is exactly why the mirror is durable Firestore rather
 * than a live relay, and why this push rides the Cloud Function plane.
 *
 * ## What this function can and cannot see
 *
 * The mirror document body is SEALED with the Cloud Vault. This function has no
 * key and therefore cannot read the title, the summary, the evidence, or the
 * project name — by design. It sees only the plaintext routing fields (`kind`,
 * `priority`, `state`, timestamps) that the mirror deliberately leaves
 * top-level so sorting and this trigger work without decrypting.
 *
 * So the push carries an opaque `item_id` plus the two bounded enums, and the
 * client hydrates and decrypts the real content from Firestore after delivery.
 * That is the same privacy posture `agentNotifications.ts` already uses for
 * agent replies (OPUS-F-006), and it means a compromised push provider learns
 * "an alert of kind X fired", never its contents.
 *
 * ## Why create-only
 *
 * The Mac already gates notification volume (`BurnBarAIInboxPublisher`: P1 only,
 * at most one per tick, one hour of cooldown per fingerprint). Firing on update
 * would re-alert on every occurrence bump of an item the user has already seen,
 * defeating that gate entirely. `onDocumentCreated` + `state == "new"` means one
 * alert per genuinely new P1 item, and the shared `create`-not-`set` event write
 * makes a redelivered platform trigger a no-op.
 */

import { onDocumentCreated } from "firebase-functions/v2/firestore";

import {
  createNotificationEvent,
  fanoutAgentReplyEvent,
  type AgentNotificationSourceKind,
} from "./agentNotifications.js";
import { isRecord } from "./guards.js";
import { logInfo } from "./logging.js";
import { FUNCTIONS_REGION } from "./runtimeOptions.js";

const REGION = FUNCTIONS_REGION;
const SOURCE_KIND: AgentNotificationSourceKind = "ai_inbox_item";

/**
 * Only P1 raises a push. The Kernel's `BurnBarInboxPriority` documents P1 as
 * "the you-would-want-to-be-interrupted tier and the only band permitted to
 * raise a user notification"; this is the cloud half of that rule.
 */
const ALERTABLE_PRIORITY = 1;

/**
 * An item whose last sighting is older than this is history, not news.
 *
 * Without it, the first mirror sync from a Mac that has been accumulating items
 * offline would fan out every historical P1 at once — a push storm that reads as
 * a bug and trains the user to disable notifications. Six hours is longer than
 * any plausible sync lag and far shorter than the age at which an alert stops
 * being actionable.
 */
const MAX_INBOX_ALERT_AGE_MS = 6 * 60 * 60 * 1000;

/**
 * `BurnBarInboxItemKind` raw values. Kept in sync with the Kernel contract
 * (`OpenBurnBarKernel/Contracts/BurnBarAIInboxContracts.swift`); an unrecognized
 * kind degrades to `system` rather than riding to FCM unvalidated, so a future
 * Mac build can never push an arbitrary string through the notification plane.
 */
const INBOX_KIND_LABELS: Record<string, string> = {
  ci_waste: "Wasted CI",
  promised_not_landed: "Promised, not landed",
  uncommitted_work: "Uncommitted work",
  cost_anomaly: "Cost anomaly",
  stuck_pr: "Stuck pull request",
  index_health: "Index health",
  brief: "Brief",
  budget: "Budget",
  system: "OpenBurnBar",
};

const FALLBACK_KIND = "system";

/** The alert body. Generic on purpose — the real summary is sealed. */
const GENERIC_INBOX_PREVIEW = "Open OpenBurnBar to see what needs you.";

interface InboxAlertRouting {
  itemId: string;
  kind: string;
  priority: number;
}

export function inboxKindLabel(kind: string): string {
  return INBOX_KIND_LABELS[kind] ?? INBOX_KIND_LABELS[FALLBACK_KIND];
}

export function inboxEventIdFor(itemId: string): string {
  return `ai_inbox_${safeId(itemId)}`;
}

/**
 * Decide whether a freshly-created mirror document deserves a push.
 *
 * Exported so the alerting rule is testable without a Firestore event: this is
 * the whole gate, and every rejection reason below is a case a wrong answer
 * would either spam the user or silently drop a real P1.
 */
export function inboxAlertRouting(args: {
  itemId: string;
  data: Record<string, unknown> | undefined;
  now?: number;
}): InboxAlertRouting | undefined {
  const data = args.data;
  if (!isRecord(data)) return undefined;
  if (data.state !== "new") return undefined;
  const priority = numberValue(data.priority);
  if (priority !== ALERTABLE_PRIORITY) return undefined;
  // A document without a seal is not a mirror document this build understands.
  if (data.contentSealed !== true) return undefined;

  const lastSeenMillis = timestampMillis(data.lastSeenAt);
  if (lastSeenMillis === undefined) return undefined;
  const now = args.now ?? Date.now();
  if (now - lastSeenMillis > MAX_INBOX_ALERT_AGE_MS) return undefined;

  const rawKind = typeof data.kind === "string" ? data.kind : "";
  return {
    itemId: args.itemId,
    kind: rawKind in INBOX_KIND_LABELS ? rawKind : FALLBACK_KIND,
    priority,
  };
}

export const onAIInboxItemNotification = onDocumentCreated(
  {
    document: "users/{uid}/ai_inbox_items/{itemId}",
    region: REGION,
  },
  async (event) => {
    const uid = String(event.params.uid);
    const itemId = String(event.params.itemId);
    const routing = inboxAlertRouting({ itemId, data: event.data?.data() });
    if (!routing) return;

    const eventId = await createNotificationEvent({
      event: {
        id: inboxEventIdFor(routing.itemId),
        uid,
        sourceKind: SOURCE_KIND,
        // The path is the collection shape, never the raw uid — the same
        // constraint the sweeper's logging obeys (F-RR09-002).
        sourcePath: `ai_inbox_items/${routing.itemId}`,
        // The inbox is not a conversation: there is no thread to resume and no
        // provider that "replied". Empty rather than synthesized so nothing
        // downstream mistakes an alert for a chat.
        threadId: "",
        messageId: routing.itemId,
        runtime: "inbox",
        providerLabel: "OpenBurnBar",
        title: inboxKindLabel(routing.kind),
        preview: GENERIC_INBOX_PREVIEW,
        // No inline reply affordance: replying to an alert is meaningless, and
        // `submitAgentNotificationReply` refuses non-repliable events.
        replyEnabled: false,
        inboxItemId: routing.itemId,
        inboxKind: routing.kind,
        inboxPriority: routing.priority,
      },
    });
    if (!eventId) return;

    const fanout = await fanoutAgentReplyEvent({ uid, eventId });
    logInfo({
      event: "ai_inbox_alert_fanout",
      // Bounded enum + the document-scoped event id only: no uid, no path, no
      // item content.
      inbox_kind: routing.kind,
      ...fanout,
    });
  },
);

function numberValue(raw: unknown): number | undefined {
  return typeof raw === "number" && Number.isFinite(raw) ? raw : undefined;
}

/** Accepts a Firestore `Timestamp`, a raw `Date`, or epoch millis/seconds. */
function timestampMillis(raw: unknown): number | undefined {
  if (raw instanceof Date) return raw.getTime();
  if (isRecord(raw) && typeof raw.toMillis === "function") {
    const millis: unknown = (raw.toMillis as () => unknown)();
    return numberValue(millis);
  }
  return undefined;
}

function safeId(raw: string): string {
  return raw.replace(/[^A-Za-z0-9_-]/g, "_").slice(0, 240);
}
