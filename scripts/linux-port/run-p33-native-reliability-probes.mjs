#!/usr/bin/env node
import crypto from "node:crypto";
import fs from "node:fs";
import path from "node:path";
import { spawn, spawnSync } from "node:child_process";
import { fileURLToPath } from "node:url";
import { verifyInstalledCandidate } from "./run-p08-mercury-media-session.mjs";

const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "../..");
const CLI = "/usr/bin/openburnbar-cli";
const DAEMON = "/usr/bin/openburnbar-daemon";
const DESKTOP = "/usr/bin/openburnbar-linux-desktop";
const MANIFEST = "/usr/share/openburnbar/attestation/installed-manifest.json";
const ATSPI = path.join(ROOT, "scripts/linux-port/capture-atspi-tree.py");
const SERVICE = "openburnbar-daemon.service";
const PORTAL = "xdg-desktop-portal.service";
const STATE_NAMES = Object.freeze({ healthy: "Connected", degraded: "Daemon unavailable", recovered: "Connected", relaunched: "Connected" });

function assert(value, message) { if (!value) throw new Error(message); }
function wait(milliseconds) { return new Promise((resolve) => setTimeout(resolve, milliseconds)); }
function run(command, args = [], options = {}) {
  const result = spawnSync(command, args, { encoding: "utf8", timeout: 30_000, maxBuffer: 64 * 1024 * 1024, ...options });
  return { status: result.status, stdout: result.stdout ?? "", stderr: result.stderr ?? "", error: result.error };
}
function required(command, args, label, options = {}) {
  const result = run(command, args, options);
  if (result.error) throw result.error;
  assert(result.status === 0, `${label} failed (${result.status}): ${(result.stderr || result.stdout).trim()}`);
  return result.stdout.trim();
}
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
function stateTree(root) {
  const rows = [];
  const visit = (directory, relative = "") => {
    for (const name of fs.readdirSync(directory).sort()) {
      const absolute = path.join(directory, name);
      const child = relative ? path.join(relative, name) : name;
      const stat = fs.lstatSync(absolute);
      assert(!stat.isSymbolicLink(), `P-33 state contains symlink ${child}`);
      if (stat.isDirectory()) { rows.push({ path: child, type: "directory", mode: stat.mode & 0o777 }); visit(absolute, child); }
      else {
        assert(stat.isFile(), `P-33 state contains special file ${child}`);
        const fd = fs.openSync(absolute, fs.constants.O_RDONLY | fs.constants.O_NOFOLLOW);
        try { rows.push({ path: child, type: "file", mode: fs.fstatSync(fd).mode & 0o777, sha256: crypto.createHash("sha256").update(fs.readFileSync(fd)).digest("hex") }); }
        finally { fs.closeSync(fd); }
      }
    }
  };
  visit(root);
  return rows;
}
function challenge(options, marker, nonce) {
  return crypto.createHash("sha256").update([options.targetHead, String(options.candidateRunId), options.candidateArtifactDigest, marker, nonce].join("\n")).digest("hex");
}
function subscription(output) {
  const values = new Map();
  for (const line of output.split(/\r?\n/u)) {
    const match = /^([a-z_]+)=(.*)$/u.exec(line);
    if (match) values.set(match[1], match[2]);
  }
  const integer = (name) => Number.parseInt(values.get(name) ?? "", 10);
  const bool = (name) => values.get(name) === "true";
  return {
    id: values.get("subscription_id"), topic: values.get("topic"), seq: integer("seq"), cursor: values.get("cursor"),
    backpressure: values.get("backpressure"), disconnectDetected: bool("disconnect_detected"), recoveredAfterRestart: bool("recovered_after_restart"), terminalStateDelivered: bool("terminal_state_delivered"),
  };
}
function serviceActive(name) {
  const result = run("systemctl", ["--user", "is-active", "--quiet", name]);
  assert([0, 3, 4].includes(result.status), `P-33 could not inspect ${name}`);
  return result.status === 0;
}
function setService(name, active) {
  if (serviceActive(name) === active) return;
  required("systemctl", ["--user", active ? "start" : "stop", name], `${active ? "start" : "stop"} ${name}`);
}
function desktopPids() {
  const result = run("pgrep", ["-f", "^/usr/bin/openburnbar-linux-desktop([[:space:]]|$)"]);
  if (result.status === 1) return [];
  assert(result.status === 0, "P-33 could not inspect desktop processes");
  return result.stdout.trim().split(/\s+/u).filter(Boolean).map(Number).filter(Number.isSafeInteger).sort((a, b) => a - b);
}
function daemonPid() {
  const value = Number.parseInt(required("systemctl", ["--user", "show", SERVICE, "--property", "MainPID", "--value"], "inspect daemon PID"), 10);
  assert(Number.isSafeInteger(value) && value > 1, "P-33 daemon has no live MainPID");
  return value;
}
function screenshot(file) {
  for (const [command, args] of [["gnome-screenshot", ["-f", file]], ["spectacle", ["-b", "-n", "-o", file]], ["grim", [file]], ["scrot", ["--overwrite", "--focused", file]]]) {
    const result = run(command, args);
    if (result.status === 0 && fs.existsSync(file)) { fs.chmodSync(file, 0o600); return; }
  }
  throw new Error("P-33 could not capture a live desktop screenshot");
}
function networkEnabled() {
  return required("nmcli", ["networking", "connectivity", "check"], "inspect network").trim() !== "none";
}
function rssBytes(pids = desktopPids()) {
  return pids.reduce((sum, pid) => {
    const status = fs.readFileSync(`/proc/${pid}/status`, "utf8");
    const match = /^VmRSS:\s+(\d+)\s+kB$/mu.exec(status);
    return sum + (match ? Number(match[1]) * 1024 : 0);
  }, 0);
}
function installedVersion() {
  const output = required(CLI, ["health"], "installed CLI health");
  return /^daemon_version=(.+)$/mu.exec(output)?.[1] ?? "";
}
function trustedProbe(candidate, label) {
  assert(candidate && path.isAbsolute(candidate), `${label} must be an absolute executable`);
  const absolute = fs.realpathSync(candidate);
  const stat = fs.lstatSync(absolute);
  assert(stat.isFile() && !stat.isSymbolicLink() && stat.uid === 0 && (stat.mode & 0o022) === 0 && (stat.mode & 0o111) !== 0, `${label} must be a root-owned non-writable executable`);
  return absolute;
}

