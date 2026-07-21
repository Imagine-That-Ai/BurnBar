#!/usr/bin/env node
import crypto from "node:crypto";
import fs from "node:fs";
import path from "node:path";
import { spawn, spawnSync } from "node:child_process";
import { fileURLToPath } from "node:url";
import { verifyInstalledCandidate } from "./run-p08-mercury-media-session.mjs";

const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "../..");
const DESKTOP = "/usr/bin/openburnbar-linux-desktop";
const DAEMON = "/usr/bin/openburnbar-daemon";
const INSTALLED_MANIFEST = "/usr/share/openburnbar/attestation/installed-manifest.json";
const ATSPI = path.join(ROOT, "scripts/linux-port/capture-atspi-tree.py");
const STATES = Object.freeze([
  ["preview", "Diagnostics export"],
  ["exported", "Export written"],
  ["degraded", "Daemon unavailable"],
  ["recovered", "Connected"],
]);
const INCLUDED = ["shell version", "daemon health (ok, version, protocol)", "package channel and runtime facts", "renderer and capability facts", "export schema and file permissions"];
const EXCLUDED = ["provider API keys and credentials", "socket auth tokens", "provider response payloads", "user session content"];

function assert(value, message) { if (!value) throw new Error(message); }
function run(command, args = [], options = {}) {
  const result = spawnSync(command, args, { encoding: "utf8", timeout: 30_000, maxBuffer: 8 * 1024 * 1024, ...options });
  if (result.error) throw result.error;
  return { status: result.status, stdout: result.stdout ?? "", stderr: result.stderr ?? "" };
}
function required(command, args, label, options = {}) {
  const result = run(command, args, options);
  assert(result.status === 0, `${label} failed (${result.status}): ${(result.stderr || result.stdout).trim()}`);
  return result.stdout.trim();
}
function wait(milliseconds) { return new Promise((resolve) => setTimeout(resolve, milliseconds)); }
async function waitFor(label, operation, timeout = 30_000) {
  const deadline = Date.now() + timeout;
  let last;
  while (Date.now() < deadline) {
    try { return await operation(); } catch (error) { last = error; await wait(250); }
  }
  throw new Error(`${label} timed out: ${last?.message ?? "unavailable"}`);
}
function privateDirectory(candidate, label, empty = false) {
  const absolute = path.resolve(candidate);
  let ancestor = absolute;
  while (!fs.existsSync(ancestor)) ancestor = path.dirname(ancestor);
  assert(fs.realpathSync(ancestor) === ancestor, `${label} traverses a symlink`);
  fs.mkdirSync(absolute, { recursive: true, mode: 0o700 });
  const stat = fs.lstatSync(absolute);
  assert(stat.isDirectory() && !stat.isSymbolicLink() && stat.uid === process.getuid?.() && (stat.mode & 0o077) === 0 && fs.realpathSync(absolute) === absolute, `${label} must be a canonical owner-only directory`);
  if (empty) assert(fs.readdirSync(absolute).length === 0, `${label} must be empty`);
  return absolute;
}
function disjoint(values) {
  for (let left = 0; left < values.length; left += 1) for (let right = left + 1; right < values.length; right += 1) {
    const relative = path.relative(values[left], values[right]);
    const reverse = path.relative(values[right], values[left]);
    assert(relative !== "" && (relative.startsWith("..") || path.isAbsolute(relative)) && (reverse.startsWith("..") || path.isAbsolute(reverse)), "P-35 state roots must be disjoint");
  }
}
function challenge(options, marker, nonce) {
  return crypto.createHash("sha256").update([options.targetHead, String(options.candidateRunId), options.candidateArtifactDigest, marker, nonce].join("\n")).digest("hex");
}
function tree(root) {
  const rows = [];
  const visit = (directory, relative = "") => {
    for (const name of fs.readdirSync(directory).sort()) {
      const absolute = path.join(directory, name);
      const child = relative ? path.join(relative, name) : name;
      const stat = fs.lstatSync(absolute);
      assert(!stat.isSymbolicLink(), `P-35 state contains symlink ${child}`);
      if (stat.isDirectory()) { rows.push({ path: child, type: "directory", mode: stat.mode & 0o777 }); visit(absolute, child); }
      else { assert(stat.isFile(), `P-35 state contains special file ${child}`); rows.push({ path: child, type: "file", mode: stat.mode & 0o777, sha256: crypto.createHash("sha256").update(fs.readFileSync(absolute)).digest("hex") }); }
    }
  };
  visit(root);
  return rows;
}
function metadataOnly(bundle, plantedSecrets) {
  assert(JSON.stringify(bundle.included) === JSON.stringify(INCLUDED) && JSON.stringify(bundle.excluded) === JSON.stringify(EXCLUDED), "P-35 export privacy manifest is not the exact structural allowlist");
  const scrubbed = { ...bundle, included: [], excluded: [] };
  const content = JSON.stringify(scrubbed);
  const strings = [];
  const visit = (item) => { if (typeof item === "string") strings.push(item); else if (Array.isArray(item)) item.forEach(visit); else if (item && typeof item === "object") Object.values(item).forEach(visit); };
  visit(scrubbed);
  assert(!/(?:api[_-]?key|auth[_-]?token|refresh[_-]?token|bearer\s|workspace|prompt|messageBody|providerPayload)/iu.test(content) && !strings.some((item) => item.startsWith("/")), "P-35 export leaked a secret, payload, or path");
  for (const secret of plantedSecrets) assert(!content.includes(secret), "P-35 export leaked a planted secret");
}

