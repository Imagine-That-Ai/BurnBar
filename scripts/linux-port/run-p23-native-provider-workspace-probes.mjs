#!/usr/bin/env node
import crypto from "node:crypto";
import fs from "node:fs";
import net from "node:net";
import path from "node:path";
import { spawn, spawnSync } from "node:child_process";
import { fileURLToPath } from "node:url";
import { verifyInstalledCandidate } from "./run-p08-mercury-media-session.mjs";

const ROOT = path.resolve(
  path.dirname(fileURLToPath(import.meta.url)),
  "../..",
);
const DESKTOP = "/usr/bin/openburnbar-linux-desktop";
const CONTROL = path.join(ROOT, "scripts/linux-port/p23-atspi-control.py");
const SUCCESS = new Set(["exact", "same_model_failover"]);
const TERMINAL_PHASES = new Set(["completed", "failed", "cancelled"]);
const FOUNDATION_REFERENCE_EPOCH_MS = Date.UTC(2001, 0, 1);

function assert(value, message) {
  if (!value) throw new Error(message);
}
function sleep(ms) {
  return new Promise((resolve) => setTimeout(resolve, ms));
}
function clone(value) {
  return structuredClone(value);
}
function writeExclusive(file, value) {
  const fd = fs.openSync(
    file,
    fs.constants.O_WRONLY | fs.constants.O_CREAT | fs.constants.O_EXCL,
    0o600,
  );
  try {
    fs.writeFileSync(fd, value);
    fs.fsyncSync(fd);
  } finally {
    fs.closeSync(fd);
  }
}
function writeJson(file, value) {
  writeExclusive(file, Buffer.from(`${JSON.stringify(value, null, 2)}\n`));
}
function privateDirectory(directory, label) {
  fs.mkdirSync(directory, { recursive: true, mode: 0o700 });
  const stat = fs.lstatSync(directory);
  assert(
    stat.isDirectory() &&
      !stat.isSymbolicLink() &&
      stat.uid === process.getuid?.() &&
      (stat.mode & 0o077) === 0,
    `${label} must be owner-only`,
  );
  assert(fs.readdirSync(directory).length === 0, `${label} must be empty`);
  return fs.realpathSync(directory);
}
function readToken(file) {
  const fd = fs.openSync(file, fs.constants.O_RDONLY | fs.constants.O_NOFOLLOW);
  try {
    const stat = fs.fstatSync(fd);
    assert(
      stat.isFile() &&
        stat.uid === process.getuid?.() &&
        (stat.mode & 0o077) === 0,
      "P-23 daemon token must be owner-only",
    );
    const token = fs.readFileSync(fd, "utf8").trim();
    assert(
      token.length >= 32 && !/[\r\n]/u.test(token),
      "P-23 daemon token is invalid",
    );
    return token;
  } finally {
    fs.closeSync(fd);
  }
}
function commandRunner() {
  return {
    run(command, args = [], options = {}) {
      const result = spawnSync(command, args, {
        encoding: "utf8",
        timeout: 30_000,
        maxBuffer: 8 * 1024 * 1024,
        ...options,
      });
      if (result.error) throw result.error;
      return {
        status: result.status,
        stdout: result.stdout ?? "",
        stderr: result.stderr ?? "",
      };
    },
    start(command, args = [], options = {}) {
      const child = spawn(command, args, {
        stdio: ["ignore", "ignore", "ignore"],
        ...options,
      });
      child.unref();
      return { pid: child.pid, kill: () => child.kill() };
    },
  };
}
function required(runner, command, args, label, options = {}) {
  const result = runner.run(command, args, options);
  assert(
    result.status === 0,
    `${label} failed (${result.status}): ${(result.stderr || result.stdout).trim()}`,
  );
  return result.stdout.trim();
}
function installedDesktopPids(runner) {
  const result = runner.run("pgrep", [
    "-f",
    "^/usr/bin/openburnbar-linux-desktop([[:space:]]|$)",
  ]);
  if (result.status === 1) return [];
  assert(
    result.status === 0,
    `P-23 desktop preflight failed: ${(result.stderr || result.stdout).trim()}`,
  );
  return result.stdout
    .trim()
    .split(/\s+/u)
    .filter(Boolean)
    .map(Number)
    .filter(Number.isSafeInteger);
}
async function waitFor(label, operation, timeoutMs = 30_000) {
  const deadline = Date.now() + timeoutMs;
  let lastError;
  while (Date.now() < deadline) {
    try {
      return await operation();
    } catch (error) {
      lastError = error;
      await sleep(250);
    }
  }
  throw new Error(`${label} timed out: ${lastError?.message ?? "unavailable"}`);
}
function rpcClient(options, authToken) {
  let sequence = 0;
  return (method, params = {}) =>
    new Promise((resolve, reject) => {
      const socket = net.createConnection(options.socketPath);
      let buffer = "";
      let settled = false;
      const finish = (callback, value) => {
        if (!settled) {
          settled = true;
          socket.destroy();
          callback(value);
        }
      };
      socket.setEncoding("utf8");
      socket.setTimeout(180_000, () =>
        finish(reject, new Error(`P-23 RPC timed out: ${method}`)),
      );
      socket.on("error", (error) => finish(reject, error));
      socket.on("connect", () =>
        socket.write(
          `${JSON.stringify({ protocolVersion: 1, id: `p23-${++sequence}`, method, traceId: `p23-trace-${sequence}`, authToken, params })}\n`,
        ),
      );
      socket.on("data", (chunk) => {
        buffer += chunk;
        const newline = buffer.indexOf("\n");
        if (newline < 0) return;
        try {
          const document = JSON.parse(buffer.slice(0, newline));
          document.error
            ? finish(
                reject,
                new Error(
                  document.error.message ?? `P-23 RPC failed: ${method}`,
                ),
              )
            : finish(resolve, document.result);
        } catch (error) {
          finish(reject, error);
        }
      });
    });
}
function serviceController(runner, options) {
  return {
    async preflight() {
      const active = runner.run("systemctl", [
        "--user",
        "is-active",
        "--quiet",
        "openburnbar-daemon.service",
      ]);
      assert(
        active.status === 0,
        "P-23 requires the active installed user daemon service",
      );
      assert(
        fs.existsSync(options.socketPath) &&
          fs.lstatSync(options.socketPath).isSocket(),
        "P-23 installed daemon socket is absent",
      );
    },
    async restart() {
      required(
        runner,
        "systemctl",
        ["--user", "restart", "openburnbar-daemon.service"],
        "restart installed daemon",
      );
      await waitFor("P-23 daemon restart", () => {
        assert(
          fs.existsSync(options.socketPath) &&
            fs.lstatSync(options.socketPath).isSocket(),
          "daemon socket absent",
        );
        return true;
      });
    },
  };
}
function nextTime(clock) {
  const now = Math.max(Date.now(), clock.value + 1);
  clock.value = now;
  return new Date(now).toISOString();
}
function sanitizeEvidence(value) {
  const forbidden = new Set([
    "apiKey",
    "api_key",
    "apiKeyRef",
    "api_key_ref",
    "credential",
    "credentialRef",
    "passphrase",
    "secret",
    "secretRef",
    "token",
    "tokenRef",
  ]);
  const scrub = (value) => {
    if (Array.isArray(value)) return value.map(scrub);
    if (!value || typeof value !== "object") return value;
    return Object.fromEntries(
      Object.entries(value)
        .filter(([key]) => !forbidden.has(key))
        .map(([key, child]) => [key, scrub(child)]),
    );
  };
  return scrub(value);
}
function snapshotOf(result) {
  return result?.snapshot ?? result;
}
function catalogOf(result) {
  return result?.catalog ?? result;
}
function providerID(value) {
  return String(
    value?.providerID ?? value?.providerId ?? value?.id ?? "",
  ).trim();
}
function modelID(value) {
  return String(value?.id ?? value?.modelID ?? value?.modelId ?? "").trim();
}
function routeAccount(entry) {
  return String(entry?.accountID ?? entry?.accountId ?? "").trim();
}
function routeProvider(entry) {
  return String(entry?.providerID ?? entry?.providerId ?? "").trim();
}
function routeAt(entry) {
  const value = entry?.occurredAt;
  if (typeof value === "number" && Number.isFinite(value)) {
    return FOUNDATION_REFERENCE_EPOCH_MS + value * 1000;
  }
  return typeof value === "string" ? Date.parse(value) : Number.NaN;
}
function successfulRoute(entry) {
  return (
    SUCCESS.has(String(entry?.finalStatus ?? "")) &&
    Number(entry?.httpStatus ?? 200) < 400
  );
}
function configuredProvider(snapshot, id) {
  return (snapshot.providers ?? []).find(
    (provider) => providerID(provider) === id,
  );
}
function catalogProvider(catalog, id) {
  return (catalog.providers ?? []).find(
    (provider) => providerID(provider) === id,
  );
}
function replaceProvider(snapshot, provider) {
  return {
    ...snapshot,
    providers: (snapshot.providers ?? []).map((row) =>
      providerID(row) === providerID(provider) ? provider : row,
    ),
  };
}
function selectLiveTarget(snapshot, catalog) {
  for (const provider of snapshot.providers ?? []) {
    const id = providerID(provider);
    const canonical = catalogProvider(catalog, id);
    const slots = (provider.credentialSlots ?? []).filter(
      (slot) => slot.isEnabled !== false,
    );
    const models = canonical?.models ?? [];
    if (
      provider.isEnabled !== false &&
      slots.length >= 2 &&
      models.length > 0
    ) {
      return {
        provider,
        catalogProvider: canonical,
        slots: slots.slice(0, 2),
        model: models[0],
      };
    }
  }
  throw new Error(
    "P-23 requires one configured provider with two enabled native credential slots and a canonical model; no live credential/failover target is available",
  );
}
function normalizedSlot(slot, status, marker) {
  const now = foundationSeconds();
  return {
    ...slot,
    status,
    cooldownUntil: status === "coolingDown" ? now + 3_600 : null,
    lastQuotaRemainingPercent:
      status === "exhausted"
        ? 0
        : status === "ready"
          ? 100
          : (slot.lastQuotaRemainingPercent ?? null),
    lastQuotaResetsAt: status === "exhausted" ? now + 3_600 : null,
    lastStatusMessage: `P-23 ${status} ${marker}`,
    updatedAt: now,
  };
}
function updateProvider(snapshot, id, mutate) {
  const provider = configuredProvider(snapshot, id);
  assert(provider, `P-23 provider disappeared: ${id}`);
  return replaceProvider(snapshot, mutate(clone(provider)));
}
function rawDate() {
  return foundationSeconds();
}
function foundationSeconds(now = Date.now()) {
  return (now - FOUNDATION_REFERENCE_EPOCH_MS) / 1000;
}
function atspi(runner, output, suffix, mode, name = null, value = null) {
  const file = path.join(output, `.p23-atspi-${suffix}.json`);
  const args = [CONTROL, "--mode", mode, "--output", file];
  if (name) args.push("--name", name);
  if (value !== null) args.push("--value", value);
  required(runner, "python3", args, `P-23 AT-SPI ${suffix}`);
  const valueOut = JSON.parse(fs.readFileSync(file, "utf8"));
  fs.rmSync(file);
  return valueOut;
}
function names(tree) {
  return (tree.nodes ?? [])
    .map((node) => String(node.name ?? ""))
    .filter(Boolean);
}
function includes(tree, expected) {
  return names(tree).some((name) => name.includes(expected));
}
function focused(tree, expected) {
  return (tree.nodes ?? []).some(
    (node) =>
      String(node.name ?? "").includes(expected) &&
      (node.states ?? []).includes("focused"),
  );
}
function defaultUI(runner, options) {
  let app = null;
  const launch = async (uri) => {
    app = runner.start(DESKTOP, uri ? [uri] : []);
    assert(
      Number.isSafeInteger(app.pid) && app.pid > 1,
      "P-23 desktop returned no PID",
    );
    await waitFor("P-23 installed desktop", () => {
      const found = runner.run("xdotool", [
        "search",
        "--onlyvisible",
        "--pid",
        String(app.pid),
        "--name",
        "^OpenBurnBar",
      ]);
      assert(found.status === 0, "window absent");
      return true;
    });
    await sleep(1200);
    return { pid: app.pid };
  };
  return {
    launch,
    snapshot(label) {
      return atspi(runner, options.rawOutputDir, label, "snapshot");
    },
    async activate(name, label) {
      const result = atspi(
        runner,
        options.rawOutputDir,
        label,
        "activate",
        name,
      );
      await sleep(900);
      return result;
    },
    screenshot(name) {
      const file = path.join(options.rawOutputDir, name);
      required(
        runner,
        "scrot",
        ["--overwrite", "--focused", file],
        `P-23 ${name}`,
      );
      assert(fs.statSync(file).size > 1024, `P-23 ${name} empty`);
      return file;
    },
    async forward(uri) {
      const child = runner.start(DESKTOP, [uri]);
      await waitFor("P-23 forwarded process exit", () => {
        const alive = runner.run("kill", ["-0", String(child.pid)]);
        assert(alive.status !== 0, "forwarder alive");
        return true;
      });
      await sleep(900);
    },
    async stop() {
      if (!app) return;
      const pid = app.pid;
      app.kill();
      await waitFor(`P-23 desktop ${pid} exit`, () => {
        const alive = runner.run("kill", ["-0", String(pid)]);
        assert(alive.status !== 0, "desktop alive");
        return true;
      });
      app = null;
    },
  };
}

