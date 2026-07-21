import assert from "node:assert/strict";
import fs from "node:fs";
import path from "node:path";
import test from "node:test";
import {
  normalizeP28DesktopIdentity,
  runP28NativeSmartHubProbes,
} from "./run-p28-native-smarthub-probes.mjs";

const PNG_SIGNATURE = Buffer.from([137, 80, 78, 71, 13, 10, 26, 10]);

function fixture() {
  const base = path.join(process.cwd(), ".tmp/p28-native-tests");
  fs.mkdirSync(base, { recursive: true });
  const root = fs.mkdtempSync(path.join(base, "probe-"));
  for (const name of ["home", "support"])
    fs.mkdirSync(path.join(root, name), { mode: 0o700 });
  return {
    root,
    options: {
      rawOutputDir: path.join(root, "raw"),
      homeDir: path.join(root, "home"),
      supportDir: path.join(root, "support"),
      environmentId: "ubuntu-24.04-gnome-wayland-aarch64",
      desktop: "GNOME",
      displayServer: "Wayland",
      bridgePort: 8787,
      marker: "p28-fedcba0987654321",
      targetHead: "1".repeat(40),
      candidateRunId: "282828",
      candidateArtifactDigest: `sha256:${"2".repeat(64)}`,
      packageVersion: "1.2.3",
      manifestSha256: "3".repeat(64),
      manifestSignatureSha256: "4".repeat(64),
    },
  };
}

function peerMetadata() {
  return {
    service_type: "_openburnbar-peer._tcp",
    instance: "OpenBurnBar-p28-live",
    txt: {
      transport: "unix-domain",
      daemon_version: "1.2.3",
      protocol_version: "1",
      platform: "linux",
      pairing: "mdns",
    },
  };
}

function peer() {
  return {
    instanceName: "OpenBurnBar-p28-live",
    hostName: "p28.local",
    port: 8787,
    txt: { ...peerMetadata().txt },
  };
}

function discovery() {
  return [
    {
      adapter: "smart_hub_bridge",
      serviceType: "_openburnbar-peer._tcp",
      instances: ["OpenBurnBar-p28-live"],
      rawTranscript:
        "=;eth0;IPv4;OpenBurnBar-p28-live;_openburnbar-peer._tcp;local;p28.local;127.0.0.1;8787",
      status: "ok",
      blocker: null,
    },
  ];
}

function healthyStatus() {
  return {
    adapter: "smart_hub_bridge",
    status: "bridge_control_ok",
    blocker: "",
    health_probe: "curl http://127.0.0.1:8787/health",
    health_response: '{"ok":true}',
    control_probe: "curl -X POST http://127.0.0.1:8787/api/display",
    control_response: '{"accepted":true}',
  };
}

function degradedStatus() {
  return {
    adapter: "smart_hub_bridge",
    status: "blocked_bridge_not_reachable",
    blocker: "Start the Linux SmartHub bridge and retry.",
    health_probe: "curl http://127.0.0.1:8787/health",
    health_response: "",
    control_probe: "curl -X POST http://127.0.0.1:8787/api/display",
    control_response: "",
  };
}