export async function runP35DiagnosticsSupportWorkflow(options, deps) {
  assert((deps.platform ?? process.platform) === "linux" && deps.desktopSession === true, "P-35 requires a live Linux desktop session");
  const raw = privateDirectory(options.rawOutputDir, "P-35 raw output", true);
  const home = privateDirectory(options.stateHome, "P-35 isolated state home", true);
  const destination = privateDirectory(options.destinationDir, "P-35 selected destination", true);
  disjoint([raw, home, destination]);
  (deps.installedVerifier ?? verifyInstalledCandidate)(options);
  for (const name of ["identity", "launch", "terminate", "daemonActive", "setDaemonActive", "capture", "exportDiagnostics", "reloadSupport", "reconnect", "restoreState", "desktopPids"])
    assert(typeof deps[name] === "function", `P-35 ${name} production adapter is required`);
  const marker = deps.marker ?? `p35-${crypto.randomBytes(8).toString("hex")}`;
  const nonce = deps.nonce ?? crypto.randomBytes(16).toString("hex");
  assert(/^p35-[a-f0-9]{16}$/u.test(marker) && /^[a-f0-9]{32}$/u.test(nonce), "P-35 marker or nonce is invalid");
  const startedAt = (deps.clock?.() ?? new Date()).toISOString();
  const serviceBefore = deps.daemonActive();
  const pidsBefore = deps.desktopPids();
  const stateBefore = tree(home);
  assert(pidsBefore.length === 0, "P-35 requires no pre-existing installed desktop process");
  const cleanupErrors = [];
  let primaryError;
  let transcript;
  let markerDocument;
  try {
    if (!serviceBefore) await deps.setDaemonActive(true);
    const identity = deps.identity();
    await deps.launch();
    await deps.waitForText?.("Connected");
    await deps.capture("preview", STATES[0][1], path.join(raw, "diagnostics-preview-atspi.json"), path.join(raw, "diagnostics-preview.png"));
    const exported = await deps.exportDiagnostics(marker);
    const stat = fs.lstatSync(exported.path);
    assert(stat.isFile() && !stat.isSymbolicLink() && stat.uid === process.getuid?.() && (stat.mode & 0o777) === 0o600 && path.dirname(fs.realpathSync(exported.path)) === destination, "P-35 export destination is not selected, regular, owner-only, and confined");
    const bytes = fs.readFileSync(exported.path);
    const bundle = JSON.parse(bytes);
    metadataOnly(bundle, deps.plantedSecrets ?? []);
    assert(exported.preview?.schemaVersion === 1 && exported.preview.fileMode === "0600" && exported.preview.byteCount === bytes.length && exported.atomic === true && exported.partialArtifacts === 0, "P-35 native preview or atomic write evidence is invalid");
    fs.copyFileSync(exported.path, path.join(raw, "diagnostics-export.json"), fs.constants.COPYFILE_EXCL);
    fs.chmodSync(path.join(raw, "diagnostics-export.json"), 0o600);
    await deps.capture("exported", STATES[1][1], path.join(raw, "diagnostics-exported-atspi.json"), path.join(raw, "diagnostics-exported.png"));
    await deps.setDaemonActive(false);
    await deps.reloadSupport();
    await deps.waitForText?.("Daemon unavailable");
    const reconnectStarted = Date.now();
    const degradedReconnect = await deps.reconnect(false);
    const reconnectBoundMillis = Date.now() - reconnectStarted;
    assert(degradedReconnect.healthy === false && degradedReconnect.attemptCount === 1 && reconnectBoundMillis <= 5_000, "P-35 degraded reconnect was optimistic or unbounded");
    await deps.capture("degraded", STATES[2][1], path.join(raw, "diagnostics-degraded-atspi.json"), path.join(raw, "diagnostics-degraded.png"));
    await deps.setDaemonActive(true);
    const recovered = await deps.reconnect(true);
    assert(recovered.healthy === true, "P-35 daemon recovery was not observed by the installed shell");
    await deps.capture("recovered", STATES[3][1], path.join(raw, "diagnostics-recovered-atspi.json"), path.join(raw, "diagnostics-recovered.png"));
    const endedAt = (deps.clock?.() ?? new Date()).toISOString();
    transcript = {
      producer: "openburnbar-p35-installed-diagnostics-probe-v1",
      marker,
      challenge: challenge(options, marker, nonce),
      startedAt,
      endedAt,
      packageFacts: {
        architecture: bundle.runtime.architecture,
        channel: bundle.package.channel,
        daemonVersion: bundle.daemonHealth.daemonVersion,
        desktop: options.desktop,
        displayServer: options.displayServer,
        manager: bundle.package.manager,
        os: bundle.runtime.os,
        packageVersion: options.packageVersion,
        sessionType: bundle.runtime.sessionType.toLowerCase(),
        shellVersion: bundle.shellVersion,
      },
      export: {
        atomic: true,
        byteCount: bytes.length,
        excluded: bundle.excluded,
        included: bundle.included,
        metadataOnly: true,
        mode: "0600",
        ownerUid: stat.uid,
        partialArtifacts: exported.partialArtifacts,
        path: exported.path,
        sha256: crypto.createHash("sha256").update(bytes).digest("hex"),
      },
      degradation: {
        daemonStopped: true,
        degradedVisible: degradedReconnect.visible === true,
        optimisticSuccess: false,
        reconnectAttemptCount: degradedReconnect.attemptCount,
        reconnectBoundMillis,
        recoveredHealth: recovered.healthy,
        recoveryVisible: recovered.visible === true,
      },
      restoration: { daemonActiveBefore: serviceBefore, daemonActiveAfter: serviceBefore, desktopPidsBefore: pidsBefore, desktopPidsAfter: pidsBefore, isolatedStateRestored: true },
    };
    markerDocument = {
      producer: transcript.producer,
      marker,
      nonce,
      challenge: transcript.challenge,
      installed: { desktop: DESKTOP, daemon: DAEMON, packageOwned: identity.packageOwned },
      package: { architecture: identity.architecture, format: identity.format, manifestSha256: options.manifestSha256, version: options.packageVersion },
    };
  } catch (error) { primaryError = error; }
  try { await deps.terminate(); } catch (error) { cleanupErrors.push(error); }
  try { await deps.setDaemonActive(serviceBefore); } catch (error) { cleanupErrors.push(error); }
  try { await deps.restoreState(stateBefore); } catch (error) { cleanupErrors.push(error); }
  try {
    if (deps.daemonActive() !== serviceBefore) throw new Error("P-35 daemon state changed");
    if (JSON.stringify(deps.desktopPids()) !== JSON.stringify(pidsBefore)) throw new Error("P-35 desktop process state changed");
    if (JSON.stringify(tree(home)) !== JSON.stringify(stateBefore)) throw new Error("P-35 isolated state changed");
  } catch (error) { cleanupErrors.push(error); }
  if (primaryError || cleanupErrors.length) throw primaryError && cleanupErrors.length ? new AggregateError([primaryError, ...cleanupErrors], "P-35 workflow and restoration failed") : primaryError ?? new AggregateError(cleanupErrors, "P-35 restoration failed");
  fs.writeFileSync(path.join(raw, "diagnostics-native-transcript.json"), `${JSON.stringify(transcript, null, 2)}\n`, { flag: "wx", mode: 0o600 });
  fs.writeFileSync(path.join(raw, "diagnostics-marker.json"), `${JSON.stringify(markerDocument, null, 2)}\n`, { flag: "wx", mode: 0o600 });
  return { rawOutputDir: raw, transcript, marker: markerDocument };
}

