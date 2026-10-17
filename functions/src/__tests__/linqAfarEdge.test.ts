import { createHmac } from "node:crypto";
import { readFileSync } from "node:fs";
import { resolve } from "node:path";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import {
  ATTRIBUTE_NAMES,
  EDGE_INSTANCE_LIMITS,
  MAX_BODY_BYTES,
  parseLinqAfarEdgeConfig,
  unavailableLinqAfarEdgeConfig,
  type LinqAfarEdgeConfig,
  type LinqAfarEdgeConfigSource,
} from "../domains/linq/afarEdgeContract.js";
import {
  classifyPublishError,
  createGoogleapisAfarPublisher,
  singleMessageId,
  type LinqAfarQueuePublisher,
  type PublishOutcome,
  type QueueMessage,
} from "../domains/linq/afarQueuePublisher.js";
import { AdmissionGate, createLinqAfarEdgeHandler, type EdgeRequest, type EdgeResponse } from "../domains/linq/afarWebhookEdge.js";

let googleapisLoads = 0;
const publishCall = vi.fn();
vi.mock("googleapis", () => {
  googleapisLoads += 1;
  return {
    google: {
      auth: { GoogleAuth: vi.fn() },
      pubsub: vi.fn(() => ({ projects: { topics: { publish: publishCall } } })),
    },
  };
});

const SECRET = "whsec_MfKQ9r8GKYqrTwjUPD8ILPZIo2LaLaSw";
const KEY = Buffer.from("MfKQ9r8GKYqrTwjUPD8ILPZIo2LaLaSw", "base64");
const LINE = "+14155550100";
const NOW_MS = Date.UTC(2026, 9, 17, 1, 20, 1, 0);
const NOW_S = Math.floor(NOW_MS / 1000);

function bindConfig(): LinqAfarEdgeConfig {
  const result = parseLinqAfarEdgeConfig({ topic: "projects/burnbar-test/topics/linq-afar", signingSecret: SECRET, approvedLines: [LINE] });
  if (!result.ok) throw new Error(result.error);
  return result.config;
}
const CONFIG = bindConfig();

function body(fields: Record<string, unknown> = {}): Buffer {
  return Buffer.from(
    JSON.stringify({
      event_id: "evt_1",
      event_type: "message.received",
      webhook_version: "2026-02-03",
      created_at: "2026-10-17T01:20:00Z",
      data: { chat: { owner_handle: { handle: LINE } } },
      ...fields,
    }),
    "utf8",
  );
}

interface RequestOptions {
  method?: string;
  raw?: Buffer;
  id?: string;
  timestamp?: number;
  signature?: string;
  extraHeaders?: string[];
  contentType?: string | null;
}

function request(options: RequestOptions = {}): EdgeRequest {
  const raw = options.raw ?? body();
  const id = options.id ?? "msg_1";
  const timestamp = String(options.timestamp ?? NOW_S);
  const signature =
    options.signature ?? `v1,${createHmac("sha256", KEY).update(`${id}.${timestamp}.`).update(raw).digest("base64")}`;
  const rawHeaders = [
    ...(options.contentType === null ? [] : ["Content-Type", options.contentType ?? "application/json"]),
    "webhook-id",
    id,
    "webhook-timestamp",
    timestamp,
    "webhook-signature",
    signature,
    ...(options.extraHeaders ?? []),
  ];
  return { method: options.method ?? "POST", rawHeaders, rawBody: raw };
}

class FakeResponse implements EdgeResponse {
  statusCode = 0;
  readonly headers = new Map<string, string>();
  body: string | undefined;
  ended = false;
  setHeader(name: string, value: string): this {
    this.headers.set(name.toLowerCase(), value);
    return this;
  }
  end(chunk?: string): this {
    this.body = chunk;
    this.ended = true;
    return this;
  }
}

const clock = { nowMs: () => NOW_MS };

function published(id = "m-1") {
  return vi.fn<LinqAfarQueuePublisher>(async () => ({ kind: "published", messageId: id }));
}

async function run(req: EdgeRequest, publisher: LinqAfarQueuePublisher = published(), configSource: LinqAfarEdgeConfigSource = () => CONFIG) {
  const res = new FakeResponse();
  await createLinqAfarEdgeHandler({ configSource, publisher, clock })(req, res);
  return res;
}

