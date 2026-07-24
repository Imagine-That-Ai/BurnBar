#!/usr/bin/env node
import crypto from "node:crypto";
import fs from "node:fs";
import path from "node:path";
import { spawn, spawnSync } from "node:child_process";
import { fileURLToPath } from "node:url";
import { verifyInstalledCandidate } from "./run-p08-mercury-media-session.mjs";

const CLI = "/usr/bin/openburnbar-cli";
const DAEMON_LAUNCHER = "/usr/libexec/openburnbar-daemon-launch";
const DESKTOP = "/usr/bin/openburnbar-linux-desktop";
const SERVICE_TYPE = "_openburnbar-peer._tcp";
const STATES = ["discovered", "controlled", "degraded", "recovered"];
const PNG_SIGNATURE = Buffer.from([137, 80, 78, 71, 13, 10, 26, 10]);

const ATSPI_SCRIPT = String.raw`
import json, sys, time
from collections import deque
from datetime import datetime, timezone
import pyatspi

state, output, marker, nonce, pid, operation, expected = sys.argv[1:]

def safe(value):
    try: return str(value or "").replace("\n", " ").strip()
    except Exception: return ""

def children(node):
    for index in range(int(getattr(node, "childCount", 0))):
        try: yield node.getChildAtIndex(index)
        except Exception: pass

def walk(root, limit=6000):
    queue, count = deque([root]), 0
    while queue and count < limit:
        node = queue.popleft(); count += 1; yield node
        queue.extend(children(node))
    if queue: raise RuntimeError("P-28 AT-SPI tree exceeded its node budget")

def details(node):
    name = safe(getattr(node, "name", ""))
    try: role = safe(node.getRoleName()).lower()
    except Exception: role = "unknown"
    try:
        action = node.queryAction()
        actions = [safe(action.getName(i)).lower() for i in range(action.nActions)]
    except Exception: actions = []
    try:
        states = [safe(pyatspi.stateToString(value)).lower() for value in node.getState().getStates()]
    except Exception: states = []
    return name, role, actions, states

def application(timeout=20):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        matches = [app for app in children(pyatspi.Registry.getDesktop(0))
                   if "openburnbar" in safe(getattr(app, "name", "")).casefold()]
        if len(matches) == 1: return matches[0]
        if len(matches) > 1: raise RuntimeError("multiple OpenBurnBar AT-SPI applications are running")
        time.sleep(.2)
    raise RuntimeError("OpenBurnBar AT-SPI application was not found")

def find(root, wanted, actionable=False):
    needle, matches = wanted.casefold(), []
    for node in walk(root):
        name, role, actions, states = details(node)
        if needle in name.casefold() and (not actionable or actions):
            matches.append((0 if name.casefold() == needle else 1, len(name), node))
    if not matches: raise RuntimeError("AT-SPI node not found: " + wanted)
    return sorted(matches, key=lambda row: (row[0], row[1]))[0][2]

def activate(node):
    action = node.queryAction()
    names = [safe(action.getName(i)).lower() for i in range(action.nActions)]
    index = next((i for wanted in ("press", "click", "activate", "select")
                  for i, name in enumerate(names) if name == wanted), 0)
    if not names or not action.doAction(index):
        raise RuntimeError("AT-SPI action failed: " + safe(getattr(node, "name", "")))

app = application()
if state == "discovered":
    try: activate(find(app, "SmartHub / IoT", True))
    except RuntimeError: pass
combo = find(app, "Operation")
if not combo.queryComponent().grabFocus(): raise RuntimeError("SmartHub operation selector rejected focus")
indexes = {"discover": 0, "status": 1}
pyatspi.Registry.generateKeyboardEvent(0, "Home", pyatspi.KEY_SYM)
for _ in range(indexes[operation]): pyatspi.Registry.generateKeyboardEvent(0, "Down", pyatspi.KEY_SYM)
pyatspi.Registry.generateKeyboardEvent(0, "Return", pyatspi.KEY_SYM)
activate(find(app, "Run operation", True))
deadline = time.monotonic() + 20
while time.monotonic() < deadline:
    names = " ".join(details(node)[0] for node in walk(app))
    if expected.casefold() in names.casefold(): break
    time.sleep(.2)
else: raise RuntimeError("SmartHub live result was not exposed through AT-SPI: " + expected)
run = find(app, "Run operation", True)
if not run.queryComponent().grabFocus(): raise RuntimeError("SmartHub Run operation control rejected focus")
rows, focused = [], ""
for node in walk(app):
    name, role, actions, states = details(node)
    if name or actions: rows.append({"name": name, "role": role, "actions": actions, "states": states})
    if "focused" in states and name: focused = name
if len(rows) < 8: raise RuntimeError("SmartHub surface exposed fewer than eight AT-SPI nodes")
names = " ".join(row["name"] for row in rows)
if "SmartHub / IoT".casefold() not in names.casefold(): raise RuntimeError("SmartHub route is absent from AT-SPI")
document = {
  "producer": "openburnbar-p28-atspi-live-v1", "marker": marker, "nonce": nonce,
  "state": state, "capturedAt": datetime.now(timezone.utc).isoformat(timespec="milliseconds").replace("+00:00", "Z"),
  "application": "OpenBurnBar", "desktopPid": int(pid), "route": "smarthub",
  "selectedOperation": operation, "focusedName": focused, "statusText": expected,
  "nodes": rows
}
with open(output, "x", encoding="utf-8") as handle: json.dump(document, handle, indent=2); handle.write("\n")
print(json.dumps(document, separators=(",", ":")))
`;

