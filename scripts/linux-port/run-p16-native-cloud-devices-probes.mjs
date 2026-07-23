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
const DAEMON = "/usr/bin/openburnbar-daemon";
const ATSPI = path.join(ROOT, "scripts/linux-port/capture-atspi-tree.py");
const STATES = ["pending", "approved", "degraded", "recovered", "revoked"];
export const P16_COORDINATION_FILES = Object.freeze({
  request: "p16-trust-request.json",
  revokeReady: "p16-revoke-ready.json",
  receipt: "p16-mobile-receipt.json",
});

function assert(value, message) {
  if (!value) throw new Error(message);
}
function run(command, args = [], options = {}) {
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
}
function required(command, args, label, options = {}) {
  const result = run(command, args, options);
  assert(
    result.status === 0,
    `${label} failed (${result.status}): ${(result.stderr || result.stdout).trim()}`,
  );
  return result.stdout.trim();
}
function wait(milliseconds) {
  return new Promise((resolve) => setTimeout(resolve, milliseconds));
}
async function waitFor(label, operation, timeout = 120_000) {
  const deadline = Date.now() + timeout;
  let last;
  while (Date.now() < deadline) {
    try {
      return await operation();
    } catch (error) {
      last = error;
      await wait(500);
    }
  }
  throw new Error(`${label} timed out: ${last?.message ?? "unavailable"}`);
}
function privateDirectory(candidate, label, empty = false) {
  const absolute = path.resolve(candidate);
  let ancestor = absolute;
  while (!fs.existsSync(ancestor)) ancestor = path.dirname(ancestor);
  assert(
    fs.realpathSync(ancestor) === ancestor,
    `${label} traverses a symlink`,
  );
  fs.mkdirSync(absolute, { recursive: true, mode: 0o700 });
  const stat = fs.lstatSync(absolute);
  assert(
    stat.isDirectory() &&
      !stat.isSymbolicLink() &&
      stat.uid === process.getuid?.(),
    `${label} must be owned`,
  );
  assert(
    (stat.mode & 0o077) === 0 && fs.realpathSync(absolute) === absolute,
    `${label} must be canonical and owner-only`,
  );
  if (empty)
    assert(fs.readdirSync(absolute).length === 0, `${label} must be empty`);
  return absolute;
}
function disjoint(values) {
  for (let left = 0; left < values.length; left += 1) {
    for (let right = left + 1; right < values.length; right += 1) {
      const forward = path.relative(values[left], values[right]);
      const reverse = path.relative(values[right], values[left]);
      assert(
        forward && (forward.startsWith("..") || path.isAbsolute(forward)),
        "P-16 state roots overlap",
      );
      assert(
        reverse && (reverse.startsWith("..") || path.isAbsolute(reverse)),
        "P-16 state roots overlap",
      );
    }
  }
}
// Opens `absolute` without ever resolving a symlink and without inspecting the
// path first: `O_NOFOLLOW` turns a symlinked entry into `ELOOP` and
// `O_NONBLOCK` keeps a hostile FIFO from stalling the open, so every assertion
// below can be made against the descriptor we actually hold.
function openEntry(absolute, child) {
  try {
    return fs.openSync(
      absolute,
      fs.constants.O_RDONLY | fs.constants.O_NOFOLLOW | fs.constants.O_NONBLOCK,
      0o600,
    );
  } catch (error) {
    assert(error.code !== "ELOOP", `P-16 state contains symlink ${child}`);
    throw error;
  }
}
function tree(root) {
  const rows = [];
  const visit = (directory, relative = "") => {
    for (const name of fs.readdirSync(directory).sort()) {
      const absolute = path.join(directory, name);
      const child = relative ? path.join(relative, name) : name;
      const fd = openEntry(absolute, child);
      let descend = false;
      try {
        const stat = fs.fstatSync(fd);
        if (stat.isDirectory()) {
          descend = true;
          rows.push({ path: child, type: "directory", mode: stat.mode & 0o777 });
        } else {
          assert(stat.isFile(), `P-16 state contains special file ${child}`);
          rows.push({
            path: child,
            type: "file",
            mode: stat.mode & 0o777,
            sha256: sha(fs.readFileSync(fd)),
          });
        }
      } finally {
        fs.closeSync(fd);
      }
      if (descend) visit(absolute, child);
    }
  };
  visit(root);
  return rows;
}
function sha(value) {
  return crypto.createHash("sha256").update(value).digest("hex");
}
function challenge(options, marker, nonce) {
  return sha(
    [
      options.targetHead,
      String(options.candidateRunId),
      options.candidateArtifactDigest,
      marker,
      nonce,
    ].join("\n"),
  );
}
function hashIdentifier(value, label) {
  assert(
    typeof value === "string" && value.length >= 8,
    `P-16 ${label} is absent`,
  );
  return `sha256:${sha(value)}`;
}
function writeExclusiveJson(file, value) {
  const temporary = `${file}.tmp-${process.pid}-${crypto.randomBytes(4).toString("hex")}`;
  fs.writeFileSync(temporary, `${JSON.stringify(value, null, 2)}\n`, {
    flag: "wx",
    mode: 0o600,
  });
  try {
    fs.renameSync(temporary, file);
  } catch (error) {
    fs.rmSync(temporary, { force: true });
    throw error;
  }
}
function coordinationDirectory(candidate) {
  const directory = privateDirectory(candidate, "P-16 coordination directory");
  const entries = fs.readdirSync(directory);
  assert(
    entries.length === 0,
    `P-16 coordination directory must be empty (found ${entries.join(", ")})`,
  );
  return directory;
}
function environmentContract(environmentId) {
  const architecture = environmentId.endsWith("-aarch64")
    ? "aarch64"
    : "x86_64";
  if (environmentId.startsWith("ubuntu-") && environmentId.includes("-gnome-"))
    return {
      architecture,
      packageFormat: "deb",
      desktop: "GNOME",
      displayServer: environmentId.includes("-x11-") ? "X11" : "Wayland",
    };
  if (environmentId.startsWith("fedora-kde-wayland-"))
    return {
      architecture,
      packageFormat: "rpm",
      desktop: "KDE Plasma",
      displayServer: "Wayland",
    };
  if (environmentId === "arch-sway-wayland-x86_64")
    return {
      architecture,
      packageFormat: "arch",
      desktop: "Sway/wlroots",
      displayServer: "Wayland",
    };
  throw new Error("P-16 environment is unsupported");
}
function normalizeStatus(value, proofState) {
  const rawState = value?.state ?? value?.phase;
  const phase =
    typeof value?.phase === "string"
      ? value.phase
      : String(rawState ?? "unknown");
  const signedIn = value?.signedIn === true;
  const rawSync = value?.syncState ?? value?.sync_state;
  return {
    state: proofState,
    phase,
    signedIn,
    syncState:
      signedIn && ["active", "cloud-ready"].includes(rawSync)
        ? "cloud-ready"
        : "local-only",
    deviceApprovalRequired:
      value?.deviceApprovalRequired === true ||
      value?.device_approval_required === true,
    deviceIdHash: hashIdentifier(
      value?.installationDeviceID ?? value?.installation_device_id,
      "installation device ID",
    ),
    safetyFingerprintHash: hashIdentifier(
      value?.installationSafetyFingerprint ??
        value?.installation_safety_fingerprint,
      "safety fingerprint",
    ),
  };
}
function receipt(source, destination) {
  const requested = path.resolve(source);
  const fd = fs.openSync(
    requested,
    fs.constants.O_RDONLY | fs.constants.O_NOFOLLOW,
    0o600,
  );
  let raw;
  try {
    const stat = fs.fstatSync(fd);
    assert(
      stat.isFile() &&
        stat.uid === process.getuid?.() &&
        stat.nlink === 1 &&
        stat.size >= 800 &&
        stat.size <= 1024 * 1024 &&
        (stat.mode & 0o077) === 0 &&
        fs.realpathSync(requested) === requested,
      "P-16 physical-ipad receipt must be an owner-only regular file",
    );
    raw = fs.readFileSync(fd, "utf8");
  } finally {
    fs.closeSync(fd);
  }
  const value = JSON.parse(raw);
  assert(
    value?.producer === "openburnbar-p16-physical-ipad-trust-cycle-v1",
    "P-16 receipt is not a physical-ipad trust cycle",
  );
  fs.copyFileSync(requested, destination, fs.constants.COPYFILE_EXCL);
  fs.chmodSync(destination, 0o600);
  return { value, sha256: sha(fs.readFileSync(destination)) };
}
function noSecrets(value) {
  assert(
    !/(?:refresh[_-]?token|firebase[_-]?id[_-]?token|app[_-]?check[_-]?token|private[_-]?key|bearer\s)/iu.test(
      JSON.stringify(value),
    ),
    "P-16 evidence contains authentication material",
  );
}