beforeEach(() => {
  vi.spyOn(console, "error").mockImplementation(() => undefined);
  vi.spyOn(console, "warn").mockImplementation(() => undefined);
  vi.spyOn(console, "log").mockImplementation(() => undefined);
});
afterEach(() => {
  vi.restoreAllMocks();
  vi.useRealTimers();
});

describe("linq afar edge: success", () => {
  it("publishes the original raw body with exactly five attributes, then answers 204", async () => {
    const publisher = published();
    const raw = Buffer.from(`  ${body().toString("utf8")}\n`, "utf8");
    const res = await run(request({ raw }), publisher);
    expect(res.statusCode).toBe(204);
    expect(res.body).toBeUndefined();
    expect(res.headers.get("cache-control")).toBe("no-store");
    expect(publisher).toHaveBeenCalledTimes(1);
    const call = publisher.mock.calls[0];
    if (call === undefined) throw new Error("publisher was not called");
    const [message] = call;
    expect(Buffer.from(message.data).equals(raw)).toBe(true);
    expect(message.topic).toBe("projects/burnbar-test/topics/linq-afar");
    expect(Object.keys(message.attributes)).toEqual([...ATTRIBUTE_NAMES]);
    expect(message.attributes["edge-received-at"]).toBe("2026-10-17T01:20:01.000Z");
    expect(message.attributes["edge-contract"]).toBe("linq-afar-edge/1");
  });

  it("accepts product-scope events and the largest allowed body", async () => {
    expect((await run(request({ raw: body({ event_type: "api_token.expired", data: {} }) }))).statusCode).toBe(204);
    const padded = body({ padding: "" });
    const big = body({ padding: "x".repeat(MAX_BODY_BYTES - padded.length) });
    expect(big.length).toBe(MAX_BODY_BYTES);
    expect((await run(request({ raw: big }))).statusCode).toBe(204);
  });
});

describe("linq afar edge: rejections", () => {
  it("405 for anything but POST", async () => {
    const res = await run(request({ method: "GET" }));
    expect(res.statusCode).toBe(405);
    expect(res.headers.get("allow")).toBe("POST");
  });

  it("415 for a missing, duplicated or non-JSON content type", async () => {
    expect((await run(request({ contentType: null }))).statusCode).toBe(415);
    expect((await run(request({ contentType: "text/plain" }))).statusCode).toBe(415);
    expect((await run(request({ contentType: "application/json; charset=latin1" }))).statusCode).toBe(415);
    expect((await run(request({ extraHeaders: ["content-type", "application/json"] }))).statusCode).toBe(415);
    expect((await run(request({ contentType: "application/json; charset=UTF-8" }))).statusCode).toBe(204);
  });

  it("413 above 64 KiB by body or declared length", async () => {
    expect((await run(request({ raw: Buffer.alloc(MAX_BODY_BYTES + 1, 0x20) }))).statusCode).toBe(413);
    expect((await run(request({ extraHeaders: ["content-length", String(MAX_BODY_BYTES + 1)] }))).statusCode).toBe(413);
  });

  it("503 with Retry-After and no publish while configuration is unavailable", async () => {
    const publisher = published();
    const res = await run(request(), publisher, unavailableLinqAfarEdgeConfig);
    expect(res.statusCode).toBe(503);
    expect(res.headers.get("retry-after")).toBe("5");
    expect(publisher).not.toHaveBeenCalled();
  });

  it("400 for missing, duplicated or malformed headers and an empty body", async () => {
    expect((await run({ ...request(), rawHeaders: ["content-type", "application/json"] })).statusCode).toBe(400);
    expect((await run(request({ extraHeaders: ["Webhook-Signature", "v1,AAAA"] }))).statusCode).toBe(400);
    expect((await run(request({ id: "msg 1" }))).statusCode).toBe(400);
    expect((await run(request({ raw: Buffer.alloc(0) }))).statusCode).toBe(400);
  });

  it("401 for a tampered body, a wrong signature and a stale or future timestamp", async () => {
    const good = request();
    const tampered = { ...good, rawBody: body({ event_id: "evt_2" }) };
    expect((await run(tampered)).statusCode).toBe(401);
    expect((await run(request({ signature: `v1,${Buffer.alloc(32).toString("base64")}` }))).statusCode).toBe(401);
    expect((await run(request({ timestamp: NOW_S - 301 }))).statusCode).toBe(401);
    expect((await run(request({ timestamp: NOW_S + 301 }))).statusCode).toBe(401);
    expect((await run(request({ timestamp: NOW_S - 300 }))).statusCode).toBe(204);
  });

  it("400 for authentic but unsupported or malformed events", async () => {
    expect((await run(request({ raw: body({ event_type: "message.deleted" }) }))).statusCode).toBe(400);
    expect((await run(request({ raw: body({ webhook_version: "2025-01-01" }) }))).statusCode).toBe(400);
    expect((await run(request({ raw: Buffer.from("not json") }))).statusCode).toBe(400);
  });

  it("403 for an authentic event on a line outside the binding", async () => {
    const publisher = published();
    const res = await run(request({ raw: body({ data: { chat: { owner_handle: { handle: "+14155550199" } } } }) }), publisher);
    expect(res.statusCode).toBe(403);
    expect(publisher).not.toHaveBeenCalled();
  });
});

