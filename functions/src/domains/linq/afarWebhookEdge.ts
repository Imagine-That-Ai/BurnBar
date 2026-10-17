/**
 * `POST /linq/afar` handler factory (contract `linq-afar-edge/1`).
 *
 * Source only: nothing exports this as a Cloud Function yet, and no Hosting
 * rewrite points at it. Activation wires `createLinqAfarEdgeHandler` into
 * `onRequest` with `EDGE_INSTANCE_LIMITS` once the topic, secret and exclusive
 * publisher binding exist.
 *
 * Responses: 204 only after Pub/Sub returns exactly one message id; 400
 * malformed or unsupported; 401 bad or stale signature; 403 line outside the
 * binding; 405/413/415 for method, size and media type; 503 with Retry-After
 * for missing configuration, capacity, deadline or any uncertain publish.
 */
import { logError, logWarn } from "@openburnbar/functions-shared/logging.js";
import {
  ADMISSION_LIMIT,
  HANDLER_DEADLINE_MS,
  MAX_BODY_BYTES,
  RETRY_AFTER_SECONDS,
  parseAfarEvent,
  type LinqAfarEdgeConfigSource,
} from "./afarEdgeContract.js";
import type { LinqAfarQueuePublisher, PublishOutcome } from "./afarQueuePublisher.js";
import {
  buildEdgeAttributes,
  collectSingleHeaders,
  isFresh,
  readWebhookHeaders,
  verifySignature,
} from "./standardWebhooks.js";

/** The parts of the Cloud Functions request the edge reads. */
export interface EdgeRequest {
  readonly method: string;
  readonly rawHeaders: readonly string[];
  readonly rawBody?: Buffer;
}

/** The parts of the response the edge writes. */
export interface EdgeResponse {
  statusCode: number;
  setHeader(name: string, value: string): unknown;
  end(chunk?: string): unknown;
}

export interface Clock {
  nowMs(): number;
}

export const systemClock: Clock = { nowMs: () => Date.now() };

/** Bounded in-process admission. A permit is held until all work it covers has settled. */
export class AdmissionGate {
  #inFlight = 0;

  constructor(private readonly limit: number) {
    if (!Number.isInteger(limit) || limit < 1) throw new RangeError("admission limit must be a positive integer");
  }

  get inFlight(): number {
    return this.#inFlight;
  }