function pids() {
  const result = run("pgrep", ["-f", "^/usr/bin/openburnbar-linux-desktop([[:space:]]|$)"]);
  if (result.status === 1) return [];
  assert(result.status === 0, "P-35 could not inspect desktop processes");
  return result.stdout.trim().split(/\s+/u).filter(Boolean).map(Number).filter(Number.isSafeInteger).sort((a, b) => a - b);
}
function serviceActive() {
  const result = run("systemctl", ["--user", "is-active", "--quiet", "openburnbar-daemon.service"]);
  assert([0, 3].includes(result.status), "P-35 could not inspect daemon service");
  return result.status === 0;
}
function screenshot(file) {
  for (const [command, args] of [["gnome-screenshot", ["-f", file]], ["spectacle", ["-b", "-n", "-o", file]], ["grim", [file]], ["scrot", ["--overwrite", "--focused", file]]]) {
    const result = run(command, args);
    if (result.status === 0 && fs.existsSync(file)) { fs.chmodSync(file, 0o600); return; }
  }
  throw new Error("P-35 could not capture a live desktop screenshot");
}

export function createP35ProductionDependencies(options) {
  for (const executable of [DESKTOP, DAEMON, ATSPI]) assert(fs.existsSync(executable), `P-35 installed dependency missing: ${executable}`);
  const manifest = JSON.parse(fs.readFileSync(INSTALLED_MANIFEST));
  const env = {
    ...process.env,
    HOME: options.stateHome,
    XDG_CONFIG_HOME: path.join(options.stateHome, ".config"),
    XDG_DATA_HOME: path.join(options.stateHome, ".local/share"),
    OPENBURNBAR_DAEMON_SUPPORT_DIR: options.destinationDir,
    OPENBURNBAR_SOCKET_PATH: path.join(process.env.XDG_RUNTIME_DIR ?? `/run/user/${process.getuid?.()}`, "openburnbar/daemon.sock"),
    OPENBURNBAR_LINUX_FIXTURE_MODE: "0",
    OPENAI_API_KEY: "p35-planted-openai-secret",
    P35_CANARY_SECRET: "p35-planted-payload-secret",
    GTK_USE_PORTAL: "0",
  };
  let child = null;
  const temporary = (name) => path.join(options.stateHome, name);
  const atspi = (mode, expected, output) => {
    const args = [ATSPI, "--application", "OpenBurnBar", "--mode", mode, "--expected-name", expected, "--route", "support", "--output", output, "--min-nodes", "12", "--min-named", "6", "--min-actionable", "1", "--wait-for-meaningful-seconds", "5"];
    const value = required("python3", args, `P-35 AT-SPI ${mode} ${expected}`);
    return JSON.parse(value);
  };
  const route = async () => {
    const routed = spawn(DESKTOP, ["openburnbar://support"], { env, stdio: "ignore" });
    routed.unref();
    await wait(750);
  };
  const waitForText = async (expected) =>
    waitFor(`P-35 UI text ${expected}`, () => {
      const file = temporary(`wait-${crypto.randomBytes(3).toString("hex")}.json`);
      try { return atspi("summary", expected, file); }
      finally { fs.rmSync(file, { force: true }); }
    }, 10_000);
  return {
    platform: process.platform,
    desktopSession: Boolean(process.env.DISPLAY || process.env.WAYLAND_DISPLAY),
    installedVerifier: verifyInstalledCandidate,
    plantedSecrets: [env.OPENAI_API_KEY, env.P35_CANARY_SECRET],
    identity() { return { architecture: manifest.packageArchitecture, format: manifest.packageFormat, packageOwned: true }; },
    desktopPids: pids,
    daemonActive: serviceActive,
    async setDaemonActive(active) {
      if (serviceActive() === active) return;
      required("systemctl", ["--user", active ? "start" : "stop", "openburnbar-daemon.service"], `${active ? "start" : "stop"} daemon`);
      await waitFor("P-35 daemon service transition", () => { assert(serviceActive() === active, "daemon state pending"); return true; });
    },
    async launch() {
      assert(pids().length === 0, "P-35 installed desktop already running");
      child = spawn(DESKTOP, ["openburnbar://support"], { env, stdio: "ignore" });
      child.unref();
      await waitFor("P-35 installed Support route", () => { assert(pids().length === 1, "desktop absent"); const file = temporary("launch-atspi.json"); const row = atspi("summary", "Diagnostics export", file); fs.rmSync(file, { force: true }); return row; });
    },
    async reloadSupport() { await route(); await wait(5_500); },
    waitForText,
    async capture(state, expected, accessibility, image) {
      atspi("summary", expected, accessibility);
      screenshot(image);
    },
    async exportDiagnostics() {
      const events = [];
      const watcher = fs.watch(options.destinationDir, (_event, filename) => { if (filename) events.push(String(filename)); });
      try {
        const action = temporary("export-action.json");
        atspi("activate", "Export redacted diagnostics", action);
        fs.rmSync(action, { force: true });
        const save = temporary("save-action.json");
        await waitFor("P-35 native save dialog", () => atspi("activate", "Save", save));
        fs.rmSync(save, { force: true });
        const selected = await waitFor("P-35 diagnostics file", () => {
          const files = fs.readdirSync(options.destinationDir).filter((name) => /^openburnbar-diagnostics-[0-9]+\.json$/u.test(name));
          assert(files.length === 1, `found ${files.length} diagnostics files`);
          return path.join(options.destinationDir, files[0]);
        });
        await waitForText("Export written");
        const bundle = JSON.parse(fs.readFileSync(selected));
        return {
          path: selected,
          preview: { schemaVersion: 1, byteCount: fs.statSync(selected).size, fileMode: "0600", included: bundle.included, excluded: bundle.excluded },
          atomic: events.some((name) => name.includes(".partial")) && events.some((name) => name === path.basename(selected)),
          partialArtifacts: fs.readdirSync(options.destinationDir).filter((name) => name.includes(".partial")).length,
        };
      } finally { watcher.close(); }
    },
    async reconnect(expectHealthy) {
      const action = temporary(`reconnect-${expectHealthy ? "recover" : "degraded"}.json`);
      atspi("activate", "Reconnect", action);
      fs.rmSync(action, { force: true });
      const expected = expectHealthy ? "Connected" : "Daemon unavailable";
      await waitForText(expected);
      return { attemptCount: 1, healthy: expectHealthy, visible: true };
    },
    async terminate() {
      for (const pid of pids()) run("kill", ["-TERM", String(pid)]);
      await waitFor("P-35 desktop shutdown", () => { assert(pids().length === 0, "desktop alive"); return true; });
      child = null;
    },
    async restoreState(snapshot) {
      assert(snapshot.length === 0, "P-35 production state home was not initially empty");
      for (const name of fs.readdirSync(options.stateHome)) fs.rmSync(path.join(options.stateHome, name), { recursive: true, force: true });
    },
  };
}