function assert(value, message) {
  if (!value) throw new Error(message);
}

function sleep(milliseconds) {
  return new Promise((resolve) => setTimeout(resolve, milliseconds));
}

function sha256(bytes) {
  return crypto.createHash("sha256").update(bytes).digest("hex");
}

function canonicalBytes(value) {
  return Buffer.from(`${JSON.stringify(value, null, 2)}\n`);
}

function command(executable, args = [], options = {}) {
  const result = spawnSync(executable, args, {
    encoding: "utf8",
    timeout: 30_000,
    maxBuffer: 8 * 1024 * 1024,
    ...options,
  });
  if (result.error) throw result.error;
  if (result.status !== 0) {
    throw new Error(
      `${executable} failed (${result.status}): ${(result.stderr || result.stdout).trim()}`,
    );
  }
  return result.stdout.trim();
}

function jsonCommand(executable, args, options = {}) {
  const value = command(executable, args, options);
  assert(value.length > 0, `${executable} returned an empty JSON response`);
  return JSON.parse(value);
}

function ownerEmptyDirectory(directory, label) {
  fs.mkdirSync(directory, { recursive: true, mode: 0o700 });
  const stat = fs.lstatSync(directory);
  assert(
    stat.isDirectory() &&
      !stat.isSymbolicLink() &&
      stat.uid === process.getuid?.() &&
      (stat.mode & 0o077) === 0,
    `P-28 ${label} must be an owned owner-only directory`,
  );
  assert(fs.readdirSync(directory).length === 0, `P-28 ${label} must be empty`);
  return fs.realpathSync(directory);
}

function writeExclusive(file, value) {
  const bytes = Buffer.isBuffer(value) ? value : canonicalBytes(value);
  fs.writeFileSync(file, bytes, { flag: "wx", mode: 0o600 });
  return sha256(bytes);
}

function processIds(pattern) {
  const result = spawnSync("pgrep", ["-f", pattern], { encoding: "utf8" });
  if (result.status === 1) return [];
  if (result.status !== 0)
    throw new Error(`P-28 could not inspect ${pattern} processes`);
  return result.stdout
    .trim()
    .split(/\s+/u)
    .filter(Boolean)
    .map(Number)
    .filter(Number.isSafeInteger)
    .sort((left, right) => left - right);
}

function daemonActive() {
  const result = spawnSync("systemctl", [
    "--user",
    "is-active",
    "--quiet",
    "openburnbar-daemon.service",
  ]);
  if (![0, 3].includes(result.status))
    throw new Error("P-28 could not inspect daemon service state");
  return result.status === 0;
}

function packageIdentity() {
  const paths = [CLI, DAEMON_LAUNCHER, DESKTOP];
  for (const [manager, executable, argsFor] of [
    ["dpkg", "dpkg-query", (file) => ["-S", file]],
    ["rpm", "rpm", (file) => ["-qf", file, "--qf", "%{NAME}\\n"]],
    ["pacman", "pacman", (file) => ["-Qo", file]],
  ]) {
    const rows = paths.map((file) =>
      spawnSync(executable, argsFor(file), { encoding: "utf8" }),
    );
    if (rows.every((row) => row.status === 0)) {
      const names = rows.map((row) => {
        const line = row.stdout.trim().split("\n")[0];
        if (manager === "dpkg") return line.split(":", 1)[0];
        if (manager === "rpm") return line;
        return line.split(" is owned by ")[1]?.split(" ")[0] ?? "";
      });
      assert(
        names.every((name) => /^openburnbar(?:$|[-_])/u.test(name)),
        "P-28 installed executables are not owned by OpenBurnBar packages",
      );
      return {
        packageManager: manager,
        packageName: names[0],
        packageOwned: true,
        executablePackages: Object.fromEntries(
          paths.map((file, index) => [file, names[index]]),
        ),
      };
    }
  }
  throw new Error("P-28 could not prove installed package ownership");
}

