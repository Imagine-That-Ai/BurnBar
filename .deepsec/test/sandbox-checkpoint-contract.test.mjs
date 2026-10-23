import assert from "node:assert/strict";
import crypto from "node:crypto";
import fs from "node:fs";
import { createRequire } from "node:module";
import os from "node:os";
import path from "node:path";
import test from "node:test";
import { pathToFileURL } from "node:url";
import vm from "node:vm";

const require = createRequire(import.meta.url);
// Read the patched functions without executing the CLI or loading an account.
const cliPath = require.resolve("deepsec");
const source = fs.readFileSync(cliPath, "utf8");
const sdkRequire = createRequire(pathToFileURL(cliPath));
const sdkPackage = sdkRequire.resolve("@vercel/sandbox/package.json");
const { Sandbox } = await import(pathToFileURL(path.join(path.dirname(sdkPackage), "dist/index.js")));
assert.equal(JSON.parse(fs.readFileSync(sdkPackage, "utf8")).version, "2.9.2");
globalThis.fetch = async () => { throw new Error("Unmocked provider request refused"); };

function bundledFunction(name) {
  const match = source.match(new RegExp(`^(?:async )?function ${name}\\([^\\n]*\\) \\{[\\s\\S]*?^\\}`, "m"));
  assert.ok(match, `Missing patched CLI function ${name}`);
  return match[0];
}

const names = ["assertNamedSandboxRunState", "runsDir2", "runPath", "generateRunId2", "saveRunState", "loadRunState", "deleteRunState", "listRunStates", "launch", "getCheckpointSandbox", "checkStatus", "collect"];
const constants = ["SANDBOX_RUN_CHECKPOINT_VERSION", "SANDBOX_RUN_IDENTITY_KIND", "RUNS_DIR"].map((name) => {
  const match = source.match(new RegExp(`^var ${name} = [^;]+;`, "m"));
  assert.ok(match, `Missing patched CLI constant ${name}`);
  return match[0];
});
const credentials = { token: "synthetic-test-only", teamId: "team_fixture", projectId: "prj_fixture" };
const session = { id: "sbx_fixture", memory: 4096, vcpus: 2, region: "iad1", runtime: "node24", timeout: 300000, status: "running", requestedAt: 1, createdAt: 1, cwd: "/vercel/sandbox", updatedAt: 1 };
const sandboxMetadata = { name: "fixture-named-sandbox", persistent: false, currentSessionId: session.id, status: "running", createdAt: 1, updatedAt: 1 };

function harness(t, { changedSession = false, unavailable = false } = {}) {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), "deepsec-checkpoint-"));
  t.after(() => fs.rmSync(root, { recursive: true, force: true }));
  const calls = { sdkGet: [], requests: [], writes: [], downloads: 0, logs: [] };
  const metadata = changedSession ? { ...sandboxMetadata, currentSessionId: "sbx_different" } : sandboxMetadata;
  const currentSession = changedSession ? { ...session, id: "sbx_different" } : session;
  const reply = (body, status = 200) => new Response(JSON.stringify(body), { status, headers: { "content-type": "application/json" } });
  const fixtureFetch = async (input, options) => {
    const url = new URL(typeof input === "string" ? input : input.url ?? input.toString());
    const method = options?.method ?? "GET";
    calls.requests.push({ path: url.pathname, method, query: Object.fromEntries(url.searchParams), body: options?.body ? JSON.parse(options.body) : undefined });
    if (unavailable) return reply({ error: { code: "not_found", message: "Synthetic unavailable sandbox" } }, 404);
    if (url.pathname === "/api/v2/sandboxes" || url.pathname === `/api/v2/sandboxes/${metadata.name}`) return reply({ sandbox: metadata, session: currentSession, routes: [] });
    if (url.pathname === `/api/v2/sandboxes/sessions/${session.id}/cmd/cmd_fixture`) return reply({ command: { id: "cmd_fixture", name: "node", args: [], cwd: session.cwd, sessionId: session.id, exitCode: 0, startedAt: 1 } });
    if (url.pathname === `/api/v2/sandboxes/sessions/${session.id}/stop`) return reply({ session: { ...session, status: "stopped" } });
    return reply({ error: { code: "not_found", message: "Unexpected synthetic route" } }, 404);
  };
  const checkedFs = new Proxy(fs, { get(target, property) {
    if (["mkdirSync", "openSync", "writeFileSync", "unlinkSync"].includes(property)) return (...args) => { calls.writes.push(property); return target[property](...args); };
    return target[property];
  } });
  let launchSandbox;
  const globals = {
    fs23: checkedFs, path28: path, crypto6: crypto, Error, console,
    dataDir: (projectId) => path.join(root, projectId),
    Sandbox2: { get: async (params) => { calls.sdkGet.push(params); return Sandbox.get({ ...params, ...credentials, fetch: fixtureFetch }); } },
    downloadResults: async () => { calls.downloads++; return 1; },
    untrackSandbox: () => {},
    bootstrapAndSpawn: async () => ({ instances: [{ sandbox: launchSandbox, sandboxId: launchSandbox.currentSession().sessionId, index: 0, manifest: ["fixture.ts"], status: "setup" }], mode: "installed" }),
    dispatchOnSandbox: async () => "cmd_fixture",
  };
  const api = vm.runInNewContext([...constants, ...names.map(bundledFunction), "({saveRunState,loadRunState,launch,checkStatus,collect})"].join("\n"), globals, { timeout: 1000 });
  const file = (runId) => path.join(root, "fixture-project", "sandbox-runs", `${runId}.json`);
  const seed = (state, runId = "fixture-run") => { fs.mkdirSync(path.dirname(file(runId)), { recursive: true }); fs.writeFileSync(file(runId), JSON.stringify(state, null, 2) + "\n"); return file(runId); };
  const log = (message) => calls.logs.push(message);
  const create = async () => { launchSandbox = await Sandbox.create({ ...credentials, fetch: fixtureFetch, runtime: "node24", resources: { vcpus: 2 }, timeout: 300000 }); return launchSandbox; };
  return { api, calls, file, seed, log, create };
}