export async function runP16CloudDevicesWorkflow(options, deps) {
  assert(
    (deps.platform ?? process.platform) === "linux" &&
      deps.desktopSession === true,
    "P-16 requires a live Linux desktop session",
  );
  const expected = environmentContract(options.environmentId);
  assert(
    options.architecture === expected.architecture &&
      options.packageFormat === expected.packageFormat &&
      options.desktop === expected.desktop &&
      options.displayServer === expected.displayServer,
    "P-16 invocation does not match its support row",
  );
  const raw = privateDirectory(options.rawOutputDir, "P-16 raw output", true);
  const home = privateDirectory(options.stateHome, "P-16 isolated state", true);
  disjoint([raw, home]);
  (deps.installedVerifier ?? verifyInstalledCandidate)(options);
  for (const name of [
    "identity",
    "launch",
    "terminate",
    "prepareTrustCycle",
    "publishTrustRequest",
    "publishRevocationReady",
    "awaitMobileReceipt",
    "waitStatus",
    "daemonActive",
    "setDaemonActive",
    "reload",
    "restart",
    "capture",
    "restoreState",
    "desktopPids",
  ])
    assert(
      typeof deps[name] === "function",
      `P-16 ${name} production adapter is required`,
    );
  const marker = deps.marker ?? `p16-${crypto.randomBytes(8).toString("hex")}`;
  const nonce = deps.nonce ?? crypto.randomBytes(16).toString("hex");
  assert(
    /^p16-[a-f0-9]{16}$/u.test(marker) && /^[a-f0-9]{32}$/u.test(nonce),
    "P-16 marker or nonce is invalid",
  );
  const startedAt = (deps.clock?.() ?? new Date()).toISOString();
  const serviceBefore = deps.daemonActive();
  const pidsBefore = deps.desktopPids();
  const stateBefore = tree(home);
  assert(
    pidsBefore.length === 0,
    "P-16 requires no pre-existing installed desktop process",
  );
  let primaryError;
  const cleanupErrors = [];
  let transcript;
  let markerDocument;
  try {
    if (!serviceBefore) await deps.setDaemonActive(true);
    const identity = deps.identity();
    await deps.launch();
    await deps.prepareTrustCycle();
    const pending = normalizeStatus(
      await deps.waitStatus("pending"),
      "authorizing",
    );
    assert(
      pending.deviceApprovalRequired && pending.signedIn,
      "P-16 pending approval state is absent",
    );
    const requestDocument = {
      producer: "openburnbar-p16-linux-trust-cycle-request-v1",
      requestedAt: (deps.clock?.() ?? new Date()).toISOString(),
      targetHead: options.targetHead,
      candidate: {
        runId: options.candidateRunId,
        artifactDigest: options.candidateArtifactDigest,
      },
      marker,
      challenge: challenge(options, marker, nonce),
      linux: {
        deviceIdHash: pending.deviceIdHash,
        safetyFingerprintHash: pending.safetyFingerprintHash,
      },
    };
    writeExclusiveJson(
      path.join(raw, "cloud-devices-coordination-request.json"),
      requestDocument,
    );
    await deps.publishTrustRequest(requestDocument);
    await deps.capture(
      "pending",
      path.join(raw, "cloud-devices-pending-atspi.json"),
      path.join(raw, "cloud-devices-pending.png"),
    );
    const approved = normalizeStatus(
      await deps.waitStatus("approved"),
      "active",
    );
    assert(
      approved.signedIn && approved.syncState === "cloud-ready",
      "P-16 physical approval did not activate cloud sync",
    );
    await deps.capture(
      "approved",
      path.join(raw, "cloud-devices-approved-atspi.json"),
      path.join(raw, "cloud-devices-approved.png"),
    );
    await deps.setDaemonActive(false);
    await deps.reload();
    const degradedResult = await deps.waitStatus("degraded");
    assert(
      degradedResult?.errorVisible === true &&
        degradedResult?.optimisticSuccess === false,
      "P-16 daemon loss was not explicit and fail closed",
    );
    await deps.capture(
      "degraded",
      path.join(raw, "cloud-devices-degraded-atspi.json"),
      path.join(raw, "cloud-devices-degraded.png"),
    );
    await deps.setDaemonActive(true);
    await deps.reload();
    const recovered = normalizeStatus(
      await deps.waitStatus("recovered"),
      "active",
    );
    await deps.capture(
      "recovered",
      path.join(raw, "cloud-devices-recovered-atspi.json"),
      path.join(raw, "cloud-devices-recovered.png"),
    );
    await deps.restart();
    const restarted = normalizeStatus(
      await deps.waitStatus("restarted"),
      "active",
    );
    assert(
      JSON.stringify(recovered) === JSON.stringify(restarted),
      "P-16 account state did not persist across installed-app restart",
    );
    const revokeReadyDocument = {
      producer: "openburnbar-p16-linux-revoke-ready-v1",
      observedAt: (deps.clock?.() ?? new Date()).toISOString(),
      targetHead: options.targetHead,
      candidate: {
        runId: options.candidateRunId,
        artifactDigest: options.candidateArtifactDigest,
      },
      marker,
      challenge: requestDocument.challenge,
      linux: requestDocument.linux,
      approvedStateObserved: true,
      restartPersistenceObserved: true,
    };
    writeExclusiveJson(
      path.join(raw, "cloud-devices-revocation-ready.json"),
      revokeReadyDocument,
    );
    await deps.publishRevocationReady(revokeReadyDocument);
    const revoked = normalizeStatus(
      await deps.waitStatus("revoked"),
      "unavailable",
    );
    assert(
      revoked.signedIn && revoked.syncState === "local-only",
      "P-16 physical revocation was not enforced",
    );
    await deps.capture(
      "revoked",
      path.join(raw, "cloud-devices-revoked-atspi.json"),
      path.join(raw, "cloud-devices-revoked.png"),
    );
    await deps.awaitMobileReceipt();
    const mobile = receipt(
      options.mobileReceipt,
      path.join(raw, "cloud-devices-mobile-receipt.json"),
    );
    assert(
      mobile.value?.linux?.marker === marker,
      "P-16 mobile receipt targets another Linux session",
    );
    const endedAt = (deps.clock?.() ?? new Date()).toISOString();
    transcript = {
      producer: "openburnbar-p16-installed-cloud-devices-probe-v1",
      marker,
      challenge: challenge(options, marker, nonce),
      startedAt,
      endedAt,
      account: { pending, approved, revoked, recovered, restarted },
      mobile: {
        approvalAuthority: "physical-ipad",
        callables: [
          "listLinuxAppCheckDevices",
          "approveLinuxAppCheckDevice",
          "revokeLinuxAppCheckDevice",
        ],
        receiptSha256: mobile.sha256,
      },
      degradation: {
        daemonStopped: true,
        errorVisible: true,
        optimisticSuccess: false,
        recovered: true,
        restartPersistent: true,
      },
      restoration: {
        daemonActiveBefore: serviceBefore,
        daemonActiveAfter: serviceBefore,
        desktopPidsBefore: pidsBefore,
        desktopPidsAfter: pidsBefore,
        isolatedStateRestored: true,
        cloudDevicesRestored: true,
        noSecretsRecorded: true,
      },
    };
    noSecrets(transcript);
    markerDocument = {
      producer: transcript.producer,
      marker,
      nonce,
      challenge: transcript.challenge,
      installed: {
        desktop: DESKTOP,
        daemon: DAEMON,
        packageName: identity.packageName,
        packageOwned: identity.packageOwned,
      },
      package: {
        architecture: options.architecture,
        format: options.packageFormat,
        manifestSha256: options.manifestSha256,
        version: options.packageVersion,
      },
    };
  } catch (error) {
    primaryError = error;
  }
  try {
    await deps.terminate();
  } catch (error) {
    cleanupErrors.push(error);
  }
  try {
    await deps.setDaemonActive(serviceBefore);
  } catch (error) {
    cleanupErrors.push(error);
  }
  try {
    await deps.restoreState(stateBefore);
  } catch (error) {
    cleanupErrors.push(error);
  }
  try {
    assert(deps.daemonActive() === serviceBefore, "P-16 daemon state changed");
    assert(
      JSON.stringify(deps.desktopPids()) === JSON.stringify(pidsBefore),
      "P-16 installed desktop process state changed",
    );
    assert(
      JSON.stringify(tree(home)) === JSON.stringify(stateBefore),
      "P-16 isolated state changed",
    );
  } catch (error) {
    cleanupErrors.push(error);
  }
  if (primaryError || cleanupErrors.length)
    throw primaryError && cleanupErrors.length
      ? new AggregateError(
          [primaryError, ...cleanupErrors],
          "P-16 workflow and restoration failed",
        )
      : (primaryError ??
          new AggregateError(cleanupErrors, "P-16 restoration failed"));
  fs.writeFileSync(
    path.join(raw, "cloud-devices-native-transcript.json"),
    `${JSON.stringify(transcript, null, 2)}\n`,
    { flag: "wx", mode: 0o600 },
  );
  fs.writeFileSync(
    path.join(raw, "cloud-devices-marker.json"),
    `${JSON.stringify(markerDocument, null, 2)}\n`,
    { flag: "wx", mode: 0o600 },
  );
  return { rawOutputDir: raw, transcript, marker: markerDocument };
}

