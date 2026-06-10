/**
 * latestRouterRundown — public-endpoint cost hardening (crosscut-012).
 *
 * The endpoint is unauthenticated by design (public rundown JSON for the
 * website), so the spend controls are: a bounded module-scope response cache
 * (short TTL for the mutable `latest`/today keys, long for immutable past
 * dates, negative-cached 404s), calendar-range date validation (the bare
 * \d{4}-\d{2}-\d{2} regex admits an unbounded key space like 9999-99-99 that
 * would defeat any cache while still costing a Firestore read per key), and a
 * required maxInstances cap on the function itself.
 *
 * These drive the real onRequest handler against a read-counting Firestore
 * double; every assertion on `firestoreReads` is the cost being bounded.
 */
import { EventEmitter } from "node:events";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

vi.mock("firebase-functions/logger", () => ({
  info: vi.fn(),
  error: vi.fn(),
  warn: vi.fn(),
  debug: vi.fn(),
}));

const stored = new Map<string, Record<string, unknown>>();
let firestoreReads = 0;

vi.mock("firebase-admin/firestore", () => ({
  getFirestore: () => ({
    doc: (path: string) => ({
      get: async () => {
        firestoreReads += 1;
        return { exists: stored.has(path), data: () => stored.get(path) };
      },
    }),
  }),
}));

// An Express/Node-response double sufficient for the firebase-functions
// onRequest wrapper: the cors middleware (cors:true) reads/sets headers and
// the wrapper resolves on the "finish" event, emitted once the body is written.
class FakeRes extends EventEmitter {
  _status = 0;
  _body: unknown = undefined;
  private _headers: Record<string, string> = {};
  status(code: number): this {
    this._status = code;
    return this;
  }
  json(body: unknown): void {
    this._body = body;
    this.emit("finish");
  }
  send(body?: unknown): void {
    if (body !== undefined) this._body = body;
    this.emit("finish");
  }
  end(): void {
    this.emit("finish");
  }
  set(name: string, value: string): void {
    this._headers[name.toLowerCase()] = value;
  }
  setHeader(name: string, value: string): void {
    this._headers[name.toLowerCase()] = value;
  }
  getHeader(name: string): string | undefined {
    return this._headers[name.toLowerCase()];
  }
}

function getRequest(query: Record<string, string> = {}) {
  const headers: Record<string, string> = {};
  return {
    method: "GET",
    path: "/latestRouterRundown",
    url: "/latestRouterRundown",
    body: undefined,
    query,
    headers,
    socket: { remoteAddress: "127.0.0.1" },
    get(_name: string): string | undefined {
      return undefined;
    },
  };
}

async function runHttpHandler(handler: unknown, req: ReturnType<typeof getRequest>, res: FakeRes): Promise<void> {
  const run = Reflect.get(Object(handler), "run");
  const callable = typeof run === "function" ? run : handler;
  if (typeof callable !== "function") {
    throw new Error("Expected HTTP handler to be callable");
  }
  await callable(req, res);
}

async function loadEndpoint() {
  const { latestRouterRundown } = await import("../routerRundown.js");
  return latestRouterRundown;
}

async function get(handler: unknown, query: Record<string, string> = {}): Promise<FakeRes> {
  const res = new FakeRes();
  await runHttpHandler(handler, getRequest(query), res);
  return res;
}

// Fixed UTC "today" so the plausibility window is deterministic.
const NOW = new Date("2026-06-09T12:00:00Z");
const LATEST_RUNDOWN = { schemaVersion: 1, date: "2026-06-09", models: [] };