function dependencies(
  value,
  {
    mutateMetadata = null,
    staleAtspi = false,
    substituteAtspi = false,
    duplicateScreenshots = false,
    partialRecovery = false,
    cleanupFailure = false,
    symlinkScreenshot = false,
    substitutedPackage = false,
  } = {},
) {
  let desktopPid = null;
  let nextDesktopPid = 2800;
  let daemonPid = 2810;
  let bridgePaused = false;
  let bridgeResumes = 0;
  let daemonRestarts = 0;
  let launches = 0;
  let screenshots = 0;
  const metadata = peerMetadata();
  if (mutateMetadata) mutateMetadata(metadata);
  return {
    platform: "linux",
    probeTimeoutMs: 25,
    installedVerifier() {},
    executableVerifier() {},
    packageIdentity: () => ({
      packageManager: "dpkg",
      packageName: "openburnbar",
      packageOwned: true,
      executablePackages: {
        "/usr/bin/openburnbar-cli": "openburnbar",
        "/usr/libexec/openburnbar-daemon-launch": substitutedPackage
          ? "other-daemon"
          : "openburnbar",
        "/usr/bin/openburnbar-linux-desktop": "openburnbar",
      },
    }),
    daemonActive: () => true,
    desktopProcessIDs: () => (desktopPid === null ? [] : [desktopPid]),
    daemonProcessIDs: () => [daemonPid],
    bridgeProcessIDs: () => [2890],
    compositor: () => ({
      desktop: "GNOME",
      displayServer: "wayland",
      display: null,
      waylandDisplay: "wayland-0",
      sessionId: "4",
      dbusSessionBus: true,
    }),
    runtimeManifest: () => ({
      schemaVersion: 1,
      daemonVersion: "1.2.3",
      capabilities: [
        { id: "smarthub.control", state: "available", source: "trusted-cli" },
      ],
    }),
    peerMetadata: () => structuredClone(metadata),
    peerBrowse: () => [peer()],
    discover: discovery,
    status: () => {
      if (bridgePaused) return degradedStatus();
      if (partialRecovery && daemonRestarts > 0) return degradedStatus();
      return healthyStatus();
    },
    async launchDesktop() {
      launches += 1;
      desktopPid = nextDesktopPid;
      nextDesktopPid += 1;
      return desktopPid;
    },
    async terminateDesktop() {
      desktopPid = null;
      if (cleanupFailure) throw new Error("forced desktop cleanup failure");
    },
    async pauseBridge() {
      bridgePaused = true;
    },
    async resumeBridge() {
      bridgePaused = false;
      bridgeResumes += 1;
    },
    async restartDaemon() {
      daemonRestarts += 1;
      daemonPid += 1;
    },
    async atspi(state, output, context) {
      const document = {
        producer: "openburnbar-p28-atspi-live-v1",
        marker: context.marker,
        nonce: context.nonce,
        state,
        capturedAt: staleAtspi
          ? "2020-01-01T00:00:00.000Z"
          : new Date().toISOString(),
        application: "OpenBurnBar",
        desktopPid: context.pid,
        route: "smarthub",
        selectedOperation: context.operation,
        focusedName: "Run operation",
        statusText: context.expected,
        nodes: [
          { name: "SmartHub / IoT", role: "section", actions: [] },
          { name: "Operation", role: "combo box", actions: ["select"] },
          { name: "Run operation", role: "push button", actions: ["press"] },
          { name: context.expected, role: "status", actions: [] },
          ...Array.from({ length: 5 }, (_, index) => ({
            name: `${state}-node-${index}`,
            role: "label",
            actions: [],
          })),
        ],
      };
      const stored = substituteAtspi
        ? { ...document, nonce: "substituted" }
        : document;
      fs.writeFileSync(output, `${JSON.stringify(stored)}\n`, {
        flag: "wx",
        mode: 0o600,
      });
      return document;
    },
    screenshot(file) {
      screenshots += 1;
      if (symlinkScreenshot && screenshots === 2) {
        const outside = path.join(value.root, "outside.png");
        fs.writeFileSync(
          outside,
          Buffer.concat([PNG_SIGNATURE, Buffer.alloc(120, 9)]),
        );
        fs.symlinkSync(outside, file);
        return;
      }
      const discriminator = duplicateScreenshots ? 7 : screenshots;
      fs.writeFileSync(
        file,
        Buffer.concat([PNG_SIGNATURE, Buffer.alloc(120, discriminator)]),
        { flag: "wx", mode: 0o600 },
      );
    },
    metrics: () => ({
      bridgePaused,
      bridgeResumes,
      daemonRestarts,
      launches,
      desktopPid,
    }),
  };
}

async function rejectsAggregate(value, deps, pattern) {
  await assert.rejects(
    runP28NativeSmartHubProbes(value.options, deps),
    (error) =>
      error instanceof AggregateError &&
      error.errors.some((item) => pattern.test(item.message)),
  );
}

test("P-28 native runner proves discovery, control, loss, recovery, and exact restoration", async () => {
  const value = fixture();
  const deps = dependencies(value);
  try {
    let result;
    try {
      result = await runP28NativeSmartHubProbes(value.options, deps);
    } catch (error) {
      throw new Error(
        error.errors?.map((item) => item.message).join(" | ") ?? error.message,
      );
    }
    assert.equal(
      result.transcript.operations.controlled.status,
      "bridge_control_ok",
    );
    assert.equal(
      result.transcript.operations.degraded.status,
      "blocked_bridge_not_reachable",
    );
    assert.equal(
      result.transcript.operations.recovery.peerIdentityPersisted,
      true,
    );
    assert.equal(
      result.transcript.restoration.exactBridgeProcessesRestored,
      true,
    );
    assert.deepEqual(deps.metrics(), {
      bridgePaused: false,
      bridgeResumes: 1,
      daemonRestarts: 1,
      launches: 2,
      desktopPid: null,
    });
    assert.deepEqual(fs.readdirSync(value.options.rawOutputDir).sort(), [
      "smarthub-controlled-atspi.json",
      "smarthub-controlled.png",
      "smarthub-degraded-atspi.json",
      "smarthub-degraded.png",
      "smarthub-discovered-atspi.json",
      "smarthub-discovered.png",
      "smarthub-marker.json",
      "smarthub-native-transcript.json",
      "smarthub-peer-manifest.json",
      "smarthub-recovered-atspi.json",
      "smarthub-recovered.png",
    ]);
  } finally {
    fs.rmSync(value.root, { recursive: true, force: true });
  }
});