function validatePackageIdentity(value) {
  assert(value?.packageOwned === true, "P-28 package ownership is not proven");
  assert(
    ["dpkg", "rpm", "pacman"].includes(value.packageManager),
    "P-28 package manager identity is invalid",
  );
  assert(
    /^openburnbar(?:$|[-_])/u.test(value.packageName ?? ""),
    "P-28 package name is invalid",
  );
  for (const executable of [CLI, DAEMON_LAUNCHER, DESKTOP]) {
    assert(
      /^openburnbar(?:$|[-_])/u.test(
        value.executablePackages?.[executable] ?? "",
      ),
      `P-28 package manifest substituted installed executable: ${executable}`,
    );
  }
  return value;
}

function screenshot(file) {
  for (const [executable, args] of [
    ["gnome-screenshot", ["-f", file]],
    ["spectacle", ["-b", "-n", "-o", file]],
    ["grim", [file]],
    ["import", ["-window", "root", file]],
  ]) {
    const result = spawnSync(executable, args, {
      encoding: "utf8",
      timeout: 30_000,
    });
    if (result.status === 0 && fs.existsSync(file)) {
      fs.chmodSync(file, 0o600);
      return;
    }
  }
  throw new Error("P-28 could not capture a desktop screenshot");
}

function openEvidenceFd(file, message) {
  try {
    return fs.openSync(file, fs.constants.O_RDONLY | fs.constants.O_NOFOLLOW);
  } catch (error) {
    if (error.code === "ELOOP") throw new Error(message);
    throw error;
  }
}

function inspectScreenshot(file, startedMs) {
  const fd = openEvidenceFd(file, `P-28 screenshot is not an owned regular file: ${file}`);
  let bytes;
  try {
    const stat = fs.fstatSync(fd);
    assert(
      stat.isFile() && stat.uid === process.getuid?.(),
      `P-28 screenshot is not an owned regular file: ${file}`,
    );
    assert(
      stat.mtimeMs >= startedMs - 1_000,
      `P-28 screenshot is stale: ${file}`,
    );
    bytes = fs.readFileSync(fd);
  } finally {
    fs.closeSync(fd);
  }
  assert(bytes.length >= 64, `P-28 screenshot is implausibly small: ${file}`);
  assert(
    bytes.subarray(0, PNG_SIGNATURE.length).equals(PNG_SIGNATURE),
    `P-28 screenshot is not PNG: ${file}`,
  );
  return sha256(bytes);
}

function inspectAtspiFile(file, document) {
  const fd = openEvidenceFd(file, `P-28 AT-SPI evidence is not an owned regular file: ${file}`);
  let bytes;
  try {
    const stat = fs.fstatSync(fd);
    assert(
      stat.isFile() && stat.uid === process.getuid?.(),
      `P-28 AT-SPI evidence is not an owned regular file: ${file}`,
    );
    bytes = fs.readFileSync(fd);
  } finally {
    fs.closeSync(fd);
  }
  const stored = JSON.parse(bytes.toString("utf8"));
  assert(
    JSON.stringify(stored) === JSON.stringify(document),
    `P-28 AT-SPI evidence was substituted after capture: ${file}`,
  );
  return sha256(bytes);
}

function validatePeer(metadata, peers, discovery) {
  assert(
    metadata?.service_type === SERVICE_TYPE,
    "P-28 peer metadata service type is invalid",
  );
  assert(
    /^OpenBurnBar-/u.test(metadata.instance ?? ""),
    "P-28 peer metadata instance is invalid",
  );
  const txt = metadata.txt;
  assert(txt && !Array.isArray(txt), "P-28 peer metadata TXT record is absent");
  assert(txt.platform === "linux", "P-28 peer metadata platform is not Linux");
  assert(txt.pairing === "mdns", "P-28 peer metadata is not mDNS-backed");
  assert(
    ["unix-domain", "http"].includes(txt.transport),
    "P-28 peer transport is invalid",
  );
  assert(
    /^\d+$/u.test(txt.protocol_version ?? "") &&
      Number(txt.protocol_version) > 0,
    "P-28 peer protocol version is invalid",
  );
  assert(
    typeof txt.daemon_version === "string" && txt.daemon_version.length > 0,
    "P-28 peer daemon version is absent",
  );
  assert(
    Array.isArray(peers) && peers.length > 0,
    "P-28 live peer browse returned no peers",
  );
  const matching = peers.filter(
    (peer) => peer.instanceName === metadata.instance,
  );
  assert(
    matching.length === 1,
    "P-28 live browse did not resolve exactly one advertised peer",
  );
  const peer = matching[0];
  assert(
    Number.isSafeInteger(peer.port) && peer.port > 0 && peer.port <= 65_535,
    "P-28 peer port is invalid",
  );
  for (const key of [
    "platform",
    "pairing",
    "transport",
    "protocol_version",
    "daemon_version",
  ])
    assert(
      peer.txt?.[key] === txt[key],
      `P-28 browsed peer ${key} does not match advertised metadata`,
    );
  assert(
    Array.isArray(discovery) && discovery.length === 1,
    "P-28 SmartHub discovery result is ambiguous",
  );
  const row = discovery[0];
  assert(
    row.adapter === "smart_hub_bridge",
    "P-28 discovery used a substituted adapter",
  );
  assert(
    row.serviceType === SERVICE_TYPE,
    "P-28 discovery used a substituted service type",
  );
  assert(
    row.status === "ok" && !row.blocker,
    "P-28 discovery did not complete successfully",
  );
  assert(
    row.instances?.includes(metadata.instance),
    "P-28 product discovery omitted the advertised peer",
  );
  return peer;
}

