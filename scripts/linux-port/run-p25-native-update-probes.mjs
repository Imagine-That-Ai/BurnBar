#!/usr/bin/env node
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
const CONTROL = path.join(ROOT, "scripts/linux-port/p25-atspi-control.py");
const PHASES = new Set(["available", "current", "error", "restart"]);
const SHA256 = /^[a-f0-9]{64}$/u;
const RELEASE_COMMIT = /^(?:[a-f0-9]{40}|[a-f0-9]{64})$/u;

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
function privateDirectory(directory) {
  fs.mkdirSync(directory, { recursive: true, mode: 0o700 });
  const stat = fs.lstatSync(directory);
  assert(
    stat.isDirectory() &&
      !stat.isSymbolicLink() &&
      stat.uid === process.getuid?.() &&
      (stat.mode & 0o077) === 0,
    "P-25 output must be an owner-only directory",
  );
  return fs.realpathSync(directory);
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
async function waitFor(label, operation, timeoutMs = 30_000) {
  const deadline = Date.now() + timeoutMs;
  let error;
  while (Date.now() < deadline) {
    try {
      return await operation();
    } catch (candidate) {
      error = candidate;
      await sleep(250);
    }
  }
  throw new Error(`${label} timed out: ${error?.message ?? "unavailable"}`);
}
function installedDesktopPids(runner) {
  const result = runner.run("pgrep", [
    "-f",
    "^/usr/bin/openburnbar-linux-desktop([[:space:]]|$)",
  ]);
  if (result.status === 1) return [];
  assert(
    result.status === 0,
    `P-25 process preflight failed: ${(result.stderr || result.stdout).trim()}`,
  );
  return result.stdout
    .trim()
    .split(/\s+/u)
    .filter(Boolean)
    .map(Number)
    .filter(Number.isSafeInteger);
}
function atspi(runner, output, suffix, mode, name = null) {
  const file = path.join(output, `.p25-atspi-${suffix}.json`);
  const args = [CONTROL, "--mode", mode, "--output", file];
  if (name) args.push("--name", name);
  required(runner, "python3", args, `P-25 AT-SPI ${suffix}`);
  const document = JSON.parse(fs.readFileSync(file, "utf8"));
  fs.rmSync(file);
  return document;
}
function names(tree) {
  return (tree.nodes ?? [])
    .map((node) => String(node.name ?? ""))
    .filter(Boolean);
}
function includes(tree, expected) {
  return names(tree).some((name) => name.includes(expected));
}
function nodeFor(tree, expected) {
  return (tree.nodes ?? []).find((node) =>
    String(node.name ?? "").includes(expected),
  );
}
function enabled(tree, expected) {
  const node = nodeFor(tree, expected);
  const states = node?.states ?? [];
  return (
    Boolean(node) && states.includes("enabled") && states.includes("sensitive")
  );
}
function packageFacts(runner, channel) {
  if (channel === "deb")
    return {
      channel,
      manager: "apt",
      owner: "apt/dpkg",
      version: required(
        runner,
        "dpkg-query",
        ["-W", "-f=${Version}", "open-burn-bar"],
        "Debian package identity",
      ),
    };
  if (channel === "rpm")
    return {
      channel,
      manager: "dnf",
      owner: "dnf/rpm",
      version: required(
        runner,
        "rpm",
        ["-q", "--qf", "%{VERSION}", "open-burn-bar"],
        "RPM package identity",
      ),
    };
  if (channel === "arch")
    return {
      channel,
      manager: "pacman",
      owner: "pacman",
      version: (
        required(
          runner,
          "pacman",
          ["-Q", "openburnbar"],
          "Arch package identity",
        ).split(/\s+/u)[1] ?? ""
      ).replace(/-[1-9][0-9]*$/u, ""),
    };
  if (channel === "appimage")
    return {
      channel,
      manager: "appimage",
      owner: "user-managed artifact",
      version:
        required(runner, DESKTOP, ["--version"], "AppImage version")
          .split(/\s+/u)
          .at(-1) ?? "",
    };
  throw new Error("P-25 requires a known installed package channel");
}
function phaseObservation(
  phase,
  tree,
  expectedVersion,
  candidateVersion,
  packageInfo,
  action,
) {
  const common = {
    updates: includes(tree, "Updates"),
    packageChannel: includes(tree, "Package channel"),
    owner: includes(tree, packageInfo.owner),
    shellVersion: includes(tree, expectedVersion),
    daemonVersion:
      names(tree).filter((name) => name.includes(expectedVersion)).length >= 2,
  };
  if (phase === "available")
    return {
      ...common,
      available: includes(tree, "is available"),
      targetVersion: includes(tree, candidateVersion),
      verified: includes(tree, "Ed25519 verified feed"),
      fresh: includes(tree, "signature verified"),
      signedDownloadEnabled: enabled(tree, "Open signed download"),
      safeActionActivated: Boolean(action?.activation?.action),
      shellDoesNotInstall: includes(
        tree,
        "never runs package-manager commands",
      ),
    };
  if (phase === "current")
    return {
      ...common,
      current: includes(tree, "up to date"),
      verified: includes(tree, "Ed25519 verified feed"),
      fresh: includes(tree, "signature verified"),
      noDownloadAction: !nodeFor(tree, "Open signed download"),
      shellDoesNotInstall: includes(
        tree,
        "never runs package-manager commands",
      ),
    };
  if (phase === "error")
    return {
      ...common,
      error:
        includes(tree, "Update metadata rejected") ||
        includes(tree, "Update channel unavailable"),
      noEnabledDownload: !enabled(tree, "Open signed download"),
      noEnabledInstall: !enabled(tree, "Copy install command"),
      recovery: includes(tree, "Check again"),
    };
  return {
    ...common,
    restarted: true,
    guidance: includes(tree, "Restart guidance"),
    daemonAligned:
      !includes(tree, "differ; restart") &&
      !includes(tree, "Daemon version is unavailable"),
  };
}
function assertObservation(phase, observed) {
  assert(
    Object.values(observed).every(Boolean),
    `P-25 ${phase} UI did not prove every required native state`,
  );
}

export async function captureP25NativeUpdatePhase(options, dependencies = {}) {
  assert(
    (dependencies.platform ?? process.platform) === "linux",
    "P-25 native probe must execute on Linux",
  );
  assert(
    PHASES.has(options.phase),
    "P-25 phase must be available, current, error, or restart",
  );
  for (const [label, value] of [
    ["installed package", options.installedPackageSha256],
    ["installed manifest", options.installedManifestSha256],
    ["installed manifest signature", options.installedManifestSignatureSha256],
  ])
    assert(SHA256.test(value), `P-25 ${label} SHA-256 is invalid`);
  assert(
    RELEASE_COMMIT.test(options.authenticatedReleaseCommit),
    "P-25 authenticated release commit is invalid",
  );
  assert(
    dependencies.desktopSession ??
      (process.env.DBUS_SESSION_BUS_ADDRESS &&
        (process.env.DISPLAY || process.env.WAYLAND_DISPLAY)),
    "P-25 requires a live desktop and D-Bus",
  );
  options.rawOutputDir = privateDirectory(options.rawOutputDir);
  const runner = dependencies.runner ?? commandRunner();
  const candidatePhase = options.phase !== "available";
  if (candidatePhase)
    (dependencies.installedVerifier ?? verifyInstalledCandidate)(options);
  const pids = (
    dependencies.desktopProcessIDs ?? (() => installedDesktopPids(runner))
  )();
  assert(pids.length === 0, "P-25 requires no pre-existing installed desktop");
  if (!dependencies.ui)
    for (const tool of ["python3", "xdotool", "scrot"])
      required(
        runner,
        "sh",
        ["-c", 'command -v "$1" >/dev/null', "p25-tool", tool],
        `required tool ${tool}`,
      );
  const facts = (dependencies.packageFacts ?? packageFacts)(
    runner,
    options.packageChannel,
  );
  assert(
    facts.version === options.expectedVersion,
    `P-25 ${options.phase} installed version ${facts.version} does not match ${options.expectedVersion}`,
  );
  if (candidatePhase)
    assert(
      options.expectedVersion === options.packageVersion,
      "P-25 candidate phase version is not release-bound",
    );
  const ui = dependencies.ui ?? {
    async launch() {
      const child = runner.start(DESKTOP, ["openburnbar://updates"]);
      await waitFor("P-25 installed desktop", () => {
        const found = runner.run("xdotool", [
          "search",
          "--onlyvisible",
          "--pid",
          String(child.pid),
          "--name",
          "^OpenBurnBar",
        ]);
        assert(found.status === 0, "window absent");
        return true;
      });
      await sleep(1500);
      return child;
    },
    snapshot(label) {
      return atspi(runner, options.rawOutputDir, label, "snapshot");
    },
    activate(name, label) {
      return atspi(runner, options.rawOutputDir, label, "activate", name);
    },
    screenshot(file) {
      required(
        runner,
        "scrot",
        ["--overwrite", "--focused", file],
        "P-25 screenshot",
      );
    },
    async stop(app) {
      app.kill();
      await waitFor("P-25 desktop exit", () => {
        const alive = runner.run("kill", ["-0", String(app.pid)]);
        assert(alive.status !== 0, "desktop alive");
        return true;
      });
    },
  };
  let app;
  try {
    if (options.phase === "restart") {
      (
        dependencies.restart ??
        (() =>
          required(
            runner,
            "systemctl",
            ["--user", "restart", "openburnbar-daemon.service"],
            "P-25 daemon restart",
          ))
      )();
      await sleep(1000);
    }
    app = await ui.launch();
    const tree = ui.snapshot(options.phase);
    const screenshot = path.join(
      options.rawOutputDir,
      `updates-${options.phase}.png`,
    );
    ui.screenshot(screenshot);
    assert(fs.statSync(screenshot).size > 1024, "P-25 screenshot is empty");
    let action = null;
    if (options.phase === "available") {
      assert(
        enabled(tree, "Open signed download"),
        "P-25 signed download action is not enabled",
      );
      action = await ui.activate("Open signed download", "signed-download");
    }
    const observed = phaseObservation(
      options.phase,
      tree,
      options.expectedVersion,
      options.packageVersion,
      facts,
      action,
    );
    assertObservation(options.phase, observed);
    const record = {
      schemaVersion: 1,
      phase: options.phase,
      capturedAt: new Date().toISOString(),
      producer: "openburnbar-p25-installed-update-phase-v1",
      targetHead: options.targetHead,
      candidateRunId: String(options.candidateRunId),
      candidateArtifactDigest: options.candidateArtifactDigest,
      manifestSha256: options.manifestSha256,
      provenance: {
        packageSha256: options.installedPackageSha256,
        manifestSha256: options.installedManifestSha256,
        manifestSignatureSha256: options.installedManifestSignatureSha256,
        releaseCommit: options.authenticatedReleaseCommit,
      },
      packageVersion: options.packageVersion,
      expectedVersion: options.expectedVersion,
      advertisedVersion:
        options.phase === "available" ? options.packageVersion : null,
      package: facts,
      appPid: app.pid,
      observed,
      action: action
        ? {
            kind: "open-signed-download",
            activated: true,
            packageMutation: false,
          }
        : null,
      rollbackClaimed: false,
    };
    writeJson(
      path.join(options.rawOutputDir, `updates-${options.phase}.json`),
      record,
    );
    return record;
  } finally {
    if (app) await ui.stop(app);
  }
}

export function parseP25Arguments(argv) {
  const flags = [
    "--raw-output-dir",
    "--phase",
    "--expected-version",
    "--package-channel",
    "--environment",
    "--target-head",
    "--candidate-run-id",
    "--candidate-artifact-digest",
    "--package-version",
    "--manifest-sha256",
    "--manifest-signature-sha256",
    "--installed-package-sha256",
    "--installed-manifest-sha256",
    "--installed-manifest-signature-sha256",
    "--authenticated-release-commit",
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
    phase: values.get("--phase"),
    expectedVersion: values.get("--expected-version"),
    packageChannel: values.get("--package-channel"),
    environmentId: values.get("--environment"),
    targetHead: values.get("--target-head"),
    candidateRunId: values.get("--candidate-run-id"),
    candidateArtifactDigest: values.get("--candidate-artifact-digest"),
    packageVersion: values.get("--package-version"),
    manifestSha256: values.get("--manifest-sha256"),
    manifestSignatureSha256: values.get("--manifest-signature-sha256"),
    installedPackageSha256: values.get("--installed-package-sha256"),
    installedManifestSha256: values.get("--installed-manifest-sha256"),
    installedManifestSignatureSha256: values.get(
      "--installed-manifest-signature-sha256",
    ),
    authenticatedReleaseCommit: values.get("--authenticated-release-commit"),
    compositor: values.get("--compositor"),
  };
}

if (
  process.argv[1] &&
  path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)
) {
  try {
    process.stdout.write(
      `${JSON.stringify(await captureP25NativeUpdatePhase(parseP25Arguments(process.argv.slice(2))), null, 2)}\n`,
    );
  } catch (error) {
    process.stderr.write(`P-25 native update probe failed: ${error.message}\n`);
    process.exitCode = 1;
  }
}
