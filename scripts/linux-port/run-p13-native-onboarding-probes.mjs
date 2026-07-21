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
const DAEMON_LAUNCHER = "/usr/libexec/openburnbar-daemon-launch";
const CONTROL = path.join(ROOT, "scripts/linux-port/p13-atspi-control.py");

function assert(value, message) {
  if (!value) throw new Error(message);
}
function sleep(ms) {
  return new Promise((resolve) => setTimeout(resolve, ms));
}
function writeExclusive(file, value) {
  const descriptor = fs.openSync(
    file,
    fs.constants.O_WRONLY | fs.constants.O_CREAT | fs.constants.O_EXCL,
    0o600,
  );
  try {
    fs.writeFileSync(descriptor, value);
    fs.fsyncSync(descriptor);
  } finally {
    fs.closeSync(descriptor);
  }
}
function writeJson(file, value) {
  writeExclusive(file, Buffer.from(`${JSON.stringify(value, null, 2)}\n`));
}
function ownerOnlyDirectory(directory, label, { empty = false } = {}) {
  fs.mkdirSync(path.resolve(directory), { recursive: true, mode: 0o700 });
  const stat = fs.lstatSync(directory);
  assert(
    stat.isDirectory() &&
      !stat.isSymbolicLink() &&
      stat.uid === process.getuid?.() &&
      (stat.mode & 0o077) === 0,
    `${label} must be an owner-only real directory`,
  );
  const resolved = fs.realpathSync(directory);
  if (empty)
    assert(fs.readdirSync(resolved).length === 0, `${label} must be empty`);
  return resolved;
}
function readToken(file) {
  const stat = fs.lstatSync(file);
  assert(
    stat.isFile() &&
      !stat.isSymbolicLink() &&
      stat.uid === process.getuid?.() &&
      (stat.mode & 0o077) === 0,
    "P-13 daemon token must be an owner-only regular file",
  );
  const value = fs.readFileSync(file, "utf8").trim();
  assert(
    value.length >= 32 && !/[\r\n]/u.test(value),
    "P-13 daemon token is invalid",
  );
  return value;
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
      return {
        pid: child.pid,
        kill: (signal = "SIGTERM") => child.kill(signal),
      };
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
    `P-13 desktop preflight failed: ${(result.stderr || result.stdout).trim()}`,
  );
  return result.stdout
    .trim()
    .split(/\s+/u)
    .filter(Boolean)
    .map(Number)
    .filter(Number.isSafeInteger);
}
async function waitFor(label, operation, timeoutMs = 20_000) {
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
function environment(options) {
  return {
    ...process.env,
    HOME: options.homeDir,
    XDG_CONFIG_HOME: path.join(options.homeDir, ".config"),
    XDG_DATA_HOME: path.join(options.homeDir, ".local/share"),
    OPENBURNBAR_DAEMON_SUPPORT_DIR: options.supportDir,
    OPENBURNBAR_DAEMON_SOCKET_PATH: options.socketPath,
    OPENBURNBAR_DAEMON_SOCKET_AUTH_TOKEN_FILE: options.tokenFile,
    OPENBURNBAR_INDEX_DATABASE_PATH: options.indexDatabase,
  };
}
function rpcClient(options, authToken) {
  let sequence = 0;
  return (method, params) =>
    new Promise((resolve, reject) => {
      const socket = net.createConnection(options.socketPath);
      let buffer = "";
      let settled = false;
      const finish = (callback, value) => {
        if (settled) return;
        settled = true;
        socket.destroy();
        callback(value);
      };
      socket.setEncoding("utf8");
      socket.setTimeout(10_000, () =>
        finish(reject, new Error(`P-13 RPC timed out: ${method}`)),
      );
      socket.on("error", (error) => finish(reject, error));
      socket.on("connect", () =>
        socket.write(
          `${JSON.stringify({ protocolVersion: 1, id: `p13-${++sequence}`, method, traceId: `p13-trace-${sequence}`, authToken, params })}\n`,
        ),
      );
      socket.on("data", (chunk) => {
        buffer += chunk;
        const newline = buffer.indexOf("\n");
        if (newline < 0) return;
        try {
          const document = JSON.parse(buffer.slice(0, newline));
          if (document.error)
            finish(
              reject,
              new Error(document.error.message ?? `P-13 RPC failed: ${method}`),
            );
          else finish(resolve, document.result);
        } catch (error) {
          finish(reject, error);
        }
      });
    });
}
function daemonController(runner, options) {
  let child = null;
  let wasActive = false;
  const env = environment(options);
  const stopChild = async () => {
    if (!child) return;
    child.kill();
    await waitFor(`P-13 daemon PID ${child.pid} exit`, () => {
      const result = runner.run("kill", ["-0", String(child.pid)]);
      assert(result.status !== 0, "daemon is still running");
      return true;
    });
    child = null;
  };
  const launch = async (label) => {
    fs.rmSync(options.socketPath, { force: true });
    const log = fs.openSync(
      path.join(options.rawOutputDir, `daemon-${label}.log`),
      "wx",
      0o600,
    );
    const process = spawn(
      DAEMON_LAUNCHER,
      ["--version", `p13-installed-${label}`],
      { env, stdio: ["ignore", log, log] },
    );
    process.unref();
    fs.closeSync(log);
    child = process;
    await waitFor(`P-13 daemon ${label}`, () => {
      assert(
        fs.existsSync(options.socketPath) &&
          fs.lstatSync(options.socketPath).isSocket(),
        "daemon socket is absent",
      );
      return true;
    });
  };
  return {
    async prepare() {
      const status = runner.run("systemctl", [
        "--user",
        "is-active",
        "--quiet",
        "openburnbar-daemon.service",
      ]);
      wasActive = status.status === 0;
      assert(
        [0, 3].includes(status.status),
        "P-13 could not determine the user daemon state",
      );
      if (wasActive)
        required(
          runner,
          "systemctl",
          ["--user", "stop", "openburnbar-daemon.service"],
          "stop user daemon",
        );
      await launch("initial");
    },
    async restart() {
      await stopChild();
      await launch("restart");
    },
    async restore() {
      await stopChild();
      if (wasActive)
        required(
          runner,
          "systemctl",
          ["--user", "start", "openburnbar-daemon.service"],
          "restore user daemon",
        );
    },
  };
}
function atspi(runner, output, suffix, mode, name = null) {
  const file = path.join(output, `.p13-atspi-${suffix}.json`);
  const args = [CONTROL, "--mode", mode, "--output", file];
  if (name) args.push("--name", name);
  required(runner, "python3", args, `P-13 AT-SPI ${suffix}`);
  const document = JSON.parse(fs.readFileSync(file, "utf8"));
  fs.rmSync(file);
  return document;
}
function names(tree) {
  return (tree.nodes ?? [])
    .map((node) => String(node.name ?? ""))
    .filter(Boolean);
}
function includes(tree, text) {
  return names(tree).some((name) => name.includes(text));
}
function defaultUI(runner, options) {
  let app = null;
  return {
    async launch() {
      app = runner.start(DESKTOP, ["openburnbar://onboarding"], {
        env: environment(options),
      });
      assert(
        Number.isSafeInteger(app.pid) && app.pid > 1,
        "P-13 desktop returned no PID",
      );
      await waitFor("P-13 installed desktop window", () => {
        const result = runner.run("xdotool", [
          "search",
          "--onlyvisible",
          "--pid",
          String(app.pid),
          "--name",
          "^OpenBurnBar",
        ]);
        assert(
          result.status === 0 &&
            result.stdout.trim().split(/\s+/u).filter(Boolean).length === 1,
          "installed window is absent",
        );
        return true;
      });
      await sleep(800);
      return { pid: app.pid };
    },
    snapshot(label) {
      return atspi(runner, options.rawOutputDir, label, "snapshot");
    },
    screenshot(name) {
      const file = path.join(options.rawOutputDir, name);
      required(
        runner,
        "scrot",
        ["--overwrite", "--focused", file],
        `P-13 ${name}`,
      );
      assert(fs.statSync(file).size > 1024, `P-13 ${name} is empty`);
      return file;
    },
    async activate(name, label) {
      const result = atspi(
        runner,
        options.rawOutputDir,
        label,
        "activate",
        name,
      );
      await sleep(800);
      return result;
    },
    async stop() {
      if (!app) return;
      const pid = app.pid;
      app.kill();
      await waitFor(`P-13 desktop PID ${pid} exit`, () => {
        const result = runner.run("kill", ["-0", String(pid)]);
        assert(result.status !== 0, "desktop is still running");
        return true;
      });
      app = null;
    },
  };
}
function timestamp(clock) {
  const value = Math.max(Date.now(), clock.value + 1);
  clock.value = value;
  return new Date(value).toISOString();
}
function providerID(row) {
  return String(row?.id ?? row?.providerID ?? "").trim();
}
function snapshotOf(result) {
  return result?.snapshot ?? result;
}

export async function runP13NativeOnboardingProbes(options, dependencies = {}) {
  assert(
    (dependencies.platform ?? process.platform) === "linux",
    "P-13 native probe must execute on Linux",
  );
  assert(
    dependencies.desktopSession ??
      (process.env.DBUS_SESSION_BUS_ADDRESS && process.env.DISPLAY),
    "P-13 requires a live Linux X11 desktop and D-Bus session",
  );
  (dependencies.installedVerifier ?? verifyInstalledCandidate)(options);
  options.rawOutputDir = ownerOnlyDirectory(
    options.rawOutputDir,
    "P-13 raw output",
    { empty: true },
  );
  options.supportDir = ownerOnlyDirectory(
    options.supportDir,
    "P-13 support directory",
  );
  options.homeDir = ownerOnlyDirectory(options.homeDir, "P-13 isolated home", {
    empty: true,
  });
  const authToken = readToken(options.tokenFile);
  assert(
    path.dirname(fs.realpathSync(options.tokenFile)) === options.supportDir,
    "P-13 token must be inside support directory",
  );
  assert(
    JSON.stringify(fs.readdirSync(options.supportDir).sort()) ===
      JSON.stringify([path.basename(options.tokenFile)]),
    "P-13 support directory must contain only its token",
  );
  assert(
    path.dirname(path.resolve(options.indexDatabase)) === options.supportDir &&
      !fs.existsSync(options.indexDatabase),
    "P-13 index database must be a missing support-directory child",
  );
  const runner = dependencies.runner ?? commandRunner();
  const processIDs = (
    dependencies.desktopProcessIDs ?? (() => installedDesktopPids(runner))
  )();
  assert(
    Array.isArray(processIDs) && processIDs.length === 0,
    "P-13 requires no pre-existing installed desktop process",
  );
  if (!dependencies.ui)
    for (const command of ["python3", "xdotool", "scrot"])
      required(
        runner,
        "sh",
        ["-c", 'command -v "$1" >/dev/null', "p13-tool", command],
        `required tool ${command}`,
      );
  const marker =
    dependencies.marker ?? `p13-${crypto.randomBytes(8).toString("hex")}`;
  assert(/^p13-[a-f0-9]{16}$/u.test(marker), "P-13 marker is invalid");
  const daemon = dependencies.daemon ?? daemonController(runner, options);
  const rpc = dependencies.rpc ?? rpcClient(options, authToken);
  const ui = dependencies.ui ?? defaultUI(runner, options);
  const events = [];
  const uiEvents = [];
  const uiActions = [];
  const clock = { value: 0 };
  let app = null;
  let prepared = false;
  let credential = null;
  const call = async (
    phase,
    method,
    request,
    { evidenceRequest = request, expectFailure = false } = {},
  ) => {
    try {
      const result = await rpc(method, request);
      if (expectFailure) throw new Error(`${phase} unexpectedly succeeded`);
      events.push({
        phase,
        at: timestamp(clock),
        method,
        request: evidenceRequest,
        ok: true,
        error: null,
        result,
      });
      return result;
    } catch (error) {
      if (expectFailure && error.message === `${phase} unexpectedly succeeded`)
        throw error;
      if (!expectFailure) {
        events.push({
          phase,
          at: timestamp(clock),
          method,
          request,
          ok: false,
          error: error.message,
          result: null,
        });
        throw error;
      }
      events.push({
        phase,
        at: timestamp(clock),
        method,
        request: evidenceRequest,
        ok: false,
        error: error.message,
        result: null,
      });
      return null;
    }
  };
  const recordUI = (phase, observed) => {
    const tree = ui.snapshot(phase);
    uiEvents.push({
      phase,
      at: timestamp(clock),
      appPid: app.pid,
      marker,
      manifestSha256: options.manifestSha256,
      observed: observed(tree),
    });
    return tree;
  };
  const stopUI = async () => {
    if (!app) return;
    await ui.stop();
    app = null;
  };
  const launchUI = async () => {
    app = await ui.launch();
  };
  const action = async (phase, name) => {
    uiActions.push({
      phase,
      at: timestamp(clock),
      result: await ui.activate(name, phase),
    });
  };
  try {
    await daemon.prepare();
    prepared = true;
    const reset = await call("reset", "daemon.onboarding.reset", {});
    assert(
      reset.currentStepID === "daemon" && reset.completed === false,
      "P-13 reset did not restore the initial gate",
    );
    await call(
      "completion-gate-rejected",
      "daemon.onboarding.action",
      {
        stepID: "privacy",
        action: "save_privacy_choices",
        telemetryEnabled: false,
        cloudSyncEnabled: false,
      },
      { expectFailure: true },
    );
    await call("daemon-verified", "daemon.onboarding.action", {
      stepID: "daemon",
      action: "verify",
    });
    await call("secret-store-verified", "daemon.onboarding.action", {
      stepID: "secret_store",
      action: "verify",
    });

    await launchUI();
    const providerTree = recordUI("provider-setup", (tree) => ({
      catalogVisible:
        includes(tree, "Connect a provider") && includes(tree, "Provider"),
      credentialFieldVisible:
        includes(tree, "API key") && includes(tree, "Credential label"),
      secureStorageCopyVisible: includes(tree, "native Secret Service"),
    }));
    assert(
      includes(providerTree, "Store credential securely"),
      "P-13 credential setup control is missing",
    );
    ui.screenshot("onboarding-provider.png");
    await stopUI();

    const paths = await call(
      "provider-paths-verified",
      "daemon.onboarding.action",
      { stepID: "provider_paths", action: "verify" },
    );
    assert(
      paths.currentStepID === "cloud_identity",
      "P-13 provider data did not advance onboarding",
    );
    const catalogResult = await call("catalog-read", "daemon.catalog", {});
    const catalog = catalogResult.catalog ?? catalogResult;
    const provider = (catalog.providers ?? []).find((row) => providerID(row));
    assert(provider, "P-13 installed daemon returned no provider catalog");
    const selectedProviderID = providerID(provider);
    const slotID = `p13-${marker.slice(-12)}`;
    const credentialLabel = `P13 ${marker}`;
    const credentialRequest = {
      providerID: selectedProviderID,
      slotID,
      label: credentialLabel,
      apiKey: `p13-temporary-${crypto.randomBytes(24).toString("base64url")}`,
      isEnabled: false,
      endpointProfileID: null,
      region: null,
      tokenPlanTier: null,
      tokenPlanBillingCycle: null,
      authMethodID: null,
    };
    const created = await call(
      "credential-created",
      "daemon.provider.credential_slot.upsert",
      credentialRequest,
      {
        evidenceRequest: {
          ...credentialRequest,
          apiKey: "[REDACTED]",
        },
      },
    );
    assert(
      created.slot?.slotID === slotID,
      "P-13 credential slot was not daemon-created",
    );
    credential = { providerID: selectedProviderID, slotID };
    const readback = await call("credential-readback", "daemon.config.get", {});
    assert(
      snapshotOf(readback).providers?.some(
        (row) =>
          row.providerID === selectedProviderID &&
          row.credentialSlots?.some((slot) => slot.slotID === slotID),
      ),
      "P-13 credential slot was not read back",
    );
    await call(
      "credential-removed",
      "daemon.provider.credential_slot.remove",
      credential,
    );
    credential = null;

    const cloudUnavailable = await call(
      "cloud-unavailable",
      "daemon.onboarding.action",
      { stepID: "cloud_identity", action: "verify" },
    );
    assert(
      cloudUnavailable.steps?.find((row) => row.id === "cloud_identity")
        ?.state === "blocked",
      "P-13 production cloud auth was configured; this unavailable-path proof must not claim or cancel a live OAuth operation",
    );
    await launchUI();
    recordUI("cloud-blocked", (tree) => ({
      blockedVisible:
        includes(tree, "Blocked") && includes(tree, "native cloud sign-in"),
      retryVisible: includes(tree, "Retry check"),
      skipVisible: includes(tree, "Skip for now"),
    }));
    ui.screenshot("onboarding-cloud.png");
    await action("cloud-retry", "Retry check");
    await action("cloud-skip", "Skip for now");
    const cloudSkipped = await call(
      "cloud-skipped",
      "daemon.onboarding.snapshot",
      {},
    );
    assert(
      cloudSkipped.currentStepID === "portal_input",
      "P-13 cloud skip did not advance through daemon authority",
    );

    await action("portal-retry", "Check integration");
    const portalBlocked = await call(
      "portal-unavailable",
      "daemon.onboarding.snapshot",
      {},
    );
    assert(
      portalBlocked.steps?.find((row) => row.id === "portal_input")?.state ===
        "blocked",
      "P-13 portal check did not fail closed",
    );
    const portalTree = recordUI("portal-blocked", (tree) => ({
      blockedVisible:
        includes(tree, "Blocked") &&
        (includes(tree, "Desktop portal") || includes(tree, "Portal")),
      retryVisible: includes(tree, "Retry check"),
      skipVisible: includes(tree, "Skip for now"),
    }));
    assert(
      includes(portalTree, "Retry check"),
      "P-13 portal recovery control is missing",
    );
    await action("portal-skip", "Skip for now");
    await call("portal-skipped", "daemon.onboarding.snapshot", {});
    await stopUI();

    await call("tray-skipped", "daemon.onboarding.action", {
      stepID: "tray",
      action: "skip",
    });
    await call("updates-unavailable", "daemon.onboarding.action", {
      stepID: "updates",
      action: "verify",
    });
    await call("updates-skipped", "daemon.onboarding.action", {
      stepID: "updates",
      action: "skip",
    });
    await launchUI();
    recordUI("privacy", (tree) => ({
      choicesVisible:
        includes(tree, "Privacy choices") &&
        includes(tree, "Telemetry") &&
        includes(tree, "Cloud sync"),
      saveVisible: includes(tree, "Save choices"),
    }));
    ui.screenshot("onboarding-privacy.png");
    await stopUI();
    const complete = await call("privacy-saved", "daemon.onboarding.action", {
      stepID: "privacy",
      action: "save_privacy_choices",
      telemetryEnabled: false,
      cloudSyncEnabled: false,
    });
    assert(
      complete.completed === true,
      "P-13 completion remained false after every required gate",
    );
    await daemon.restart();
    const restart = await call(
      "restart-snapshot",
      "daemon.onboarding.snapshot",
      {},
    );
    assert(
      JSON.stringify(restart) === JSON.stringify(complete),
      "P-13 onboarding completion did not survive restart",
    );
    const config = snapshotOf(
      await call("privacy-config-readback", "daemon.config.get", {}),
    );
    assert(
      config.telemetryEnabled === false && config.cloudSyncEnabled === false,
      "P-13 privacy choices were not daemon-readable",
    );
    await launchUI();
    recordUI("completed", (tree) => ({
      completedVisible: includes(tree, "Setup complete"),
      resetVisible: includes(tree, "Reset setup"),
    }));
    ui.screenshot("onboarding-completed.png");
    await stopUI();

    writeJson(path.join(options.rawOutputDir, "onboarding-marker.json"), {
      marker,
      providerID: selectedProviderID,
      slotID,
      credentialLabel,
      safety: {
        credentialMaterialRecordedInEvidence: false,
        credentialRemoved: true,
        productionOAuthClaimed: false,
      },
    });
    writeJson(
      path.join(options.rawOutputDir, "onboarding-daemon-transcript.json"),
      {
        producer: "openburnbar-p13-installed-onboarding-daemon-probe-v1",
        transport: "installed daemon AF_UNIX RPC",
        events,
      },
    );
    writeJson(
      path.join(options.rawOutputDir, "onboarding-ui-transcript.json"),
      {
        producer: "openburnbar-p13-installed-onboarding-ui-probe-v1",
        events: uiEvents,
        actions: uiActions,
        productionAuth: {
          configured: false,
          retryOutcome: "remained-unavailable",
          cancelOutcome: "not-started-unavailable",
          productionSuccessClaimed: false,
        },
      },
    );
    return {
      output: options.rawOutputDir,
      marker,
      providerID: selectedProviderID,
    };
  } finally {
    try {
      await stopUI();
    } catch {
      /* preserve primary failure */
    }
    let cleanupError = null;
    if (credential) {
      try {
        await rpc("daemon.provider.credential_slot.remove", credential);
      } catch (error) {
        process.stderr.write(
          `P-13 CRITICAL: temporary credential cleanup failed: ${error.message}\n`,
        );
        cleanupError = error;
      }
    }
    try {
      if (prepared) await daemon.restore();
    } catch (error) {
      cleanupError ??= error;
    }
    if (cleanupError) throw cleanupError;
  }
}

export function parseP13Arguments(argv) {
  const flags = [
    "--raw-output-dir",
    "--support-dir",
    "--home-dir",
    "--socket-path",
    "--token-file",
    "--index-database",
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
    supportDir: values.get("--support-dir"),
    homeDir: values.get("--home-dir"),
    socketPath: values.get("--socket-path"),
    tokenFile: values.get("--token-file"),
    indexDatabase: values.get("--index-database"),
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
      `${JSON.stringify(await runP13NativeOnboardingProbes(parseP13Arguments(process.argv.slice(2))), null, 2)}\n`,
    );
  } catch (error) {
    process.stderr.write(
      `P-13 native onboarding probe failed: ${error.message}\n`,
    );
    process.exitCode = 1;
  }
}