function validateHealthyStatus(value, label) {
  assert(
    value?.adapter === "smart_hub_bridge",
    `P-28 ${label} status used a substituted adapter`,
  );
  assert(
    value.status === "bridge_control_ok",
    `P-28 ${label} status did not prove health and control`,
  );
  assert(value.blocker === "", `P-28 ${label} status retained a blocker`);
  assert(
    /\/health/u.test(value.health_probe ?? "") &&
      (value.health_response ?? "").length > 0,
    `P-28 ${label} omitted live health proof`,
  );
  assert(
    /\/api\/display/u.test(value.control_probe ?? "") &&
      (value.control_response ?? "").length > 0,
    `P-28 ${label} omitted actionable control proof`,
  );
}

function validateDegradedStatus(value) {
  assert(
    value?.adapter === "smart_hub_bridge",
    "P-28 degraded status used a substituted adapter",
  );
  assert(
    value.status === "blocked_bridge_not_reachable",
    "P-28 bridge outage did not produce honest capability loss",
  );
  assert(
    (value.blocker ?? "").length > 0,
    "P-28 degraded status omitted recovery guidance",
  );
  assert(
    !(value.health_response ?? "") && !(value.control_response ?? ""),
    "P-28 degraded status replayed a healthy response",
  );
}

export function normalizeP28DesktopIdentity(value) {
  const observed = String(value ?? "").trim();
  const normalized = observed.toLowerCase();
  if (/(?:^|[:;])gnome(?:$|[:;])/u.test(normalized)) return "GNOME";
  if (
    /(?:^|[:;])kde(?:$|[:;])/u.test(normalized) ||
    normalized.includes("plasma")
  )
    return "KDE Plasma";
  if (
    /(?:^|[:;])sway(?:$|[:;])/u.test(normalized) ||
    normalized.includes("wlroots")
  )
    return "Sway/wlroots";
  return observed;
}

function validateAtspi(
  document,
  { marker, nonce, state, pid, operation, expected, startedMs },
) {
  assert(
    document?.producer === "openburnbar-p28-atspi-live-v1",
    `P-28 ${state} AT-SPI producer is invalid`,
  );
  assert(
    document.marker === marker && document.nonce === nonce,
    `P-28 ${state} AT-SPI binding is invalid`,
  );
  assert(
    document.state === state && document.desktopPid === pid,
    `P-28 ${state} AT-SPI process/state binding is invalid`,
  );
  assert(
    document.route === "smarthub" && document.selectedOperation === operation,
    `P-28 ${state} AT-SPI route/action is invalid`,
  );
  const capturedMs = Date.parse(document.capturedAt);
  assert(
    Number.isFinite(capturedMs) &&
      capturedMs >= startedMs - 1_000 &&
      capturedMs <= Date.now() + 5_000,
    `P-28 ${state} AT-SPI evidence is stale or future-dated`,
  );
  assert(
    /Run operation/iu.test(document.focusedName ?? ""),
    `P-28 ${state} AT-SPI focus was not restored to the action`,
  );
  const nodes = document.nodes;
  assert(
    Array.isArray(nodes) && nodes.length >= 8,
    `P-28 ${state} AT-SPI tree is incomplete`,
  );
  const operationNode = nodes.find((node) =>
    /Operation/iu.test(node.name ?? ""),
  );
  const actionNode = nodes.find((node) =>
    /Run operation/iu.test(node.name ?? ""),
  );
  assert(
    operationNode && actionNode?.actions?.length > 0,
    `P-28 ${state} AT-SPI controls are not actionable`,
  );
  const visible = `${document.statusText ?? ""} ${nodes.map((node) => node.name).join(" ")}`;
  assert(
    visible.toLowerCase().includes(expected.toLowerCase()),
    `P-28 ${state} AT-SPI status is stale or substituted`,
  );
}