export async function runP23NativeProviderWorkspaceProbes(
  options,
  dependencies = {},
) {
  assert(
    (dependencies.platform ?? process.platform) === "linux",
    "P-23 native probe must execute on Linux",
  );
  assert(
    dependencies.desktopSession ??
      (process.env.DBUS_SESSION_BUS_ADDRESS &&
        (process.env.DISPLAY || process.env.WAYLAND_DISPLAY)),
    "P-23 requires a live desktop and D-Bus",
  );
  (dependencies.installedVerifier ?? verifyInstalledCandidate)(options);
  options.rawOutputDir = privateDirectory(
    options.rawOutputDir,
    "P-23 raw output",
  );
  const token = readToken(options.tokenFile);
  const runner = dependencies.runner ?? commandRunner();
  const pids = (
    dependencies.desktopProcessIDs ?? (() => installedDesktopPids(runner))
  )();
  assert(
    Array.isArray(pids) && pids.length === 0,
    "P-23 requires no pre-existing installed desktop",
  );
  if (!dependencies.ui)
    for (const tool of ["python3", "xdotool", "scrot"])
      required(
        runner,
        "sh",
        ["-c", 'command -v "$1" >/dev/null', "p23-tool", tool],
        `required tool ${tool}`,
      );
  const rpc = dependencies.rpc ?? rpcClient(options, token);
  const service = dependencies.service ?? serviceController(runner, options);
  const ui = dependencies.ui ?? defaultUI(runner, options);
  const marker =
    dependencies.marker ?? `p23-${crypto.randomBytes(8).toString("hex")}`;
  const clock = { value: 0 };
  const events = [];
  const uiEvents = [];
  const startedAt = Date.now();
  let original = null;
  let clientAttached = false;
  let app = null;
  let target;
  const call = async (phase, method, request = {}) => {
    try {
      const result = await rpc(method, request);
      events.push({
        phase,
        at: nextTime(clock),
        method,
        request: sanitizeEvidence(request),
        ok: true,
        error: null,
        result: sanitizeEvidence(result),
      });
      return result;
    } catch (error) {
      events.push({
        phase,
        at: nextTime(clock),
        method,
        request: sanitizeEvidence(request),
        ok: false,
        error: error.message,
        result: null,
      });
      throw error;
    }
  };
  const observe = (phase, observed) =>
    uiEvents.push({
      phase,
      at: nextTime(clock),
      appPid: app.pid,
      marker,
      manifestSha256: options.manifestSha256,
      observed,
    });
  const clientID = `p23-proof-${marker}`;
  const sessionID = `p23-session-${marker}`;
  const attach = async () => {
    await call("client-attach", "client.attach", {
      clientID,
      sessionID,
      clientName: "P-23 installed provider proof",
      supportedProtocolVersions: [1],
    });
    await call("client-claim", "client.claimControl", { clientID, sessionID });
    clientAttached = true;
  };
  const detach = async () => {
    if (clientAttached) {
      await rpc("client.detach", { clientID, sessionID });
      clientAttached = false;
    }
  };
  const routeRun = async (phase, expectedSlotID, after) => {
    const prompt = `Reply with exactly P23_OK_${marker}. Do not call tools.`;
    const created = await call(`${phase}-run`, "run.create", {
      clientID,
      sessionID,
      prompt,
      modelID: modelID(target.model),
      metadata: {},
    });
    assert(created.runID, `P-23 ${phase} run returned no ID`);
    await waitFor(
      `P-23 ${phase} run terminal`,
      async () => {
        const detail = await rpc("run.get", { runID: created.runID, clientID });
        const run = detail.run ?? detail;
        assert(TERMINAL_PHASES.has(run.phase), `run phase ${run.phase}`);
        assert(
          run.phase === "completed",
          `run failed: ${run.errorMessage ?? run.phase}`,
        );
        return run;
      },
      180_000,
    );
    const log = await waitFor(
      `P-23 ${phase} route log`,
      async () => {
        const recent = await rpc("daemon.proxy.route_log.recent", {
          limit: 200,
        });
        const entry = (recent.entries ?? []).find(
          (row) =>
            routeAt(row) > after &&
            routeProvider(row) === providerID(target.provider) &&
            routeAccount(row) === expectedSlotID &&
            successfulRoute(row),
        );
        assert(entry, `no successful ${expectedSlotID} route log`);
        return entry;
      },
      30_000,
    );
    events.push({
      phase: `${phase}-route`,
      at: nextTime(clock),
      method: "daemon.proxy.route_log.recent",
      request: { limit: 200 },
      ok: true,
      error: null,
      result: sanitizeEvidence(log),
    });
    return log;
  };
  try {
    await service.preflight();
    original = snapshotOf(
      await call("config-original", "daemon.config.get", {}),
    );
    const catalog = catalogOf(
      await call("catalog-original", "daemon.catalog", {}),
    );
    await call("quota-original", "daemon.quota.signals.recent", { limit: 200 });
    await call("route-log-baseline", "daemon.proxy.route_log.recent", {
      limit: 200,
    });
    target = selectLiveTarget(original, catalog);
    const id = providerID(target.provider);
    const base = modelID(target.model);
    const [slotA, slotB] = target.slots;
    const customModelID = `${base}-p23-${marker.slice(-8)}`;
    const aliasID = `p23-alias-${marker.slice(-8)}`;
    const variantID = `p23-variant-${marker.slice(-8)}`;
    await attach();
    let working = updateProvider(original, id, (provider) => ({
      ...provider,
      preferredCredentialSlotID: slotA.slotID,
      credentialSlots: provider.credentialSlots.map((slot) =>
        slot.slotID === slotA.slotID || slot.slotID === slotB.slotID
          ? normalizedSlot(slot, "ready", marker)
          : slot,
      ),
    }));
    working.routerMode = "same_model_failover";
    working = snapshotOf(
      await call("manual-a-config", "daemon.config.update", {
        snapshot: working,
      }),
    );
    const manualAAfter = Date.now() - 1;
    const manualA = await routeRun("manual-a", slotA.slotID, manualAAfter);
    working = updateProvider(working, id, (provider) => ({
      ...provider,
      preferredCredentialSlotID: slotB.slotID,
    }));
    working = snapshotOf(
      await call("manual-b-config", "daemon.config.update", {
        snapshot: working,
      }),
    );
    const manualBAfter = Date.now() - 1;
    const manualB = await routeRun("manual-b", slotB.slotID, manualBAfter);

    const now = rawDate();
    working = snapshotOf(
      await call("custom-upsert", "daemon.provider.custom_model.upsert", {
        providerID: id,
        customModel: {
          modelID: customModelID,
          displayName: `P23 custom ${marker}`,
          createdAt: now,
          updatedAt: now,
        },
      }),
    );
    working = snapshotOf(
      await call("alias-upsert", "daemon.provider.model_alias.upsert", {
        providerID: id,
        alias: {
          aliasID,
          baseModelID: base,
          displayName: `P23 alias ${marker}`,
          hidesBaseModel: false,
          createdAt: now,
          updatedAt: now,
        },
      }),
    );
    working = snapshotOf(
      await call("variant-upsert", "daemon.provider.model_variant.upsert", {
        providerID: id,
        variant: {
          variantID,
          label: `P23 High ${marker}`,
          baseModelID: base,
          thinkingLevel: "high",
          maxOutputTokens: 256,
          createdAt: now,
          updatedAt: now,
        },
      }),
    );
    working = updateProvider(working, id, (provider) => ({
      ...provider,
      preferredCredentialSlotID: slotA.slotID,
      credentialSlots: provider.credentialSlots.map((slot) =>
        slot.slotID === slotA.slotID
          ? normalizedSlot(slot, "exhausted", marker)
          : slot.slotID === slotB.slotID
            ? normalizedSlot(slot, "ready", marker)
            : slot,
      ),
    }));
    working.routerMode = "same_model_failover";
    working = snapshotOf(
      await call("automatic-drain-config", "daemon.config.update", {
        snapshot: working,
      }),
    );
    const autoAfter = Date.now() - 1;
    const automatic = await routeRun(
      "automatic-drain",
      slotB.slotID,
      autoAfter,
    );
    assert(
      routeAccount(automatic) !== slotA.slotID,
      "P-23 exhausted preferred slot was not drained",
    );
    await detach();

    await service.restart();
    const restartSnapshot = snapshotOf(
      await call("restart-config", "daemon.config.get", {}),
    );
    const restartProvider = configuredProvider(restartSnapshot, id);
    assert(
      restartProvider?.customModels?.some(
        (row) => row.modelID === customModelID,
      ) &&
        restartProvider?.modelAliases?.some((row) => row.aliasID === aliasID) &&
        restartProvider?.modelVariants?.some(
          (row) => row.variantID === variantID,
        ),
      "P-23 model lifecycle did not persist across daemon restart",
    );
    assert(
      restartProvider?.preferredCredentialSlotID === slotA.slotID &&
        restartSnapshot.routerMode === "same_model_failover",
      "P-23 routing policy did not persist across daemon restart",
    );

    const uri = `openburnbar://providers?provider=${encodeURIComponent(id)}`;
    app = await ui.launch(uri);
    const detailTree = ui.snapshot("detail");
    const detailObserved = {
      workspace: includes(detailTree, "Providers & models"),
      provider: includes(detailTree, id),
      health: includes(detailTree, "Healthy"),
      failover: includes(detailTree, "Eligible"),
      account: includes(detailTree, slotA.label),
      exhausted: includes(detailTree, "exhausted"),
    };
    assert(
      Object.values(detailObserved).every(Boolean),
      "P-23 provider detail/account/failover UI is incomplete",
    );
    observe("detail", detailObserved);
    ui.screenshot("provider-detail.png");
    await ui.forward(
      `openburnbar://providers?provider=${encodeURIComponent(id)}&model=${encodeURIComponent(customModelID)}`,
    );
    const modelTree = ui.snapshot("model-forward");
    const modelObserved = {
      custom: includes(modelTree, customModelID),
      alias: includes(modelTree, aliasID),
      variant: includes(modelTree, variantID),
      focused: focused(modelTree, customModelID),
    };
    assert(
      Object.values(modelObserved).every(Boolean),
      "P-23 deep-linked model lifecycle/focus UI is incomplete",
    );
    observe("model-deep-link", modelObserved);
    ui.screenshot("provider-model-deep-link.png");
    await ui.forward(
      `openburnbar://providers?provider=${encodeURIComponent(id)}&model=${encodeURIComponent(aliasID)}`,
    );
    const aliasTree = ui.snapshot("alias-forward");
    const deepObserved = {
      provider: includes(aliasTree, id),
      alias: includes(aliasTree, aliasID),
      focused: focused(aliasTree, aliasID),
    };
    assert(
      Object.values(deepObserved).every(Boolean),
      "P-23 single-instance alias deep link did not restore focus",
    );
    observe("deep-link-restoration", deepObserved);
    ui.screenshot("provider-deep-link-restored.png");

    working = updateProvider(restartSnapshot, id, (provider) => ({
      ...provider,
      credentialSlots: provider.credentialSlots.map((slot) =>
        [slotA.slotID, slotB.slotID].includes(slot.slotID)
          ? normalizedSlot(slot, "coolingDown", marker)
          : slot,
      ),
    }));
    working = snapshotOf(
      await call("degraded-config", "daemon.config.update", {
        snapshot: working,
      }),
    );
    await ui.activate("Refresh catalog", "degraded-refresh");
    const degradedTree = ui.snapshot("degraded");
    const degradedObserved = {
      degraded: includes(degradedTree, "Degraded"),
      unavailableFailover: includes(degradedTree, "Unavailable"),
      cooling: includes(degradedTree, "cooling"),
    };
    assert(
      Object.values(degradedObserved).every(Boolean),
      "P-23 degraded provider UI is incomplete",
    );
    observe("degraded", degradedObserved);
    ui.screenshot("provider-degraded.png");
    working = updateProvider(working, id, (provider) => ({
      ...provider,
      credentialSlots: provider.credentialSlots.map((slot) =>
        [slotA.slotID, slotB.slotID].includes(slot.slotID)
          ? normalizedSlot(slot, "missingSecret", marker)
          : slot,
      ),
    }));
    await call("unavailable-config", "daemon.config.update", {
      snapshot: working,
    });
    await ui.activate("Refresh catalog", "unavailable-refresh");
    const unavailableTree = ui.snapshot("unavailable");
    const unavailableObserved = {
      unavailable: includes(unavailableTree, "Unavailable"),
      missing: includes(unavailableTree, "missing"),
      routeUnavailable: includes(
        unavailableTree,
        "No verified credential route is available",
      ),
    };
    assert(
      Object.values(unavailableObserved).every(Boolean),
      "P-23 unavailable provider UI is incomplete",
    );
    observe("unavailable", unavailableObserved);
    ui.screenshot("provider-unavailable.png");
    await ui.stop();
    app = null;

    const expectedOriginal = original;
    await call("restore-config", "daemon.config.update", {
      snapshot: expectedOriginal,
    });
    await service.restart();
    const restoredOriginal = snapshotOf(
      await call("restore-restart-config", "daemon.config.get", {}),
    );
    assert(
      JSON.stringify(restoredOriginal) === JSON.stringify(expectedOriginal),
      "P-23 original provider configuration was not restored exactly",
    );
    original = null;

    const markerDocument = {
      marker,
      providerID: id,
      providerLabel:
        target.catalogProvider.displayName ??
        target.catalogProvider.label ??
        id,
      baseModelID: base,
      customModelID,
      aliasID,
      variantID,
      slotA: { slotID: slotA.slotID, label: slotA.label },
      slotB: { slotID: slotB.slotID, label: slotB.label },
      liveRouteEvidence: {
        manualA: manualA.id,
        manualB: manualB.id,
        automaticDrain: automatic.id,
      },
      safety: {
        credentialsRecorded: false,
        originalConfigRestored: true,
        controlledQuotaStateMutation: true,
        unsupportedLiveFailoverClaimed: false,
      },
    };
    writeJson(
      path.join(options.rawOutputDir, "provider-marker.json"),
      markerDocument,
    );
    writeJson(
      path.join(options.rawOutputDir, "provider-daemon-transcript.json"),
      {
        producer: "openburnbar-p23-installed-provider-daemon-probe-v1",
        transport: "installed daemon AF_UNIX RPC",
        startedAt: new Date(startedAt).toISOString(),
        events,
      },
    );
    writeJson(path.join(options.rawOutputDir, "provider-ui-transcript.json"), {
      producer: "openburnbar-p23-installed-provider-ui-probe-v1",
      events: uiEvents,
    });
    return { output: options.rawOutputDir, marker };
  } finally {
    try {
      if (app) await ui.stop();
    } catch {
      /* preserve primary failure */
    }
    try {
      await detach();
    } catch {
      /* preserve primary failure */
    }
    if (original) {
      try {
        await rpc("daemon.config.update", { snapshot: original });
        await service.restart();
        const restored = snapshotOf(await rpc("daemon.config.get", {}));
        assert(
          JSON.stringify(restored) === JSON.stringify(original),
          "P-23 failure cleanup did not restore the original config exactly",
        );
      } catch (error) {
        process.stderr.write(
          `P-23 CRITICAL: original provider config restoration failed: ${error.message}\n`,
        );
        throw error;
      }
    }
  }
}