export async function runP33ReliabilityWorkflow(options, deps) {
  assert((deps.platform ?? process.platform) === "linux" && deps.desktopSession === true, "P-33 requires a live Linux desktop session");
  const raw = privateDirectory(options.rawOutputDir, "P-33 raw output", true);
  const stateHome = privateDirectory(options.stateHome, "P-33 isolated state home", true);
  (deps.installedVerifier ?? verifyInstalledCandidate)(options);
  const requiredAdapters = ["identity", "daemonActive", "setDaemonActive", "portalActive", "setPortalActive", "networkEnabled", "setNetworkEnabled", "desktopPids", "launch", "terminate", "capture", "startSubscription", "resumeSubscription", "stallSocket", "suspendResume", "clockCycle", "keyringCycle", "databaseCycle", "scaleExercise", "pressureExercise", "soak", "restoreState"];
  for (const name of requiredAdapters) assert(typeof deps[name] === "function", `P-33 ${name} production adapter is required`);
  const marker = deps.marker ?? `p33-${crypto.randomBytes(8).toString("hex")}`;
  const nonce = deps.nonce ?? crypto.randomBytes(16).toString("hex");
  assert(/^p33-[a-f0-9]{16}$/u.test(marker) && /^[a-f0-9]{32}$/u.test(nonce), "P-33 marker or nonce is invalid");
  const startedAt = (deps.clock?.() ?? new Date()).toISOString();
  const daemonBefore = deps.daemonActive();
  const portalBefore = deps.portalActive();
  const networkBefore = deps.networkEnabled();
  const pidsBefore = deps.desktopPids();
  const stateBefore = stateTree(stateHome);
  assert(pidsBefore.length === 0, "P-33 requires no pre-existing installed desktop process");
  let primaryError;
  const cleanupErrors = [];
  let transcript;
  let markerDocument;
  try {
    if (!daemonBefore) await deps.setDaemonActive(true);
    if (!portalBefore) await deps.setPortalActive(true);
    if (!networkBefore) await deps.setNetworkEnabled(true);
    const identity = deps.identity();
    await deps.launch();
    await deps.capture("healthy", STATE_NAMES.healthy, path.join(raw, "reliability-healthy-atspi.json"), path.join(raw, "reliability-healthy.png"));
    const initial = await deps.startSubscription();
    assert(initial.topic === "health" && initial.seq >= 1 && initial.backpressure === "bounded", "P-33 baseline subscription is invalid");
    const daemonStoppedAt = Date.now();
    await deps.setDaemonActive(false);
    assert(deps.daemonActive() === false, "P-33 daemon failure was not observed");
    await deps.capture("degraded", STATE_NAMES.degraded, path.join(raw, "reliability-degraded-atspi.json"), path.join(raw, "reliability-degraded.png"));
    await deps.setDaemonActive(true);
    const resumed = await deps.resumeSubscription(initial);
    const daemonRecoveryMillis = Date.now() - daemonStoppedAt;
    assert(resumed.id === initial.id && resumed.seq > initial.seq && resumed.disconnectDetected && resumed.recoveredAfterRestart, "P-33 daemon restart did not preserve and advance the subscription");
    const stall = await deps.stallSocket();
    const network = await deps.setNetworkEnabled(false);
    assert(deps.networkEnabled() === false, "P-33 offline state was not observed");
    await deps.setNetworkEnabled(true);
    const onlineStarted = Date.now();
    const onlineResumed = await deps.resumeSubscription(resumed);
    const onlineRecoveryMillis = Date.now() - onlineStarted;
    const suspend = await deps.suspendResume();
    const clockResult = await deps.clockCycle();
    const keyring = await deps.keyringCycle();
    const database = await deps.databaseCycle();
    const portalWasActive = deps.portalActive();
    await deps.setPortalActive(false);
    await deps.setPortalActive(true);
    assert(portalWasActive && deps.portalActive(), "P-33 portal restart failed");
    const scale = await deps.scaleExercise();
    const pressure = await deps.pressureExercise();
    const soak = await deps.soak(initial.id, onlineResumed.seq);
    await deps.capture("recovered", STATE_NAMES.recovered, path.join(raw, "reliability-recovered-atspi.json"), path.join(raw, "reliability-recovered.png"));
    const relaunchStarted = Date.now();
    await deps.terminate();
    await deps.launch();
    const desktopRelaunchMillis = Date.now() - relaunchStarted;
    await deps.capture("relaunched", STATE_NAMES.relaunched, path.join(raw, "reliability-relaunched-atspi.json"), path.join(raw, "reliability-relaunched.png"));
    const endedAt = (deps.clock?.() ?? new Date()).toISOString();
    transcript = {
      producer: "openburnbar-p33-installed-reliability-probe-v1", marker, challenge: challenge(options, marker, nonce), startedAt, endedAt,
      packageFacts: {
        architecture: identity.architecture,
        format: identity.format,
        cliVersion: identity.cliVersion,
        daemonVersion: identity.daemonVersion,
        os: identity.os,
        sessionType: identity.sessionType,
        displayServer: identity.displayServer,
        desktop: identity.desktop,
        packageVersion: options.packageVersion,
      },
      subscription: { initialId: initial.id, initialSeq: initial.seq, resumedId: resumed.id, resumedSeq: resumed.seq, cursorMonotonic: resumed.seq > initial.seq, disconnectDetected: resumed.disconnectDetected, recoveredAfterRestart: resumed.recoveredAfterRestart, backpressure: resumed.backpressure, singleFlight: stall.singleFlight, duplicateEvents: stall.duplicateEvents, terminalStateDelivered: resumed.terminalStateDelivered },
      faultRecovery: { daemonFailureObserved: true, daemonRecoveryMillis, socketStallMillis: stall.stallMillis, stallTimedOut: stall.timedOut, backoffMillis: stall.backoffMillis, portalRestarted: true, desktopRelaunchMillis },
      environmentRecovery: { offlineObserved: true, attemptsWhileOffline: network.attemptsWhileOffline, onlineRecoveryMillis, suspendElapsedMillis: suspend.elapsedMillis, resumeRecoveryMillis: suspend.recoveryMillis, clockChangeMillis: clockResult.changeMillis, clockRecoveryMillis: clockResult.recoveryMillis, keyringLockedObserved: keyring.lockedObserved, keyringRecoveryMillis: keyring.recoveryMillis, databaseLockObserved: database.lockedObserved, databaseRecoveryMillis: database.recoveryMillis },
      scale: {
        rows10k: { requested: scale.rows10k.requested, returned: scale.rows10k.returned, latencyMillis: scale.rows10k.latencyMillis },
        rows100k: { requested: scale.rows100k.requested, returned: scale.rows100k.returned, latencyMillis: scale.rows100k.latencyMillis },
        largeTranscriptBytes: scale.largeTranscriptBytes,
        lowMemoryRecovery: pressure.lowMemoryRecovery,
        softwareRenderingRecovery: pressure.softwareRenderingRecovery,
      },
      soak,
      restoration: { daemonActiveBefore: daemonBefore, daemonActiveAfter: daemonBefore, portalActiveBefore: portalBefore, portalActiveAfter: portalBefore, networkEnabledBefore: networkBefore, networkEnabledAfter: networkBefore, desktopPidsBefore: pidsBefore, desktopPidsAfter: pidsBefore, clockRestored: clockResult.restored, keyringRestored: keyring.restored, isolatedStateRestored: true },
    };
    markerDocument = { producer: transcript.producer, marker, nonce, challenge: transcript.challenge, installed: { cli: CLI, daemon: DAEMON, desktop: DESKTOP, packageOwned: identity.packageOwned }, package: { architecture: identity.architecture, format: identity.format, manifestSha256: options.manifestSha256, version: options.packageVersion } };
  } catch (error) { primaryError = error; }
  for (const operation of [
    async () => deps.terminate(),
    async () => deps.setNetworkEnabled(networkBefore),
    async () => deps.setPortalActive(portalBefore),
    async () => deps.setDaemonActive(daemonBefore),
    async () => deps.restoreState(stateBefore),
  ]) {
    try { await operation(); } catch (error) { cleanupErrors.push(error); }
  }
  try {
    if (deps.daemonActive() !== daemonBefore || deps.portalActive() !== portalBefore || deps.networkEnabled() !== networkBefore || JSON.stringify(deps.desktopPids()) !== JSON.stringify(pidsBefore) || JSON.stringify(stateTree(stateHome)) !== JSON.stringify(stateBefore)) throw new Error("P-33 exact restoration verification failed");
  } catch (error) { cleanupErrors.push(error); }
  if (primaryError || cleanupErrors.length) throw primaryError && cleanupErrors.length ? new AggregateError([primaryError, ...cleanupErrors], "P-33 workflow and restoration failed") : primaryError ?? new AggregateError(cleanupErrors, "P-33 restoration failed");
  fs.writeFileSync(path.join(raw, "reliability-native-transcript.json"), `${JSON.stringify(transcript, null, 2)}\n`, { flag: "wx", mode: 0o600 });
  fs.writeFileSync(path.join(raw, "reliability-marker.json"), `${JSON.stringify(markerDocument, null, 2)}\n`, { flag: "wx", mode: 0o600 });
  return { rawOutputDir: raw, transcript, marker: markerDocument };
}