function desktopPids() {
  const result = run("pgrep", [
    "-f",
    "^/usr/bin/openburnbar-linux-desktop([[:space:]]|$)",
  ]);
  if (result.status === 1) return [];
  assert(
    result.status === 0,
    "P-16 could not inspect installed desktop processes",
  );
  return result.stdout
    .trim()
    .split(/\s+/u)
    .filter(Boolean)
    .map(Number)
    .filter(Number.isSafeInteger)
    .sort((a, b) => a - b);
}
function serviceActive() {
  const result = run("systemctl", [
    "--user",
    "is-active",
    "--quiet",
    "openburnbar-daemon.service",
  ]);
  assert(
    [0, 3].includes(result.status),
    "P-16 could not inspect daemon service",
  );
  return result.status === 0;
}
function screenshot(file) {
  for (const [command, args] of [
    ["gnome-screenshot", ["-f", file]],
    ["spectacle", ["-b", "-n", "-o", file]],
    ["grim", [file]],
    ["scrot", ["--overwrite", "--focused", file]],
  ]) {
    const result = run(command, args);
    if (result.status === 0 && fs.existsSync(file)) {
      fs.chmodSync(file, 0o600);
      return;
    }
  }
  throw new Error("P-16 could not capture a live installed-app screenshot");
}
async function reservePort() {
  return new Promise((resolve, reject) => {
    const server = net.createServer();
    server.once("error", reject);
    server.listen(0, "127.0.0.1", () => {
      const address = server.address();
      server.close((error) => (error ? reject(error) : resolve(address.port)));
    });
  });
}
async function request(base, method, endpoint, body) {
  const response = await fetch(new URL(endpoint, base), {
    method,
    headers:
      body === undefined ? undefined : { "content-type": "application/json" },
    body: body === undefined ? undefined : JSON.stringify(body),
    signal: AbortSignal.timeout(30_000),
  });
  const text = await response.text();
  const value = text ? JSON.parse(text) : null;
  if (!response.ok)
    throw new Error(
      `P-16 WebDriver ${method} ${endpoint} failed (${response.status})`,
    );
  return value?.value ?? value;
}
function driver(env) {
  let child;
  let sessionId;
  let base;
  return {
    async start() {
      required("which", ["tauri-driver"], "P-16 WebDriver prerequisites", { env });
      required("which", ["WebKitWebDriver"], "P-16 WebDriver prerequisites", { env });
      const port = await reservePort();
      base = `http://127.0.0.1:${port}/`;
      child = spawn("tauri-driver", ["--port", String(port)], {
        env,
        stdio: "ignore",
      });
      await waitFor(
        "P-16 tauri-driver",
        () => request(base, "GET", "/status"),
        30_000,
      );
      const session = await request(base, "POST", "/session", {
        capabilities: {
          alwaysMatch: {
            browserName: "wry",
            "tauri:options": { application: DESKTOP },
          },
        },
      });
      sessionId = session?.sessionId;
      assert(sessionId, "P-16 WebDriver session is absent");
      await this.route();
    },
    execute(script, args = [], async = false) {
      assert(sessionId, "P-16 WebDriver inactive");
      return request(
        base,
        "POST",
        `/session/${sessionId}/execute/${async ? "async" : "sync"}`,
        { script, args },
      );
    },
    async invokeResult(command, payload = {}) {
      return this.execute(
        "const done=arguments[arguments.length-1];window.__TAURI_INTERNALS__.invoke(arguments[0],arguments[1]).then(v=>done({ok:true,value:v}),e=>done({ok:false,error:String(e)}));",
        [command, payload],
        true,
      );
    },
    async invoke(command, payload = {}) {
      const result = await this.invokeResult(command, payload);
      assert(
        result?.ok,
        `P-16 Tauri ${command} failed: ${result?.error ?? "unknown"}`,
      );
      return result.value;
    },
    route() {
      return this.execute(
        "window.location.hash='#/account';window.dispatchEvent(new HashChangeEvent('hashchange'));return true;",
      );
    },
    async stop() {
      if (sessionId) {
        try {
          await request(base, "DELETE", `/session/${sessionId}`);
        } catch {}
      }
      sessionId = null;
      if (child) {
        child.kill("SIGTERM");
        await wait(300);
      }
      child = null;
    },
  };
}
function packageIdentity(options) {
  const manager =
    options.packageFormat === "deb"
      ? "dpkg"
      : options.packageFormat === "rpm"
        ? "rpm"
        : "pacman";
  const packageName =
    options.packageFormat === "arch" ? "openburnbar" : "open-burn-bar";
  for (const file of [DESKTOP, DAEMON]) {
    const stat = fs.lstatSync(file);
    assert(
      stat.isFile() &&
        !stat.isSymbolicLink() &&
        stat.uid === 0 &&
        (stat.mode & 0o022) === 0,
      `P-16 unsafe installed file ${file}`,
    );
    const output =
      manager === "dpkg"
        ? required("dpkg-query", ["-S", file], "P-16 dpkg owner")
        : manager === "rpm"
          ? required("rpm", ["-qf", file], "P-16 rpm owner")
          : required("pacman", ["-Qo", file], "P-16 pacman owner");
    assert(
      output.includes(packageName),
      `P-16 substitute package owns ${file}`,
    );
  }
  return { packageName, packageOwned: true };
}