async function waitFor(label, operation, timeout = 20_000) {
  const deadline = Date.now() + timeout;
  let last;
  while (Date.now() < deadline) {
    try {
      return await operation();
    } catch (error) {
      last = error;
      await sleep(250);
    }
  }
  throw new Error(`${label} timed out: ${last?.message ?? "unavailable"}`);
}

function defaultDependencies(options) {
  let child = null;
  let bridgePid = null;
  const env = {
    ...process.env,
    HOME: options.homeDir,
    XDG_CONFIG_HOME: path.join(options.homeDir, ".config"),
    XDG_DATA_HOME: path.join(options.homeDir, ".local/share"),
    OPENBURNBAR_SMARTHUB_BRIDGE_PORT: String(options.bridgePort),
  };
  function bridgeProcessIDs() {
    const result = spawnSync(
      "lsof",
      ["-nP", `-iTCP:${options.bridgePort}`, "-sTCP:LISTEN", "-t"],
      { encoding: "utf8" },
    );
    if (result.status === 1) return [];
    if (result.status !== 0)
      throw new Error("P-28 could not inspect the SmartHub bridge listener");
    return [
      ...new Set(
        result.stdout.trim().split(/\s+/u).filter(Boolean).map(Number),
      ),
    ]
      .filter(Number.isSafeInteger)
      .sort((left, right) => left - right);
  }
  return {
    platform: process.platform,
    installedVerifier: verifyInstalledCandidate,
    executableVerifier() {
      for (const executable of [CLI, DAEMON_LAUNCHER, DESKTOP]) {
        const stat = fs.lstatSync(executable);
        assert(
          stat.isFile() &&
            !stat.isSymbolicLink() &&
            stat.uid === 0 &&
            (stat.mode & 0o111) !== 0,
          `P-28 installed executable is not a root-owned regular executable: ${executable}`,
        );
      }
      for (const executable of ["python3", "avahi-browse", "systemctl", "lsof"])
        command("which", [executable]);
    },
    packageIdentity,
    daemonActive,
    desktopProcessIDs: () =>
      processIds("^/usr/bin/openburnbar-linux-desktop([[:space:]]|$)"),
    daemonProcessIDs: () =>
      processIds("^/usr/bin/openburnbar-daemon([[:space:]]|$)"),
    bridgeProcessIDs,
    compositor() {
      const displayServer = (process.env.XDG_SESSION_TYPE ?? "").toLowerCase();
      const desktop = normalizeP28DesktopIdentity(
        process.env.XDG_CURRENT_DESKTOP,
      );
      assert(
        ["x11", "wayland"].includes(displayServer),
        "P-28 could not observe X11 or Wayland session truth",
      );
      assert(desktop.trim(), "P-28 XDG_CURRENT_DESKTOP is absent");
      assert(
        process.env.DBUS_SESSION_BUS_ADDRESS,
        "P-28 desktop session bus is absent",
      );
      return {
        desktop,
        displayServer,
        display: process.env.DISPLAY ?? null,
        waylandDisplay: process.env.WAYLAND_DISPLAY ?? null,
        sessionId: process.env.XDG_SESSION_ID ?? null,
        dbusSessionBus: true,
      };
    },
    runtimeManifest: () =>
      jsonCommand(DESKTOP, ["--runtime-capabilities"], { env }),
    peerMetadata: () =>
      jsonCommand(CLI, ["local-peer", "advertise-metadata", "--json"], { env }),
    peerBrowse: () =>
      jsonCommand(CLI, ["local-peer", "browse", "--json", "--timeout", "3"], {
        env,
      }),
    discover: () =>
      jsonCommand(CLI, ["devices", "discover", "smarthub", "--json"], { env }),
    status: () =>
      jsonCommand(CLI, ["devices", "iot", "smarthub", "status", "--json"], {
        env,
      }),
    async launchDesktop() {
      child = spawn(DESKTOP, [], { env, stdio: "ignore" });
      child.unref();
      await waitFor("P-28 installed desktop", () => {
        assert(
          this.desktopProcessIDs().includes(child.pid),
          "desktop process is absent",
        );
        return true;
      });
      return child.pid;
    },
    async terminateDesktop() {
      if (!child) return;
      const pid = child.pid;
      child.kill("SIGTERM");
      await waitFor("P-28 installed desktop exit", () => {
        assert(
          !this.desktopProcessIDs().includes(pid),
          "desktop process remains alive",
        );
        return true;
      });
      child = null;
    },
    async pauseBridge() {
      const ids = bridgeProcessIDs();
      assert(
        ids.length === 1,
        "P-28 requires exactly one live SmartHub bridge listener",
      );
      bridgePid = ids[0];
      process.kill(bridgePid, "SIGSTOP");
    },
    async resumeBridge() {
      if (bridgePid === null) return;
      process.kill(bridgePid, "SIGCONT");
      bridgePid = null;
    },
    async restartDaemon() {
      command("systemctl", ["--user", "restart", "openburnbar-daemon.service"]);
      await waitFor("P-28 daemon restart", () => {
        assert(daemonActive(), "daemon service is inactive");
        return true;
      });
    },
    async atspi(state, output, context) {
      return jsonCommand(
        "python3",
        [
          "-c",
          ATSPI_SCRIPT,
          state,
          output,
          context.marker,
          context.nonce,
          String(context.pid),
          context.operation,
          context.expected,
        ],
        { env },
      );
    },
    screenshot,
  };
}