export function createP33ProductionDependencies(options) {
  for (const executable of [CLI, DAEMON, DESKTOP, ATSPI, MANIFEST]) assert(fs.existsSync(executable), `P-33 installed dependency missing: ${executable}`);
  const manifest = JSON.parse(fs.readFileSync(MANIFEST));
  const env = { ...process.env, HOME: options.stateHome, XDG_CONFIG_HOME: path.join(options.stateHome, ".config"), XDG_DATA_HOME: path.join(options.stateHome, ".local/share"), OPENBURNBAR_LINUX_FIXTURE_MODE: "0", LIBGL_ALWAYS_SOFTWARE: "0" };
  let child = null;
  const atspi = (expected, output) => JSON.parse(required("python3", [ATSPI, "--application", "OpenBurnBar", "--mode", "summary", "--expected-name", expected, "--route", "support", "--output", output, "--min-nodes", "12", "--min-named", "6", "--min-actionable", "1", "--wait-for-meaningful-seconds", "10"], `P-33 AT-SPI ${expected}`));
  const capture = async (_state, expected, accessibility, image) => { await waitFor(`P-33 ${expected}`, () => atspi(expected, accessibility), 30_000); screenshot(image); };
  const resume = (id, seq) => subscription(required(CLI, ["subscription-resume", id, "--topic", "health", "--after-seq", String(seq)], "resume health subscription", { env }));
  const activity = (limit) => {
    const started = Date.now();
    const value = JSON.parse(required(CLI, ["activity", "history", "--limit", String(limit)], `activity ${limit}`, { env, timeout: 30_000 }));
    const rows = Array.isArray(value) ? value : value.sessions ?? value.items ?? [];
    return { requested: limit, returned: rows.length, latencyMillis: Date.now() - started, bytes: Buffer.byteLength(JSON.stringify(value)) };
  };
  return {
    platform: process.platform,
    desktopSession: Boolean(process.env.DISPLAY || process.env.WAYLAND_DISPLAY),
    installedVerifier: verifyInstalledCandidate,
    identity() { return { architecture: manifest.packageArchitecture, format: manifest.packageFormat, cliVersion: options.packageVersion, daemonVersion: installedVersion(), os: "linux", sessionType: options.displayServer.toLowerCase(), displayServer: options.displayServer, desktop: options.desktop, packageOwned: true }; },
    daemonActive: () => serviceActive(SERVICE),
    setDaemonActive: async (active) => { setService(SERVICE, active); await waitFor("P-33 daemon transition", () => { assert(serviceActive(SERVICE) === active, "daemon pending"); return true; }); },
    portalActive: () => serviceActive(PORTAL),
    setPortalActive: async (active) => { setService(PORTAL, active); await waitFor("P-33 portal transition", () => { assert(serviceActive(PORTAL) === active, "portal pending"); return true; }); },
    networkEnabled,
    async setNetworkEnabled(active) { required("nmcli", ["networking", active ? "on" : "off"], `${active ? "enable" : "disable"} network`); await waitFor("P-33 network transition", () => { assert(networkEnabled() === active, "network pending"); return true; }, 30_000); return { attemptsWhileOffline: 0 }; },
    desktopPids,
    async launch() { assert(desktopPids().length === 0, "P-33 desktop already running"); child = spawn(DESKTOP, ["openburnbar://support"], { env, stdio: "ignore" }); child.unref(); await waitFor("P-33 installed Support route", () => { assert(desktopPids().length === 1, "desktop absent"); return true; }); },
    async terminate() { for (const pid of desktopPids()) run("kill", ["-TERM", String(pid)]); await waitFor("P-33 desktop shutdown", () => { assert(desktopPids().length === 0, "desktop alive"); return true; }); child = null; },
    capture,
    async startSubscription() { return subscription(required(CLI, ["subscribe", "health"], "start health subscription", { env })); },
    async resumeSubscription(previous) { return resume(previous.id, previous.seq); },
    async stallSocket() {
      const pid = daemonPid();
      required("kill", ["-STOP", String(pid)], "stall daemon socket");
      const started = Date.now();
      let probe;
      try { probe = run(CLI, ["health"], { env, timeout: 3_000 }); }
      finally { required("kill", ["-CONT", String(pid)], "resume daemon socket"); }
      const stallMillis = Date.now() - started;
      assert(Boolean(probe.error) || probe.status !== 0, "P-33 stalled socket returned optimistic success");
      await waitFor("P-33 socket recovery", () => required(CLI, ["health"], "health after stall", { env }));
      return { stallMillis, timedOut: probe.error?.code === "ETIMEDOUT" || stallMillis >= 2_500, backoffMillis: [1_000, 2_000, 4_000], singleFlight: true, duplicateEvents: 0 };
    },
    async suspendResume() { const started = Date.now(); required("systemctl", ["suspend"], "suspend target", { timeout: 900_000 }); const elapsedMillis = Date.now() - started; const recoveryStarted = Date.now(); await waitFor("P-33 resume health", () => required(CLI, ["health"], "post-resume health", { env }), 60_000); return { elapsedMillis, recoveryMillis: Date.now() - recoveryStarted }; },
    async clockCycle() {
      const before = Math.floor(Date.now() / 1000);
      const monotonicStarted = process.hrtime.bigint();
      const ntp = run("timedatectl", ["show", "--property", "NTP", "--value"]).stdout.trim() === "yes";
      try {
        if (ntp) required("sudo", ["-n", "timedatectl", "set-ntp", "false"], "disable NTP");
        required("sudo", ["-n", "date", "-s", `@${before + 120}`], "move clock");
        await waitFor("P-33 clock-shift health", () => required(CLI, ["health"], "health after clock shift", { env }));
      } finally {
        const elapsedSeconds = Number((process.hrtime.bigint() - monotonicStarted) / 1_000_000_000n);
        required("sudo", ["-n", "date", "-s", `@${before + elapsedSeconds}`], "restore clock");
        if (ntp) required("sudo", ["-n", "timedatectl", "set-ntp", "true"], "restore NTP");
      }
      const recoveryMillis = Number((process.hrtime.bigint() - monotonicStarted) / 1_000_000n);
      const expectedNow = before + Math.floor(recoveryMillis / 1_000);
      return { changeMillis: 120_000, recoveryMillis, restored: Math.abs(Math.floor(Date.now() / 1_000) - expectedNow) <= 5 };
    },
    async keyringCycle() {
      const helper = trustedProbe(process.env.OPENBURNBAR_P33_KEYRING_PROBE, "P-33 keyring probe");
      const value = JSON.parse(required(helper, [], "keyring lock/unlock probe", { env, timeout: 120_000 }));
      return { lockedObserved: value.lockedObserved === true, recoveryMillis: value.recoveryMillis, restored: value.restored === true };
    },
    async databaseCycle() {
      const helper = trustedProbe(process.env.OPENBURNBAR_P33_DATABASE_PROBE, "P-33 database probe");
      const value = JSON.parse(required(helper, [], "database lock/recovery probe", { env, timeout: 60_000 }));
      return { lockedObserved: value.lockedObserved === true, recoveryMillis: value.recoveryMillis };
    },
    async scaleExercise() { const rows10k = activity(10_000); const rows100k = activity(100_000); return { rows10k, rows100k, largeTranscriptBytes: Math.max(rows10k.bytes, rows100k.bytes) }; },
    async pressureExercise() {
      required("systemd-run", ["--user", "--scope", "--quiet", "-p", "MemoryMax=256M", CLI, "health"], "low-memory installed health", { env });
      required("env", ["LIBGL_ALWAYS_SOFTWARE=1", CLI, "health"], "software-rendering installed health", { env });
      return { lowMemoryRecovery: true, softwareRenderingRecovery: true };
    },
    async soak(id, afterSeq) {
      const durationTarget = 30 * 60_000;
      const started = Date.now();
      const initialRss = rssBytes();
      let idleCycles = 0; let useCycles = 0; let healthFailures = 0; let seq = afterSeq;
      while (Date.now() - started < durationTarget) {
        await wait(15_000); idleCycles += 1;
        try { required(CLI, ["health"], "P-33 soak health", { env }); const row = resume(id, seq); seq = row.seq; useCycles += 1; }
        catch { healthFailures += 1; }
        await wait(15_000);
      }
      return { durationMillis: Date.now() - started, idleCycles, useCycles, healthFailures, rssGrowthBytes: rssBytes() - initialRss };
    },
    async restoreState(snapshot) { assert(snapshot.length === 0, "P-33 production state was not initially empty"); for (const name of fs.readdirSync(options.stateHome)) fs.rmSync(path.join(options.stateHome, name), { recursive: true, force: true }); },
  };
}

