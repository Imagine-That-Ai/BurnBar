/**
 * Durable hand-off of a verified Linq delivery to Pub/Sub.
 *
 * Uses the Pub/Sub v1 REST API through the existing `googleapis` dependency,
 * imported lazily (see `__tests__/lazyGoogleapis.test.ts`). A publish counts
 * only when Pub/Sub returns exactly one non-empty message id, which it does
 * after the message is durably stored. The request is never retried here: a
 * failure is reported to Linq as 503 and Linq redelivers the original.
 */
import type { EdgeAttributes } from "./afarEdgeContract.js";

export interface QueueMessage {
  /** `projects/{project}/topics/{topic}`. */
  readonly topic: string;
  /** The original raw body, unaltered. */
  readonly data: Uint8Array;
  readonly attributes: EdgeAttributes;
}

export type PublishFailure = "aborted" | "rejected" | "uncertain" | "invalid-response";

export type PublishOutcome =
  | { readonly kind: "published"; readonly messageId: string }
  | { readonly kind: "failed"; readonly failure: PublishFailure; readonly detail: string };

/**
 * Publishes one message. Must settle (never reject) and must stop work
 * promptly once `signal` aborts.
 */
export type LinqAfarQueuePublisher = (message: QueueMessage, signal: AbortSignal) => Promise<PublishOutcome>;

/** Exactly one non-empty string id, or null. */
export function singleMessageId(messageIds: unknown): string | null {
  if (!Array.isArray(messageIds) || messageIds.length !== 1) return null;
  const [id] = messageIds;
  return typeof id === "string" && id.length > 0 ? id : null;
}

function httpStatusOf(error: unknown): number | null {
  if (error === null || typeof error !== "object" || !("status" in error)) return null;
  const { status } = error;
  return typeof status === "number" ? status : null;
}

/** Classify a thrown publish error. Only definite client errors count as rejected. */
export function classifyPublishError(error: unknown, signal: AbortSignal): PublishOutcome {
  if (signal.aborted) return { kind: "failed", failure: "aborted", detail: "publish aborted at the handler deadline" };
  const status = httpStatusOf(error);
  if (status !== null && status >= 400 && status < 500 && status !== 408 && status !== 429) {
    return { kind: "failed", failure: "rejected", detail: `Pub/Sub returned HTTP ${status}` };
  }
  return { kind: "failed", failure: "uncertain", detail: status === null ? "Pub/Sub request failed" : `Pub/Sub returned HTTP ${status}` };
}

const PUBSUB_SCOPE = "https://www.googleapis.com/auth/pubsub";

async function createTopicsClient() {
  const { google } = await import("googleapis");
  const auth = new google.auth.GoogleAuth({ scopes: [PUBSUB_SCOPE] });
  return google.pubsub({ version: "v1", auth }).projects.topics;
}

type TopicsClient = Awaited<ReturnType<typeof createTopicsClient>>;

/**
 * Production publisher using Application Default Credentials. The client is
 * created on first use and reused; a failed creation is not cached.
 */
export function createGoogleapisAfarPublisher(): LinqAfarQueuePublisher {
  let client: Promise<TopicsClient> | null = null;
  const topics = (): Promise<TopicsClient> => {
    if (client === null) {
      const created = createTopicsClient();
      client = created;
      created.catch(() => {
        if (client === created) client = null;
      });
    }
    return client;
  };

  return async (message, signal) => {
    try {
      const api = await topics();
      if (signal.aborted) return classifyPublishError(null, signal);
      const response = await api.publish(
        {
          topic: message.topic,
          requestBody: {
            messages: [{ data: Buffer.from(message.data).toString("base64"), attributes: { ...message.attributes } }],
          },
        },
        { signal, retry: false },
      );
      const messageId = singleMessageId(response.data.messageIds);
      return messageId === null
        ? { kind: "failed", failure: "invalid-response", detail: "Pub/Sub did not return exactly one message id" }
        : { kind: "published", messageId };
    } catch (error) {
      return classifyPublishError(error, signal);
    }
  };
}
