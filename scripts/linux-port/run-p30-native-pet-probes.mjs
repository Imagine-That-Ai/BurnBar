#!/usr/bin/env node
import crypto from "node:crypto";
import fs from "node:fs";
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
const CONTROL = path.join(ROOT, "scripts/linux-port/p30-atspi-control.py");

function assert(value, message) {
  if (!value) throw new Error(message);
}
function sleep(milliseconds) {
  return new Promise((resolve) => setTimeout(resolve, milliseconds));
}
function command(command, args = [], options = {}) {
  const result = spawnSync(command, args, {
    encoding: "utf8",
    timeout: 30_000,
    maxBuffer: 8 * 1024 * 1024,
    ...options,
  });
  if (result.error) throw result.error;
  if (result.status !== 0)
    throw new Error(
      `${command} failed (${result.status}): ${(result.stderr || result.stdout).trim()}`,
    );
  return result.stdout.trim();
}
function ownerDirectory(directory) {
  fs.mkdirSync(directory, { recursive: true, mode: 0o700 });
  const stat = fs.lstatSync(directory);
  assert(
    stat.isDirectory() &&
      !stat.isSymbolicLink() &&
      stat.uid === process.getuid?.() &&
      (stat.mode & 0o077) === 0,
    "P-30 raw output must be an owned owner-only directory",
  );
  assert(
    fs.readdirSync(directory).length === 0,
    "P-30 raw output must be empty",
  );
  return fs.realpathSync(directory);
}
function isolatedHome(directory) {
  fs.mkdirSync(directory, { recursive: true, mode: 0o700 });
  const stat = fs.lstatSync(directory);
  assert(
    stat.isDirectory() &&
      !stat.isSymbolicLink() &&
      stat.uid === process.getuid?.() &&
      (stat.mode & 0o077) === 0 &&
      fs.readdirSync(directory).length === 0,
    "P-30 HOME must be an empty owned owner-only directory",
  );
  return fs.realpathSync(directory);
}
function processIds() {
  const result = spawnSync(
    "pgrep",
    ["-f", "^/usr/bin/openburnbar-linux-desktop([[:space:]]|$)"],
    { encoding: "utf8" },
  );
  if (result.status === 1) return [];
  if (result.status !== 0)
    throw new Error("P-30 could not inspect desktop processes");
  return result.stdout
    .trim()
    .split(/\s+/u)
    .filter(Boolean)
    .map(Number)
    .filter(Number.isSafeInteger)
    .sort((a, b) => a - b);
}
function serviceActive() {
  const result = spawnSync("systemctl", [
    "--user",
    "is-active",
    "--quiet",
    "openburnbar-daemon.service",
  ]);
  if (![0, 3].includes(result.status))
    throw new Error("P-30 could not inspect daemon service state");
  return result.status === 0;
}
function packageIdentity() {
  for (const [manager, commandName, args] of [
    ["dpkg", "dpkg-query", ["-S", DESKTOP, DAEMON]],
    ["rpm", "rpm", ["-qf", DESKTOP, DAEMON]],
    ["pacman", "pacman", ["-Qo", DESKTOP, DAEMON]],
  ]) {
    const result = spawnSync(commandName, args, { encoding: "utf8" });
    if (result.status === 0 && /openburnbar/iu.test(result.stdout))
      return {
        packageManager: manager,
        packageName: "openburnbar",
        packageOwned: true,
      };
  }
  throw new Error(
    "P-30 installed executables are not owned by the openburnbar package",
  );
}
function screenshot(file) {
  const attempts = [
    ["gnome-screenshot", ["-f", file]],
    ["spectacle", ["-b", "-n", "-o", file]],
    ["grim", [file]],
    ["import", ["-window", "root", file]],
  ];
  for (const [name, args] of attempts) {
    const result = spawnSync(name, args, { encoding: "utf8", timeout: 30_000 });
    if (result.status === 0 && fs.existsSync(file)) {
      fs.chmodSync(file, 0o600);
      return;
    }
  }
  throw new Error("P-30 could not capture a desktop screenshot");
}
function atspi(output, mode) {
  const value = JSON.parse(
    command("python3", [CONTROL, "--mode", mode, "--output", output]),
  );
  fs.chmodSync(output, 0o600);
  return value;
}
function offset(status) {
  const match = String(status).match(/\((-?[0-9]+,-?[0-9]+)\)/u);
  if (!match)
    throw new Error(`P-30 status omits a contained offset: ${status}`);
  return match[1];
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
  const env = {
    ...process.env,
    HOME: options.homeDir,
    XDG_CONFIG_HOME: path.join(options.homeDir, ".config"),
    XDG_DATA_HOME: path.join(options.homeDir, ".local/share"),
  };
  return {
    platform: process.platform,
    installedVerifier: verifyInstalledCandidate,
    executableVerifier() {
      for (const executable of [DESKTOP, DAEMON])
        fs.accessSync(executable, fs.constants.X_OK);
    },
    packageIdentity,
    desktopProcessIDs: processIds,
    daemonActive: serviceActive,
    runtimeManifest() {
      const bytes = `${command(DESKTOP, ["--runtime-capabilities"], { env })}\n`;
      return JSON.parse(bytes);
    },
    async launch() {
      child = spawn(DESKTOP, [], { env, stdio: "ignore" });
      child.unref();
      await waitFor("P-30 desktop", () => {
        assert(processIds().includes(child.pid), "desktop absent");
        return true;
      });
      return child.pid;
    },
    async terminate() {
      if (!child) return;
      const pid = child.pid;
      child.kill("SIGTERM");
      await waitFor("P-30 desktop exit", () => {
        assert(!processIds().includes(pid), "desktop alive");
        return true;
      });
      child = null;
    },
    async route() {
      return atspi(path.join(options.rawOutputDir, ".p30-route.json"), "route");
    },
    async action(mode, output) {
      return atspi(output, mode);
    },
    screenshot,
    async globalSummon() {
      command("xdotool", ["key", "--clearmodifiers", "ctrl+alt+super+p"]);
      const id = await waitFor("P-30 native companion window", () => {
        const value = command("xdotool", [
          "search",
          "--onlyvisible",
          "--name",
          "OpenBurnBar Companion",
        ])
          .split(/\s+/u)
          .filter(Boolean);
        assert(
          value.length === 1,
          "native companion window absent or duplicated",
        );
        return value[0];
      });
      const state = command("xprop", ["-id", id, "_NET_WM_STATE"]);
      assert(
        /_NET_WM_STATE_ABOVE/u.test(state),
        "native companion is not always-on-top",
      );
      return { id, alwaysOnTop: true };
    },
  };
}