export async function runP28NativeSmartHubProbes(options, dependencies = null) {
  const startedMs = Date.now();
  const startedAt = new Date(startedMs).toISOString();
  const output = ownerEmptyDirectory(options.rawOutputDir, "raw output");
  const home = ownerEmptyDirectory(options.homeDir, "HOME");
  const support = ownerEmptyDirectory(options.supportDir, "support directory");
  assert(
    new Set([output, home, support]).size === 3,
    "P-28 evidence, HOME, and support directories must be disjoint",
  );
  const deps =
    dependencies ??
    defaultDependencies({
      ...options,
      rawOutputDir: output,
      homeDir: home,
      supportDir: support,
    });
  assert(deps.platform === "linux", "P-28 native probes require Linux");
  assert(
    /^[a-z0-9][a-z0-9._-]{7,127}$/u.test(options.marker),
    "P-28 marker is invalid",
  );
  assert(
    Number.isSafeInteger(options.bridgePort) &&
      options.bridgePort > 0 &&
      options.bridgePort <= 65_535,
    "P-28 bridge port is invalid",
  );

  const before = {
    desktopPids: deps.desktopProcessIDs(),
    daemonPids: deps.daemonProcessIDs(),
    bridgePids: deps.bridgeProcessIDs(),
    daemonActive: deps.daemonActive(),
  };
  assert(
    before.desktopPids.length === 0,
    "P-28 requires no preexisting installed desktop process",
  );
  assert(
    before.daemonActive && before.daemonPids.length === 1,
    "P-28 requires one active installed daemon",
  );
  assert(
    before.bridgePids.length === 1,
    "P-28 requires one live SmartHub bridge listener",
  );

  const nonce = crypto.randomBytes(24).toString("hex");
  let primaryPid = null;
  let relaunchPid = null;
  let bridgePaused = false;
  let primaryError = null;
  const cleanupErrors = [];
  let transcript;
  let markerDocument;
  let peerDocument;

  try {
    deps.installedVerifier(options);
    deps.executableVerifier();
    const installed = validatePackageIdentity(deps.packageIdentity());
    const compositor = deps.compositor();
    assert(
      compositor.desktop === options.desktop,
      "P-28 observed desktop does not match the requested environment",
    );
    assert(
      compositor.displayServer === options.displayServer.toLowerCase(),
      "P-28 observed display server does not match the requested environment",
    );

    const runtime = deps.runtimeManifest();
    const capability = runtime.capabilities?.find?.(
      (item) => item.id === "smarthub.control",
    );
    assert(
      capability?.state === "available",
      "P-28 installed runtime does not expose SmartHub control",
    );
    const runtimeSha256 = sha256(canonicalBytes(runtime));

    const metadata = deps.peerMetadata();
    const peers = deps.peerBrowse();
    const discovery = deps.discover();
    const matchedPeer = validatePeer(metadata, peers, discovery);
    peerDocument = {
      producer: "openburnbar-p28-live-peer-manifest-v1",
      marker: options.marker,
      nonce,
      capturedAt: new Date().toISOString(),
      source: {
        advertise: `${CLI} local-peer advertise-metadata --json`,
        browse: `${CLI} local-peer browse --json --timeout 3`,
        discovery: `${CLI} devices discover smarthub --json`,
      },
      serviceType: SERVICE_TYPE,
      platform: "linux",
      discoveryMethod: "mdns-avahi",
      transport: metadata.txt.transport,
      protocolVersion: metadata.txt.protocol_version,
      daemonVersion: metadata.txt.daemon_version,
      advertised: metadata,
      matchedPeer,
      discovery,
    };
    const peerManifestSha256 = sha256(canonicalBytes(peerDocument));

    primaryPid = await deps.launchDesktop();
    const captures = {};
    async function capture(state, operation, expected) {
      const atspiFile = path.join(output, `smarthub-${state}-atspi.json`);
      const pngFile = path.join(output, `smarthub-${state}.png`);
      const document = await deps.atspi(state, atspiFile, {
        marker: options.marker,
        nonce,
        pid: state === "recovered" ? relaunchPid : primaryPid,
        operation,
        expected,
      });
      fs.chmodSync(atspiFile, 0o600);
      validateAtspi(document, {
        marker: options.marker,
        nonce,
        state,
        pid: state === "recovered" ? relaunchPid : primaryPid,
        operation,
        expected,
        startedMs,
      });
      const atspiSha256 = inspectAtspiFile(atspiFile, document);
      deps.screenshot(pngFile);
      captures[state] = {
        atspiSha256,
        screenshotSha256: inspectScreenshot(pngFile, startedMs),
        capturedAt: document.capturedAt,
        focusedName: document.focusedName,
        statusText: document.statusText,
      };
    }

    await capture("discovered", "discover", metadata.instance);
    const controlled = deps.status();
    validateHealthyStatus(controlled, "controlled");
    await capture("controlled", "status", "bridge_control_ok");

    await deps.pauseBridge();
    bridgePaused = true;
    const degraded = await waitFor(
      "P-28 honest bridge capability loss",
      () => {
        const value = deps.status();
        validateDegradedStatus(value);
        return value;
      },
      deps.probeTimeoutMs ?? 20_000,
    );
    await capture("degraded", "status", "blocked_bridge_not_reachable");

    await deps.terminateDesktop();
    await deps.resumeBridge();
    bridgePaused = false;
    await deps.restartDaemon();
    relaunchPid = await deps.launchDesktop();
    assert(
      relaunchPid !== primaryPid,
      "P-28 desktop restart reused the stale process identity",
    );
    const recoveredPeers = deps.peerBrowse();
    const recoveredDiscovery = deps.discover();
    const recoveredPeer = validatePeer(
      metadata,
      recoveredPeers,
      recoveredDiscovery,
    );
    assert(
      JSON.stringify(recoveredPeer) === JSON.stringify(matchedPeer),
      "P-28 peer identity or transport changed after reconnect",
    );
    const recovered = await waitFor(
      "P-28 SmartHub recovery",
      () => {
        const value = deps.status();
        validateHealthyStatus(value, "recovered");
        return value;
      },
      deps.probeTimeoutMs ?? 20_000,
    );
    await capture("recovered", "status", "bridge_control_ok");

    const screenshotDigests = STATES.map(
      (state) => captures[state].screenshotSha256,
    );
    const atspiDigests = STATES.map((state) => captures[state].atspiSha256);
    assert(
      new Set(screenshotDigests).size === STATES.length,
      "P-28 screenshots are duplicated or replayed",
    );
    assert(
      new Set(atspiDigests).size === STATES.length,
      "P-28 AT-SPI evidence is duplicated or replayed",
    );

    transcript = {
      producer: "openburnbar-p28-installed-smarthub-native-v1",
      marker: options.marker,
      nonce,
      startedAt,
      endedAt: new Date().toISOString(),
      installed: {
        cli: CLI,
        daemonLauncher: DAEMON_LAUNCHER,
        desktop: DESKTOP,
        ...installed,
      },
      runtime: { manifest: runtime, sha256: runtimeSha256, capability },
      peerManifest: {
        sha256: peerManifestSha256,
        instance: metadata.instance,
        endpoint: `${matchedPeer.hostName}:${matchedPeer.port}`,
      },
      compositor,
      session: {
        fixtureMode: false,
        isolatedHome: true,
        isolatedSupport: true,
        primaryDesktopPid: primaryPid,
        relaunchDesktopPid: relaunchPid,
      },
      operations: {
        discovery: { result: discovery, peer: matchedPeer },
        controlled,
        degraded,
        recovered,
        recovery: {
          bridgeResumed: true,
          daemonRestarted: true,
          desktopRestarted: true,
          peerIdentityPersisted: true,
          healthRecovered: true,
          controlRecovered: true,
          staleHealthyResultBlocked: true,
        },
      },
      accessibility: {
        route: "smarthub",
        actionableControls: true,
        focusRestored: true,
        liveStatusObserved: true,
        captures,
      },
      restoration: {
        daemonWasActive: before.daemonActive,
        daemonActiveAfter: before.daemonActive,
        desktopPidsBefore: before.desktopPids,
        desktopPidsAfter: before.desktopPids,
        bridgePidsBefore: before.bridgePids,
        bridgePidsAfter: before.bridgePids,
        exactDesktopProcessesRestored: true,
        exactBridgeProcessesRestored: true,
        daemonServiceStateRestored: true,
      },
    };
    markerDocument = {
      producer: "openburnbar-p28-installed-marker-v1",
      marker: options.marker,
      nonce,
      installed: {
        cli: CLI,
        daemonLauncher: DAEMON_LAUNCHER,
        desktop: DESKTOP,
        ...installed,
      },
      runtimeManifestSha256: runtimeSha256,
      peerManifestSha256,
      safety: {
        fixtureMode: false,
        isolatedHome: true,
        isolatedSupport: true,
        preexistingProcesses: before,
        exactDesktopProcessesRestored: true,
        exactBridgeProcessesRestored: true,
        daemonServiceStateRestored: true,
      },
    };
  } catch (error) {
    primaryError = error;
  }

  if (bridgePaused) {
    try {
      await deps.resumeBridge();
      bridgePaused = false;
    } catch (error) {
      cleanupErrors.push(error);
    }
  }
  try {
    await deps.terminateDesktop();
  } catch (error) {
    cleanupErrors.push(error);
  }
  try {
    if (deps.daemonActive() !== before.daemonActive)
      cleanupErrors.push(new Error("P-28 daemon service state changed"));
  } catch (error) {
    cleanupErrors.push(error);
  }
  try {
    if (
      JSON.stringify(deps.desktopProcessIDs()) !==
      JSON.stringify(before.desktopPids)
    )
      cleanupErrors.push(new Error("P-28 desktop process state changed"));
  } catch (error) {
    cleanupErrors.push(error);
  }
  try {
    if (
      JSON.stringify(deps.bridgeProcessIDs()) !==
      JSON.stringify(before.bridgePids)
    )
      cleanupErrors.push(
        new Error("P-28 SmartHub bridge process state changed"),
      );
  } catch (error) {
    cleanupErrors.push(error);
  }

  if (primaryError || cleanupErrors.length) {
    throw new AggregateError(
      [...(primaryError ? [primaryError] : []), ...cleanupErrors],
      "P-28 native SmartHub probe or restoration failed",
    );
  }

  transcript.endedAt = new Date().toISOString();
  transcript.restoration.daemonActiveAfter = deps.daemonActive();
  transcript.restoration.desktopPidsAfter = deps.desktopProcessIDs();
  transcript.restoration.bridgePidsAfter = deps.bridgeProcessIDs();
  writeExclusive(
    path.join(output, "smarthub-peer-manifest.json"),
    peerDocument,
  );
  writeExclusive(
    path.join(output, "smarthub-native-transcript.json"),
    transcript,
  );
  writeExclusive(path.join(output, "smarthub-marker.json"), markerDocument);
  assert(
    fs.readdirSync(output).length === 11,
    "P-28 raw output does not contain exactly 11 artifacts",
  );
  return {
    output,
    primaryPid,
    relaunchPid,
    transcript,
    peerDocument,
    markerDocument,
  };
}