describe("latestRouterRundown cost hardening", () => {
  beforeEach(() => {
    // Fresh module per test so the module-scope cache starts empty.
    vi.resetModules();
    stored.clear();
    firestoreReads = 0;
    vi.useFakeTimers();
    vi.setSystemTime(NOW);
  });

  afterEach(() => {
    vi.useRealTimers();
    vi.clearAllMocks();
  });

  it("serves repeat hits for latest from the in-memory cache (single Firestore read)", async () => {
    stored.set("router_rundowns/latest", LATEST_RUNDOWN);
    const handler = await loadEndpoint();

    const first = await get(handler);
    expect(first._status).toBe(200);
    expect(first._body).toEqual(LATEST_RUNDOWN);
    expect(first.getHeader("cache-control")).toBe("public, max-age=300, s-maxage=300");
    expect(firestoreReads).toBe(1);

    const second = await get(handler);
    expect(second._status).toBe(200);
    expect(second._body).toEqual(LATEST_RUNDOWN);
    expect(second.getHeader("cache-control")).toBe("public, max-age=300, s-maxage=300");
    expect(firestoreReads).toBe(1);
  });

  it("refetches latest after the mutable 60s TTL (scheduled runs overwrite it)", async () => {
    stored.set("router_rundowns/latest", LATEST_RUNDOWN);
    const handler = await loadEndpoint();

    await get(handler);
    expect(firestoreReads).toBe(1);

    vi.setSystemTime(new Date(NOW.getTime() + 61_000));
    const res = await get(handler);
    expect(res._status).toBe(200);
    expect(firestoreReads).toBe(2);
  });

  it("keeps immutable past dates cached well beyond the mutable TTL", async () => {
    stored.set("router_rundowns/2026-05-13", { schemaVersion: 1, date: "2026-05-13" });
    const handler = await loadEndpoint();

    await get(handler, { date: "2026-05-13" });
    expect(firestoreReads).toBe(1);

    vi.setSystemTime(new Date(NOW.getTime() + 60 * 60 * 1000));
    const res = await get(handler, { date: "2026-05-13" });
    expect(res._status).toBe(200);
    expect(firestoreReads).toBe(1);
  });

  it("404s regex-shaped but implausible dates with ZERO Firestore reads", async () => {
    const handler = await loadEndpoint();

    for (const date of [
      "9999-99-99", // not a calendar date — the key-space amplification vector
      "2026-02-30", // calendar-invalid
      "2024-12-31", // before any rundown existed
      "2026-06-11", // two days past server "today" — cannot have been written
    ]) {
      const res = await get(handler, { date });
      expect(res._status, date).toBe(404);
      expect(res._body).toEqual({ error: "not_found", date });
    }
    expect(firestoreReads).toBe(0);
  });

  it("negative-caches 404s for plausible-but-missing dates", async () => {
    const handler = await loadEndpoint();

    const first = await get(handler, { date: "2026-06-01" });
    expect(first._status).toBe(404);
    expect(firestoreReads).toBe(1);

    const second = await get(handler, { date: "2026-06-01" });
    expect(second._status).toBe(404);
    expect(firestoreReads).toBe(1);

    vi.setSystemTime(new Date(NOW.getTime() + 61_000));
    await get(handler, { date: "2026-06-01" });
    expect(firestoreReads).toBe(2);
  });

  it("bounds the cache: oldest entry is evicted, newest stays cached", async () => {
    const handler = await loadEndpoint();

    // 65 distinct plausible dates overflow the 64-entry cache by one.
    const dates: string[] = [];
    for (let i = 0; i < 65; i += 1) {
      const day = new Date(Date.UTC(2026, 0, 1) + i * 24 * 60 * 60 * 1000);
      dates.push(day.toISOString().slice(0, 10));
    }
    for (const date of dates) {
      stored.set(`router_rundowns/${date}`, { schemaVersion: 1, date });
      await get(handler, { date });
    }
    expect(firestoreReads).toBe(65);

    // Newest entry is still cached; the oldest was evicted and re-reads.
    await get(handler, { date: dates[64] });
    expect(firestoreReads).toBe(65);
    await get(handler, { date: dates[0] });
    expect(firestoreReads).toBe(66);
  });

  it("declares a required maxInstances cap on invocation spend", async () => {
    const handler = (await loadEndpoint()) as { __endpoint?: { maxInstances?: number } };
    expect(handler.__endpoint?.maxInstances).toBe(10);
  });
});