  /** Returns a one-shot release function, or null when the gate is full. */
  tryAcquire(): (() => void) | null {
    if (this.#inFlight >= this.limit) return null;
    this.#inFlight += 1;
    let released = false;
    return () => {
      if (released) return;
      released = true;
      this.#inFlight -= 1;
    };
  }
}

export interface LinqAfarEdgeDependencies {
  /** Explicit binding source. Production passes `unavailableLinqAfarEdgeConfig` until activation. */
  readonly configSource: LinqAfarEdgeConfigSource;
  readonly publisher: LinqAfarQueuePublisher;
  readonly clock?: Clock;
  readonly admission?: AdmissionGate;
  readonly deadlineMs?: number;
}

type Rejection = 400 | 401 | 403 | 405 | 413 | 415 | 503;

const ERROR_CODES: Readonly<Record<Rejection, string>> = {
  400: "malformed",
  401: "unauthorized",
  403: "forbidden",
  405: "method_not_allowed",
  413: "payload_too_large",
  415: "unsupported_media_type",
  503: "unavailable",
};

const JSON_MEDIA_TYPE = /^application\/json\s*(?:;\s*charset\s*=\s*"?utf-8"?\s*)?$/i;

function respond(res: EdgeResponse, status: 204 | Rejection): void {
  res.statusCode = status;
  res.setHeader("Cache-Control", "no-store");
  if (status === 204) {
    res.end();
    return;
  }
  if (status === 405) res.setHeader("Allow", "POST");
  if (status === 503) res.setHeader("Retry-After", String(RETRY_AFTER_SECONDS));
  res.setHeader("Content-Type", "application/json; charset=utf-8");
  res.end(JSON.stringify({ error: ERROR_CODES[status] }));
}

function declaredLengthTooLarge(rawHeaders: readonly string[]): boolean {
  const { values } = collectSingleHeaders(rawHeaders, ["content-length"]);
  const declared = values.get("content-length");
  return declared !== undefined && /^[0-9]+$/.test(declared) && Number(declared) > MAX_BODY_BYTES;
}

/** Build the request handler. Every dependency is explicit; there is no default configuration. */
export function createLinqAfarEdgeHandler(deps: LinqAfarEdgeDependencies): (req: EdgeRequest, res: EdgeResponse) => Promise<void> {
  const clock = deps.clock ?? systemClock;
  const admission = deps.admission ?? new AdmissionGate(ADMISSION_LIMIT);
  const deadlineMs = deps.deadlineMs ?? HANDLER_DEADLINE_MS;
  if (!Number.isInteger(deadlineMs) || deadlineMs < 1) throw new RangeError("deadlineMs must be a positive integer");

  return async (req, res) => {
    const deadlineAt = clock.nowMs() + deadlineMs;

    if (req.method !== "POST") return respond(res, 405);
    const contentType = collectSingleHeaders(req.rawHeaders, ["content-type"]);
    const mediaType = contentType.values.get("content-type");
    if (contentType.duplicate !== null || mediaType === undefined || !JSON_MEDIA_TYPE.test(mediaType)) {
      return respond(res, 415);
    }
    if (declaredLengthTooLarge(req.rawHeaders) || (req.rawBody !== undefined && req.rawBody.length > MAX_BODY_BYTES)) {
      return respond(res, 413);
    }

    const release = admission.tryAcquire();
    if (release === null) return respond(res, 503);
    try {
      await handleAdmitted(req, res, deadlineAt);
    } finally {
      release();
    }
  };

  async function handleAdmitted(req: EdgeRequest, res: EdgeResponse, deadlineAt: number): Promise<void> {
    const config = deps.configSource();
    if (config === null) return respond(res, 503);

    const rawBody = req.rawBody;
    if (rawBody === undefined || rawBody.length === 0) return respond(res, 400);

    const headerResult = readWebhookHeaders(req.rawHeaders);
    if (!headerResult.ok) return respond(res, 400);
    const { headers } = headerResult;

    const verifiedAtMs = clock.nowMs();
    if (!isFresh(headers.timestamp, verifiedAtMs) || !verifySignature(headers, rawBody, config.signingKey)) {
      logWarn({ event: "linq_afar_edge.rejected", reason: "signature_or_freshness" });
      return respond(res, 401);
    }

    const event = parseAfarEvent(rawBody, config);
    if (event.kind === "malformed") return respond(res, 400);
    if (event.kind === "unbound") {
      logWarn({ event: "linq_afar_edge.rejected", reason: "line_not_bound" });
      return respond(res, 403);
    }

    const attributeResult = buildEdgeAttributes(headers, verifiedAtMs);
    if (!attributeResult.ok) return respond(res, 400);

    const remainingMs = deadlineAt - clock.nowMs();
    if (remainingMs <= 0) return respond(res, 503);

    const outcome = await publishWithinDeadline(
      { topic: config.topic, data: rawBody, attributes: attributeResult.attributes },
      remainingMs,
      res,
    );
    if (outcome === null) return;
    if (outcome.kind === "published") return respond(res, 204);
    logError({ event: "linq_afar_edge.publish_failed", failure: outcome.failure, error: outcome.detail });
    return respond(res, 503);
  }

  /**
   * Publish, but answer 503 when the deadline passes first. Either way the
   * function returns only after the publish promise settles, so the caller's
   * admission permit covers the whole underlying request.
   * Returns null when the deadline response was already sent.
   */
  async function publishWithinDeadline(
    message: Parameters<LinqAfarQueuePublisher>[0],
    remainingMs: number,
    res: EdgeResponse,
  ): Promise<PublishOutcome | null> {
    const controller = new AbortController();
    const settled: Promise<PublishOutcome> = deps.publisher(message, controller.signal).then(
      (outcome) => outcome,
      (error: unknown) => ({ kind: "failed", failure: "uncertain", detail: error instanceof Error ? error.message : "publisher threw" }),
    );
    let timer: NodeJS.Timeout | undefined;
    const deadline = new Promise<"deadline">((resolve) => {
      timer = setTimeout(() => resolve("deadline"), remainingMs);
    });
    try {
      const first = await Promise.race([settled, deadline]);
      if (first !== "deadline") return first;
      controller.abort();
      respond(res, 503);
      const late = await settled;
      logError({ event: "linq_afar_edge.publish_failed", failure: "deadline", error: `settled after deadline as ${late.kind}` });
      return null;
    } finally {
      clearTimeout(timer);
    }
  }
}