test("P-28 native runner canonicalizes supported live desktop identities", () => {
  assert.equal(normalizeP28DesktopIdentity("GNOME"), "GNOME");
  assert.equal(normalizeP28DesktopIdentity("ubuntu:GNOME"), "GNOME");
  assert.equal(normalizeP28DesktopIdentity("KDE"), "KDE Plasma");
  assert.equal(normalizeP28DesktopIdentity("KDE Plasma"), "KDE Plasma");
  assert.equal(normalizeP28DesktopIdentity("sway"), "Sway/wlroots");
  assert.equal(normalizeP28DesktopIdentity("wlroots"), "Sway/wlroots");
  assert.equal(normalizeP28DesktopIdentity("XFCE"), "XFCE");
});

test("P-28 native runner rejects forged peer metadata", async () => {
  const value = fixture();
  try {
    await rejectsAggregate(
      value,
      dependencies(value, {
        mutateMetadata: (metadata) => {
          metadata.txt.platform = "darwin";
        },
      }),
      /platform is not Linux/u,
    );
  } finally {
    fs.rmSync(value.root, { recursive: true, force: true });
  }
});

test("P-28 native runner rejects a substituted installed daemon launcher", async () => {
  const value = fixture();
  try {
    await rejectsAggregate(
      value,
      dependencies(value, { substitutedPackage: true }),
      /substituted installed executable.*openburnbar-daemon-launch/u,
    );
  } finally {
    fs.rmSync(value.root, { recursive: true, force: true });
  }
});

test("P-28 native runner rejects stale and substituted AT-SPI evidence", async () => {
  for (const [setting, pattern] of [
    [{ staleAtspi: true }, /stale or future-dated/u],
    [{ substituteAtspi: true }, /substituted after capture/u],
  ]) {
    const value = fixture();
    try {
      await rejectsAggregate(value, dependencies(value, setting), pattern);
    } finally {
      fs.rmSync(value.root, { recursive: true, force: true });
    }
  }
});

test("P-28 native runner rejects duplicated screenshots", async () => {
  const value = fixture();
  try {
    await rejectsAggregate(
      value,
      dependencies(value, { duplicateScreenshots: true }),
      /screenshots are duplicated or replayed/u,
    );
  } finally {
    fs.rmSync(value.root, { recursive: true, force: true });
  }
});

test("P-28 native runner rejects symlinked evidence", async () => {
  const value = fixture();
  try {
    await rejectsAggregate(
      value,
      dependencies(value, { symlinkScreenshot: true }),
      /not an owned regular file/u,
    );
  } finally {
    fs.rmSync(value.root, { recursive: true, force: true });
  }
});

test("P-28 native runner rejects partial recovery", async () => {
  const value = fixture();
  try {
    await rejectsAggregate(
      value,
      dependencies(value, { partialRecovery: true }),
      /recovered status did not prove health and control/u,
    );
  } finally {
    fs.rmSync(value.root, { recursive: true, force: true });
  }
});

test("P-28 native runner preserves primary and cleanup failures", async () => {
  const value = fixture();
  const deps = dependencies(value, {
    mutateMetadata: (metadata) => {
      metadata.txt.transport = "ssh";
    },
    cleanupFailure: true,
  });
  try {
    await assert.rejects(
      runP28NativeSmartHubProbes(value.options, deps),
      (error) =>
        error instanceof AggregateError &&
        error.errors.some((item) =>
          /transport is invalid/u.test(item.message),
        ) &&
        error.errors.some((item) => /cleanup failure/u.test(item.message)),
    );
  } finally {
    fs.rmSync(value.root, { recursive: true, force: true });
  }
});