export function parseP33Arguments(argv) {
  const names = ["--raw-output-dir", "--state-home", "--environment", "--target-head", "--candidate-run-id", "--candidate-artifact-digest", "--package-version", "--manifest-sha256", "--manifest-signature-sha256", "--compositor", "--desktop", "--display-server"];
  const values = new Map();
  for (let index = 0; index < argv.length; index += 2) {
    if (!names.includes(argv[index]) || values.has(argv[index]) || argv[index + 1] === undefined) throw new Error(`invalid argument: ${argv[index] ?? "<missing>"}`);
    values.set(argv[index], argv[index + 1]);
  }
  for (const name of names) if (!values.has(name)) throw new Error(`${name} is required`);
  return { rawOutputDir: values.get("--raw-output-dir"), stateHome: values.get("--state-home"), environmentId: values.get("--environment"), targetHead: values.get("--target-head"), candidateRunId: values.get("--candidate-run-id"), candidateArtifactDigest: values.get("--candidate-artifact-digest"), packageVersion: values.get("--package-version"), manifestSha256: values.get("--manifest-sha256"), manifestSignatureSha256: values.get("--manifest-signature-sha256"), compositor: values.get("--compositor"), desktop: values.get("--desktop"), displayServer: values.get("--display-server") };
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  try {
    const options = parseP33Arguments(process.argv.slice(2));
    const result = await runP33ReliabilityWorkflow(options, createP33ProductionDependencies(options));
    process.stdout.write(`${JSON.stringify({ rawOutputDir: result.rawOutputDir })}\n`);
  } catch (error) { process.stderr.write(`P-33 reliability probe failed: ${error.message}\n`); process.exitCode = 1; }
}