function namedState() {
  return { schemaVersion: 2, sandboxIdentity: "vercel-named-sandbox", runId: "fixture-run", projectId: "fixture-project", command: "process", vcpus: 2, launchedAt: "2026-10-23T00:00:00Z", sandboxes: [{ sandboxName: sandboxMetadata.name, sessionId: session.id, cmdId: "cmd_fixture", index: 0, manifest: ["fixture.ts"] }] };
}

for (const operation of ["checkStatus", "collect"]) {
  test(`${operation}: legacy session checkpoint is preserved with zero requests or writes`, { timeout: 5000 }, async (t) => {
    const h = harness(t);
    const state = namedState(); delete state.schemaVersion; delete state.sandboxIdentity;
    state.sandboxes = [{ sandboxId: session.id, cmdId: "cmd_fixture", index: 0, manifest: ["fixture.ts"] }];
    const file = h.seed(state); const before = fs.readFileSync(file); const stat = fs.statSync(file);
    await assert.rejects(h.api[operation]("fixture-project", "fixture-run", h.log), /DEEPSEC_UNSUPPORTED_LEGACY_CHECKPOINT.*Saved state is unchanged/);
    assert.deepEqual(h.calls.sdkGet, []); assert.deepEqual(h.calls.requests, []); assert.deepEqual(h.calls.writes, []); assert.equal(h.calls.downloads, 0);
    assert.deepEqual(fs.readFileSync(file), before); assert.equal(fs.statSync(file).mtimeMs, stat.mtimeMs);
  });
}

test("all checkpoint entries are validated before the first provider request", async (t) => {
  const h = harness(t); const state = namedState(); state.sandboxes.push({ sandboxId: "sbx_legacy", cmdId: "cmd_fixture", index: 1, manifest: [] });
  const file = h.seed(state); const before = fs.readFileSync(file);
  await assert.rejects(h.api.collect("fixture-project", "fixture-run", h.log), /DEEPSEC_INVALID_SANDBOX_CHECKPOINT/);
  assert.deepEqual(h.calls.requests, []); assert.deepEqual(h.calls.sdkGet, []); assert.deepEqual(h.calls.writes, []); assert.deepEqual(fs.readFileSync(file), before);
});