function parseArgs(argv) {
  const names = [
    "--raw-output-dir",
    "--home-dir",
    "--support-dir",
    "--environment",
    "--desktop",
    "--display-server",
    "--bridge-port",
    "--marker",
    "--target-head",
    "--candidate-run-id",
    "--candidate-artifact-digest",
    "--package-version",
    "--manifest-sha256",
    "--manifest-signature-sha256",
  ];
  const values = new Map();
  for (let index = 0; index < argv.length; index += 2) {
    const name = argv[index];
    if (
      !names.includes(name) ||
      values.has(name) ||
      argv[index + 1] === undefined
    )
      throw new Error(`invalid argument: ${name ?? "<missing>"}`);
    values.set(name, argv[index + 1]);
  }
  for (const name of names)
    if (!values.has(name)) throw new Error(`${name} is required`);
  const bridgePort = Number(values.get("--bridge-port"));
  return {
    rawOutputDir: values.get("--raw-output-dir"),
    homeDir: values.get("--home-dir"),
    supportDir: values.get("--support-dir"),
    environmentId: values.get("--environment"),
    desktop: values.get("--desktop"),
    displayServer: values.get("--display-server"),
    bridgePort,
    marker: values.get("--marker"),
    targetHead: values.get("--target-head"),
    candidateRunId: values.get("--candidate-run-id"),
    candidateArtifactDigest: values.get("--candidate-artifact-digest"),
    packageVersion: values.get("--package-version"),
    manifestSha256: values.get("--manifest-sha256"),
    manifestSignatureSha256: values.get("--manifest-signature-sha256"),
  };
}

if (
  process.argv[1] &&
  path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)
) {
  runP28NativeSmartHubProbes(parseArgs(process.argv.slice(2)))
    .then((result) =>
      process.stdout.write(`${JSON.stringify({ output: result.output })}\n`),
    )
    .catch((error) => {
      process.stderr.write(
        `P-28 native SmartHub probes failed: ${error.message}\n`,
      );
      process.exitCode = 1;
    });
}