export function createP16ProductionDependencies(options) {
  const runtime =
    process.env.XDG_RUNTIME_DIR ?? `/run/user/${process.getuid?.()}`;
  const data =
    process.env.XDG_DATA_HOME ?? path.join(process.env.HOME, ".local/share");
  const socket = path.join(runtime, "openburnbar/daemon.sock");
  const token = path.join(data, "openburnbar/daemon-socket-auth-token");
  const coordination = coordinationDirectory(options.coordinationDir);
  const expectedReceipt = path.join(
    coordination,
    P16_COORDINATION_FILES.receipt,
  );
  assert(
    path.resolve(options.mobileReceipt ?? expectedReceipt) === expectedReceipt,
    `P-16 mobile receipt must be ${expectedReceipt}`,
  );
  assert(fs.lstatSync(socket).isSocket(), "P-16 daemon socket is absent");
  const tokenStat = fs.lstatSync(token);
  assert(
    tokenStat.isFile() &&
      !tokenStat.isSymbolicLink() &&
      tokenStat.uid === process.getuid?.() &&
      (tokenStat.mode & 0o077) === 0,
    "P-16 daemon token is unsafe",
  );
  const env = {
    ...process.env,
    HOME: options.stateHome,
    XDG_CONFIG_HOME: path.join(options.stateHome, ".config"),
    XDG_DATA_HOME: path.join(options.stateHome, ".local/share"),
    XDG_RUNTIME_DIR: runtime,
    OPENBURNBAR_DAEMON_SOCKET_PATH: socket,
    OPENBURNBAR_DAEMON_SOCKET_AUTH_TOKEN_FILE: token,
    OPENBURNBAR_LINUX_FIXTURE_MODE: "0",
  };
  let control = driver(env);
  const expectedText = {
    pending: "approval",
    approved: "cloud",
    degraded: "unavailable",
    recovered: "cloud",
    revoked: "unavailable",
  };
  async function statusFor(kind) {
    if (kind === "degraded") {
      const result = await control.invokeResult("account_status");
      assert(result?.ok === false, "daemon call unexpectedly succeeded");
      return { errorVisible: true, optimisticSuccess: false };
    }
    const raw = await control.invoke("account_status");
    if (kind === "pending")
      assert(
        raw?.deviceApprovalRequired === true ||
          raw?.state === "awaiting-device-approval",
        "not pending",
      );
    if (["approved", "recovered", "restarted"].includes(kind))
      assert(
        raw?.signedIn === true &&
          ["active", "cloud-ready"].includes(raw?.syncState),
        "not approved",
      );
    if (kind === "revoked")
      assert(
        raw?.signedIn === true &&
          raw?.state === "unavailable" &&
          !raw?.deviceApprovalRequired,
        "not revoked",
      );
    return raw;
  }
  return {
    platform: process.platform,
    desktopSession: Boolean(process.env.DISPLAY || process.env.WAYLAND_DISPLAY),
    installedVerifier: verifyInstalledCandidate,
    identity: () => packageIdentity(options),
    desktopPids,
    daemonActive: serviceActive,
    async setDaemonActive(active) {
      if (serviceActive() !== active)
        required(
          "systemctl",
          ["--user", active ? "start" : "stop", "openburnbar-daemon.service"],
          `P-16 ${active ? "start" : "stop"} daemon`,
        );
      await waitFor(
        "P-16 daemon transition",
        () => {
          assert(serviceActive() === active, "daemon transition pending");
          return true;
        },
        30_000,
      );
    },
    async launch() {
      assert(desktopPids().length === 0, "P-16 installed desktop already runs");
      await control.start();
    },
    async terminate() {
      await control.stop();
      await waitFor(
        "P-16 installed desktop exit",
        () => {
          assert(desktopPids().length === 0, "desktop still runs");
          return true;
        },
        30_000,
      );
    },
    async prepareTrustCycle() {
      await control.invoke("account_rotate_identity");
    },
    async publishTrustRequest(document) {
      writeExclusiveJson(
        path.join(coordination, P16_COORDINATION_FILES.request),
        document,
      );
    },
    async publishRevocationReady(document) {
      writeExclusiveJson(
        path.join(coordination, P16_COORDINATION_FILES.revokeReady),
        document,
      );
    },
    async awaitMobileReceipt() {
      await waitFor(
        "P-16 physical-iPad receipt",
        () => {
          assert(fs.existsSync(expectedReceipt), "receipt not published");
          return true;
        },
        10 * 60_000,
      );
    },
    waitStatus: (kind) => waitFor(`P-16 ${kind} state`, () => statusFor(kind)),
    async reload() {
      await control.route();
      await wait(1_000);
    },
    async restart() {
      await control.stop();
      control = driver(env);
      await control.start();
    },
    async capture(state, accessibility, image) {
      const temporary = `${accessibility}.raw`;
      required(
        "python3",
        [
          ATSPI,
          "--application",
          "OpenBurnBar",
          "--mode",
          "summary",
          "--expected-name",
          expectedText[state],
          "--route",
          "account",
          "--output",
          temporary,
          "--min-nodes",
          "12",
          "--min-named",
          "6",
          "--min-actionable",
          "1",
          "--wait-for-meaningful-seconds",
          "10",
        ],
        `P-16 ${state} AT-SPI`,
      );
      const raw = JSON.parse(fs.readFileSync(temporary, "utf8"));
      fs.rmSync(temporary, { force: true });
      assert(
        raw.pass === true && raw.expectedNamePresent === true,
        `P-16 ${state} AT-SPI state is not visible`,
      );
      const names = (raw.namedSamples ?? [])
        .map((node) => (typeof node === "string" ? node : node?.name))
        .filter(Boolean);
      const focused = (raw.focusedNodes ?? [])
        .map((node) => (typeof node === "string" ? node : node?.name))
        .find(Boolean);
      const visibleStatus = names.join(" | ");
      assert(
        new RegExp(expectedText[state], "iu").test(visibleStatus),
        `P-16 ${state} AT-SPI status is not present in the live tree`,
      );
      const document = {
        producer: "openburnbar-p16-atspi-live-v1",
        capturedAt: new Date().toISOString(),
        application: "OpenBurnBar",
        route: "account",
        focusedName: focused ?? names[0] ?? "Account",
        statusText: visibleStatus,
        namedNodes: names.slice(0, 100),
      };
      assert(
        document.namedNodes.length >= 6,
        `P-16 ${state} AT-SPI tree is incomplete`,
      );
      fs.writeFileSync(
        accessibility,
        `${JSON.stringify(document, null, 2)}\n`,
        { flag: "wx", mode: 0o600 },
      );
      screenshot(image);
    },
    async restoreState(snapshot) {
      assert(
        snapshot.length === 0,
        "P-16 isolated state was not initially empty",
      );
      for (const name of fs.readdirSync(options.stateHome))
        fs.rmSync(path.join(options.stateHome, name), {
          recursive: true,
          force: true,
        });
    },
  };
}