for (const mutation of [
  (state) => { state.schemaVersion = 3; },
  (state) => { state.sandboxIdentity = "session-id"; },
  (state) => { state.sandboxes[0].sandboxName = ""; },
  (state) => { delete state.sandboxes[0].sessionId; },
  (state) => { state.sandboxes[0].cmdId = null; },
]) {
  test(`invalid checkpoint is rejected before provider access: ${mutation.toString()}`, async (t) => {
    const h = harness(t); const state = namedState(); mutation(state); const file = h.seed(state); const before = fs.readFileSync(file);
    await assert.rejects(h.api.collect("fixture-project", "fixture-run", h.log), /DEEPSEC_(UNSUPPORTED|INVALID)_SANDBOX_CHECKPOINT/);
    assert.deepEqual(h.calls.sdkGet, []); assert.deepEqual(h.calls.requests, []); assert.deepEqual(h.calls.writes, []); assert.deepEqual(fs.readFileSync(file), before);
  });
}

test("launch saves a versioned, typed name and a distinct session ID", async (t) => {
  const h = harness(t); await h.create();
  const runId = await h.api.launch({ projectId: "fixture-project", command: "process", vcpus: 2 }, h.log);
  const state = JSON.parse(fs.readFileSync(h.file(runId), "utf8"));
  assert.equal(state.schemaVersion, 2); assert.equal(state.sandboxIdentity, "vercel-named-sandbox");
  assert.deepEqual(state.sandboxes, namedState().sandboxes); assert.equal("sandboxId" in state.sandboxes[0], false);
  assert.notEqual(state.sandboxes[0].sandboxName, state.sandboxes[0].sessionId);
});

test("the real SDK preserves the session ID for cleanup logging after stop", async (t) => {
  const h = harness(t); const sandbox = await h.create();
  await sandbox.stop();
  assert.equal(sandbox.currentSession().sessionId, session.id);
  assert.equal(h.calls.requests.filter((request) => request.path.endsWith("/stop")).length, 1);
});

test("new checkpoint status roundtrips through the real SDK without rewriting state", async (t) => {
  const h = harness(t); const file = h.seed(namedState()); const before = fs.readFileSync(file);
  await h.api.checkStatus("fixture-project", "fixture-run", h.log);
  assert.equal(h.calls.sdkGet[0].name, sandboxMetadata.name); assert.equal(h.calls.sdkGet[0].resume, false);
  assert.equal(h.calls.requests[0].query.resume, "false"); assert.ok(h.calls.logs.some((line) => line.includes("COMPLETE (exit 0")));
  assert.deepEqual(h.calls.writes, []); assert.deepEqual(fs.readFileSync(file), before);
});

test("successful new collect keeps result session-ID semantics and removes only its checkpoint", async (t) => {
  const h = harness(t); const file = h.seed(namedState());
  const results = await h.api.collect("fixture-project", "fixture-run", h.log);
  assert.equal(results[0].success, true); assert.equal(results[0].sandboxId, session.id); assert.equal(results[0].filesProcessed, 1);
  assert.equal(h.calls.downloads, 1); assert.equal(fs.existsSync(file), false); assert.deepEqual(h.calls.writes, ["unlinkSync"]);
  assert.equal(h.calls.requests.filter((request) => request.path.endsWith("/stop")).length, 1);
});

test("a name pointing to another session cannot fetch commands, download, stop, or delete state", async (t) => {
  const h = harness(t, { changedSession: true }); const file = h.seed(namedState()); const before = fs.readFileSync(file);
  const results = await h.api.collect("fixture-project", "fixture-run", h.log);
  assert.equal(results[0].success, false); assert.match(results[0].error, /DEEPSEC_SANDBOX_SESSION_MISMATCH/);
  assert.equal(h.calls.requests.length, 1); assert.equal(h.calls.downloads, 0); assert.deepEqual(h.calls.writes, []); assert.deepEqual(fs.readFileSync(file), before);
});

test("provider lookup failure preserves a new checkpoint for recovery", async (t) => {
  const h = harness(t, { unavailable: true }); const file = h.seed(namedState()); const before = fs.readFileSync(file);
  const results = await h.api.collect("fixture-project", "fixture-run", h.log);
  assert.equal(results[0].success, false); assert.equal(h.calls.downloads, 0); assert.deepEqual(h.calls.writes, []); assert.deepEqual(fs.readFileSync(file), before);
});

test("invalid legacy state cannot be saved or cause directory creation", (t) => {
  const h = harness(t); const legacy = namedState(); delete legacy.schemaVersion;
  assert.throws(() => h.api.saveRunState(legacy), /DEEPSEC_UNSUPPORTED_LEGACY_CHECKPOINT/);
  assert.deepEqual(h.calls.writes, []); assert.equal(fs.existsSync(h.file(legacy.runId)), false);
});