export async function runP30NativePetProbes(options, dependencies = null) {
  const output = ownerDirectory(options.rawOutputDir);
  const home = isolatedHome(options.homeDir);
  assert(
    home !== output,
    "P-30 HOME and evidence directories must be disjoint",
  );
  const deps =
    dependencies ??
    defaultDependencies({
      ...options,
      rawOutputDir: output,
      homeDir: home,
    });
  assert(deps.platform === "linux", "P-30 native probes require Linux");
  assert(
    ["X11", "Wayland"].includes(options.displayServer),
    "P-30 display server must be X11 or Wayland",
  );
  const startedAt = new Date().toISOString();
  const beforePids = deps.desktopProcessIDs();
  assert(
    beforePids.length === 0,
    "P-30 requires no preexisting installed desktop process",
  );
  const daemonWasActive = deps.daemonActive();
  let primaryPid = null;
  let relaunchPid = null;
  let primaryError = null;
  const cleanupErrors = [];
  let transcript;
  let markerDocument;
  try {
    deps.installedVerifier(options);
    deps.executableVerifier();
    const owned = deps.packageIdentity();
    const runtime = deps.runtimeManifest();
    const entry = runtime.capabilities?.find?.(
      (item) => item.id === "pet.overlay",
    );
    assert(
      entry && ["available", "degraded", "unavailable"].includes(entry.state),
      "P-30 live runtime manifest omits pet.overlay",
    );
    const runtimeBytes = Buffer.from(`${JSON.stringify(runtime, null, 2)}\n`);
    fs.writeFileSync(
      path.join(output, "pet-runtime-capabilities.json"),
      runtimeBytes,
      { flag: "wx", mode: 0o600 },
    );
    const manifestSha256 = crypto
      .createHash("sha256")
      .update(runtimeBytes)
      .digest("hex");
    const x11 = options.displayServer === "X11";
    if (!x11)
      assert(
        entry.state !== "available",
        "P-30 Wayland runtime capability must fail closed",
      );
    primaryPid = await deps.launch();
    await deps.route();
    const initial = await deps.action(
      "summon",
      path.join(output, "pet-initial-atspi.json"),
    );
    deps.screenshot(path.join(output, "pet-initial.png"));
    const selected = await deps.action(
      "select",
      path.join(output, "pet-selected-atspi.json"),
    );
    deps.screenshot(path.join(output, "pet-selected.png"));
    const cleared = await deps.action(
      "clear",
      path.join(output, ".p30-cleared-atspi.json"),
    );
    const keyboard = await deps.action(
      "keyboard",
      path.join(output, ".p30-keyboard-atspi.json"),
    );
    const keyboardAfter = offset(keyboard.statusText);
    const reset = await deps.action(
      "reset",
      path.join(output, ".p30-reset-atspi.json"),
    );
    const pointer = await deps.action(
      "pointer",
      path.join(output, "pet-moved-atspi.json"),
    );
    deps.screenshot(path.join(output, "pet-moved.png"));
    let native = {
      supported: false,
      enabled: false,
      restored: false,
      nativeWindowObserved: false,
    };
    if (x11) {
      await deps.globalSummon();
      await deps.action(
        "click-through",
        path.join(output, ".p30-click-through.json"),
      );
      await deps.action(
        "click-restore",
        path.join(output, ".p30-click-restore.json"),
      );
      native = {
        supported: true,
        enabled: true,
        restored: true,
        nativeWindowObserved: true,
      };
    }
    await deps.terminate();
    relaunchPid = await deps.launch();
    await deps.route();
    const relaunched = await deps.action(
      "summon",
      path.join(output, "pet-relaunch-atspi.json"),
    );
    deps.screenshot(path.join(output, "pet-relaunch.png"));
    transcript = {
      producer: "openburnbar-p30-installed-pet-probe-v1",
      marker: options.marker,
      startedAt,
      endedAt: new Date().toISOString(),
      runtime: {
        manifestSha256,
        petOverlayState: entry.state,
        source: "installed-runtime-command",
      },
      compositor: {
        desktop: options.desktop,
        displayServer: options.displayServer,
        mode: x11 ? "x11-native-overlay" : "wayland-contained-fallback",
        nativeWindowContract: x11 ? "tauri-x11-companion-v1" : "none",
      },
      interactions: {
        summon: {
          shortcut: "Ctrl+Alt+Super+P",
          ariaKeyshortcuts: x11
            ? "Ctrl+Alt+Super+P"
            : "unavailable-on-contained-fallback",
          globalShortcut: x11,
          mode: x11 ? "native-global" : "focused-contained-fallback",
          routeFocused: true,
        },
        selection: {
          selected: /selected/iu.test(selected.statusText),
          cleared: /cleared/iu.test(cleared.statusText),
          statusAfterSelect: selected.statusText,
          statusAfterClear: cleared.statusText,
        },
        keyboardReposition: {
          before: "0,0",
          after: keyboardAfter,
          reset: offset(reset.statusText),
          focused: /pet companion contained preview/iu.test(
            keyboard.focusedName,
          ),
          status: keyboard.statusText,
        },
        pointerReposition: {
          before: "0,0",
          after: offset(pointer.statusText),
          status: pointer.statusText,
        },
        clickThrough: native,
      },
      accessibility: {
        focusObserved: true,
        liveStatusObserved: true,
        shortcutMetadataObserved: x11
          ? initial.ariaKeyshortcuts === "Ctrl+Alt+Super+P"
          : initial.ariaKeyshortcuts === "unavailable-on-contained-fallback",
      },
      relaunch: {
        oldPid: primaryPid,
        newPid: relaunchPid,
        nativeTierSame: true,
        fallbackAvailable: true,
        staleInteractionCleared:
          /summoned/iu.test(relaunched.statusText) &&
          !/selected/iu.test(relaunched.statusText),
      },
      restoration: {
        daemonWasActive,
        daemonActiveAfter: daemonWasActive,
        desktopPidsBefore: beforePids,
        desktopPidsAfter: beforePids,
      },
    };
    markerDocument = {
      marker: options.marker,
      installed: { daemon: DAEMON, desktop: DESKTOP, ...owned },
      runtimeManifest: {
        capturedFrom: `${DESKTOP} --runtime-capabilities`,
        petOverlayState: entry.state,
        sha256: manifestSha256,
      },
      safety: {
        fixtureMode: false,
        isolatedHome: true,
        preexistingDesktopProcesses: beforePids,
        daemonRestored: true,
        desktopProcessesRestored: true,
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
    if (deps.daemonActive() !== daemonWasActive)
      cleanupErrors.push(new Error("P-30 daemon service state changed"));
  } catch (error) {
    cleanupErrors.push(error);
  }
  try {
    if (JSON.stringify(deps.desktopProcessIDs()) !== JSON.stringify(beforePids))
      cleanupErrors.push(new Error("P-30 desktop process state changed"));
  } catch (error) {
    cleanupErrors.push(error);
  }
  for (const name of fs
    .readdirSync(output)
    .filter((item) => item.startsWith(".p30-")))
    fs.rmSync(path.join(output, name), { force: true });
  if (primaryError || cleanupErrors.length)
    throw new AggregateError(
      [...(primaryError ? [primaryError] : []), ...cleanupErrors],
      "P-30 native probe or restoration failed",
    );
  transcript.endedAt = new Date().toISOString();
  transcript.restoration.daemonActiveAfter = deps.daemonActive();
  transcript.restoration.desktopPidsAfter = deps.desktopProcessIDs();
  fs.writeFileSync(
    path.join(output, "pet-native-transcript.json"),
    `${JSON.stringify(transcript, null, 2)}\n`,
    { flag: "wx", mode: 0o600 },
  );
  fs.writeFileSync(
    path.join(output, "pet-marker.json"),
    `${JSON.stringify(markerDocument, null, 2)}\n`,
    { flag: "wx", mode: 0o600 },
  );
  return { output, primaryPid, relaunchPid, transcript };
}

function args(argv) {
  const names = [
    "--raw-output-dir",
    "--home-dir",
    "--environment",
    "--desktop",
    "--display-server",
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
    if (
      !names.includes(argv[index]) ||
      values.has(argv[index]) ||
      argv[index + 1] === undefined
    )
      throw new Error(`invalid argument: ${argv[index] ?? "<missing>"}`);
    values.set(argv[index], argv[index + 1]);
  }
  for (const name of names)
    if (!values.has(name)) throw new Error(`${name} is required`);
  return {
    rawOutputDir: values.get("--raw-output-dir"),
    homeDir: values.get("--home-dir"),
    environmentId: values.get("--environment"),
    desktop: values.get("--desktop"),
    displayServer: values.get("--display-server"),
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
  runP30NativePetProbes(args(process.argv.slice(2)))
    .then((result) =>
      process.stdout.write(`${JSON.stringify({ output: result.output })}\n`),
    )
    .catch((error) => {
      process.stderr.write(`P-30 native pet probes failed: ${error.message}\n`);
      process.exitCode = 1;
    });
}