export function parseP16Arguments(argv) {
  const names = [
    "--raw-output-dir",
    "--state-home",
    "--mobile-receipt",
    "--coordination-dir",
    "--environment",
    "--target-head",
    "--candidate-run-id",
    "--candidate-artifact-digest",
    "--package-version",
    "--manifest-sha256",
    "--manifest-signature-sha256",
    "--architecture",
    "--package-format",
    "--desktop",
    "--display-server",
  ];
  const optional = new Set(["--mobile-receipt"]);
  const values = new Map();
  for (let index = 0; index < argv.length; index += 2) {
    if (
      !names.includes(argv[index]) ||
      values.has(argv[index]) ||
      argv[index + 1] === undefined
    )
      throw new Error(`invalid argument: ${argv[index] ?? "<missing>"}`);
    values.set(argv[index], argv[index + 1]);
  }
  for (const name of names)
    if (!optional.has(name) && !values.has(name))
      throw new Error(`${name} is required`);
  const parsed = Object.fromEntries(
    names.map((name) => [
      name
        .slice(2)
        .replace(/-([a-z])/gu, (_match, letter) => letter.toUpperCase()),
      values.get(name),
    ]),
  );
  parsed.mobileReceipt ??= path.join(
    parsed.coordinationDir,
    P16_COORDINATION_FILES.receipt,
  );
  return parsed;
}
export async function runP16Production(argv, injected = {}) {
  const options = parseP16Arguments(argv);
  return (injected.runWorkflow ?? runP16CloudDevicesWorkflow)(
    options,
    (injected.createDependencies ?? createP16ProductionDependencies)(options),
  );
}
if (
  process.argv[1] &&
  path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)
) {
  runP16Production(process.argv.slice(2))
    .then((result) =>
      process.stdout.write(
        `${JSON.stringify({ output: result.rawOutputDir })}\n`,
      ),
    )
    .catch((error) => {
      process.stderr.write(
        `P-16 installed cloud/devices probe failed: ${error.message}\n`,
      );
      process.exitCode = 1;
    });
}