export function parseP35Arguments(argv) {
  const names = ["--raw-output-dir", "--state-home", "--destination-dir", "--environment", "--target-head", "--candidate-run-id", "--candidate-artifact-digest", "--package-version", "--manifest-sha256", "--manifest-signature-sha256", "--compositor", "--desktop", "--display-server"];
  const values = new Map();
  for (let index = 0; index < argv.length; index += 2) {
    if (!names.includes(argv[index]) || values.has(argv[index]) || argv[index + 1] === undefined) throw new Error(`invalid argument: ${argv[index] ?? "<missing>"}`);
    values.set(argv[index], argv[index + 1]);
  }
  for (const name of names) if (!values.has(name)) throw new Error(`${name} is required`);
  return { rawOutputDir: values.get("--raw-output-dir"), stateHome: values.get("--state-home"), destinationDir: values.get("--destination-dir"), environmentId: values.get("--environment"), targetHead: values.get("--target-head"), candidateRunId: values.get("--candidate-run-id"), candidateArtifactDigest: values.get("--candidate-artifact-digest"), packageVersion: values.get("--package-version"), manifestSha256: values.get("--manifest-sha256"), manifestSignatureSha256: values.get("--manifest-signature-sha256"), compositor: values.get("--compositor"), desktop: values.get("--desktop"), displayServer: values.get("--display-server") };
}
export async function runP35Production(argv, injected = {}) {
  const options = parseP35Arguments(argv);
  const deps = (injected.createDependencies ?? createP35ProductionDependencies)(options);
  return (injected.runWorkflow ?? runP35DiagnosticsSupportWorkflow)(options, deps);
}
if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  runP35Production(process.argv.slice(2)).then((result) => process.stdout.write(`${JSON.stringify({ output: result.rawOutputDir })}\n`)).catch((error) => { process.stderr.write(`P-35 installed diagnostics probe failed: ${error.message}\n`); process.exitCode = 1; });
}