describe("linq afar edge: publish outcomes never fake success", () => {
  const failures: PublishOutcome[] = [
    { kind: "failed", failure: "uncertain", detail: "network" },
    { kind: "failed", failure: "rejected", detail: "403" },
    { kind: "failed", failure: "invalid-response", detail: "no id" },
  ];
  it.each(failures)("503 when the publisher reports $failure", async (outcome) => {
    const res = await run(request(), async () => outcome);
    expect(res.statusCode).toBe(503);
    expect(res.headers.get("retry-after")).toBe("5");
  });

  it("503 when the publisher throws", async () => {
    const res = await run(request(), async () => {
      throw new Error("boom");
    });
    expect(res.statusCode).toBe(503);
  });

  it("requires exactly one non-empty message id", () => {
    expect(singleMessageId(["m-1"])).toBe("m-1");
    expect(singleMessageId([])).toBeNull();
    expect(singleMessageId(["a", "b"])).toBeNull();
    expect(singleMessageId([""])).toBeNull();
    expect(singleMessageId([1])).toBeNull();
    expect(singleMessageId(undefined)).toBeNull();
  });
});

describe("linq afar edge: deadline and admission", () => {
  it("answers 503 at the deadline, aborts, and holds the permit until the publish settles", async () => {
    vi.useFakeTimers();
    let settle: ((outcome: PublishOutcome) => void) | undefined;
    let observedSignal: AbortSignal | undefined;
    const publisher: LinqAfarQueuePublisher = (_message, signal) => {
      observedSignal = signal;
      return new Promise((resolveOutcome) => {
        settle = resolveOutcome;
      });
    };
    const admission = new AdmissionGate(4);
    const res = new FakeResponse();
    let finished = false;
    const pending = createLinqAfarEdgeHandler({ configSource: () => CONFIG, publisher, clock, admission, deadlineMs: 9_000 })(request(), res).then(() => {
      finished = true;
    });

    await vi.advanceTimersByTimeAsync(8_999);
    expect(res.ended).toBe(false);
    await vi.advanceTimersByTimeAsync(1);
    expect(res.statusCode).toBe(503);
    expect(observedSignal?.aborted).toBe(true);
    expect(admission.inFlight).toBe(1);
    expect(finished).toBe(false);

    settle?.({ kind: "failed", failure: "aborted", detail: "aborted" });
    await pending;
    expect(finished).toBe(true);
    expect(admission.inFlight).toBe(0);
  });

  it("counts the deadline from handler entry, not from the publish call", async () => {
    // Entry reads NOW_MS; every later reading is 9 s on, as if verification had used the budget.
    let readings = 0;
    const slowClock = { nowMs: () => (readings++ === 0 ? NOW_MS : NOW_MS + 9_000) };
    const publisher = published();
    const res = new FakeResponse();
    await createLinqAfarEdgeHandler({ configSource: () => CONFIG, publisher, clock: slowClock, deadlineMs: 9_000 })(request(), res);
    expect(res.statusCode).toBe(503);
    expect(publisher).not.toHaveBeenCalled();
  });

  it("503 without publishing when admission is full", async () => {
    const admission = new AdmissionGate(1);
    const hold = admission.tryAcquire();
    const publisher = published();
    const res = new FakeResponse();
    await createLinqAfarEdgeHandler({ configSource: () => CONFIG, publisher, clock, admission })(request(), res);
    expect(res.statusCode).toBe(503);
    expect(publisher).not.toHaveBeenCalled();
    hold?.();
    expect(admission.inFlight).toBe(0);
  });

  it("declares admission ceilings matching the contract", () => {
    expect(EDGE_INSTANCE_LIMITS).toEqual({ minInstances: 0, maxInstances: 1, concurrency: 4 });
    expect(() => new AdmissionGate(0)).toThrow(RangeError);
  });
});