export function parseP23Arguments(argv) {
  const flags = [
    "--raw-output-dir",
    "--socket-path",
    "--token-file",
    "--environment",
    "--target-head",
    "--candidate-run-id",
    "--candidate-artifact-digest",
    "--package-version",
    "--manifest-sha256",
    "--manifest-signature-sha256",
    "--compositor",
  ];
  const values = new Map();
  for (let index = 0; index < argv.length; index += 2) {
    if (
      !flags.includes(argv[index]) ||
      values.has(argv[index]) ||
      argv[index + 1] === undefined
    )
      throw new Error(`invalid argument: ${argv[index] ?? "<missing>"}`);
    values.set(argv[index], argv[index + 1]);
  }
  for (const flag of flags)
    if (!values.has(flag)) throw new Error(`${flag} is required`);
  return {
    rawOutputDir: values.get("--raw-output-dir"),
    socketPath: values.get("--socket-path"),
    tokenFile: values.get("--token-file"),
    environmentId: values.get("--environment"),
    targetHead: values.get("--target-head"),
    candidateRunId: values.get("--candidate-run-id"),
    candidateArtifactDigest: values.get("--candidate-artifact-digest"),
    packageVersion: values.get("--package-version"),
    manifestSha256: values.get("--manifest-sha256"),
    manifestSignatureSha256: values.get("--manifest-signature-sha256"),
    compositor: values.get("--compositor"),
  };
}

if (
  process.argv[1] &&
  path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)
) {
  try {
    process.stdout.write(
      `${JSON.stringify(await runP23NativeProviderWorkspaceProbes(parseP23Arguments(process.argv.slice(2))), null, 2)}\n`,
    );
  } catch (error) {
    process.stderr.write(
      `P-23 native provider workspace probe failed: ${error.message}\n`,
    );
    process.exitCode = 1;
  }
}