describe("googleapis publisher", () => {
  beforeEach(() => publishCall.mockReset());

  it("loads googleapis lazily and publishes base64 raw data with retries off and the caller's signal", async () => {
    const before = googleapisLoads;
    const publish = createGoogleapisAfarPublisher();
    expect(googleapisLoads).toBe(before);
    publishCall.mockResolvedValue({ data: { messageIds: ["m-9"] } });
    const controller = new AbortController();
    const attributes = {
      "webhook-id": "msg_1",
      "webhook-timestamp": "1",
      "webhook-signature": "v1,AAAA",
      "edge-contract": "linq-afar-edge/1",
      "edge-received-at": "2026-10-17T01:20:01.000Z",
    };
    const outcome = await publish({ topic: "projects/p-test1/topics/t-1", data: Buffer.from("{}"), attributes }, controller.signal);
    expect(outcome).toEqual({ kind: "published", messageId: "m-9" });
    expect(publishCall).toHaveBeenCalledWith(
      { topic: "projects/p-test1/topics/t-1", requestBody: { messages: [{ data: Buffer.from("{}").toString("base64"), attributes }] } },
      { signal: controller.signal, retry: false },
    );
  });

  it("reports invalid responses, client rejections and aborts without throwing", async () => {
    const publish = createGoogleapisAfarPublisher();
    const message: QueueMessage = {
      topic: "projects/p-test1/topics/t-1",
      data: Buffer.from("{}"),
      attributes: {
        "webhook-id": "a",
        "webhook-timestamp": "1",
        "webhook-signature": "v1,AAAA",
        "edge-contract": "linq-afar-edge/1",
        "edge-received-at": "2026-10-17T01:20:01.000Z",
      },
    };
    publishCall.mockResolvedValueOnce({ data: { messageIds: ["a", "b"] } });
    expect(await publish(message, new AbortController().signal)).toMatchObject({ failure: "invalid-response" });
    publishCall.mockRejectedValueOnce(Object.assign(new Error("denied"), { status: 403 }));
    expect(await publish(message, new AbortController().signal)).toMatchObject({ failure: "rejected" });
    publishCall.mockRejectedValueOnce(Object.assign(new Error("busy"), { status: 503 }));
    expect(await publish(message, new AbortController().signal)).toMatchObject({ failure: "uncertain" });
    const aborted = new AbortController();
    aborted.abort();
    expect(await publish(message, aborted.signal)).toMatchObject({ failure: "aborted" });
  });

  it("treats 408 and 429 as uncertain, not rejected", () => {
    const signal = new AbortController().signal;
    expect(classifyPublishError({ status: 408 }, signal)).toMatchObject({ failure: "uncertain" });
    expect(classifyPublishError({ status: 429 }, signal)).toMatchObject({ failure: "uncertain" });
  });
});

describe("linq afar edge: activation stays off", () => {
  const repo = resolve(__dirname, "../../..");
  it("is not exported as a Cloud Function and has no Hosting rewrite", () => {
    expect(readFileSync(resolve(repo, "functions/src/index.ts"), "utf8")).not.toMatch(/linq/i);
    expect(readFileSync(resolve(repo, "firebase.json"), "utf8")).not.toMatch(/\/linq\//);
  });
});
