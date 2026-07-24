#!/usr/bin/env node
import crypto from "node:crypto";
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import {
  P24_CONFIG_WRITES,
  P24_SETTINGS_DEEP_LINK,
  P24_SETTINGS_TAB_OWNERSHIP,
  P24_SETTINGS_TABS,
} from "./lib/p24-settings-proof.mjs";
import { verifyInstalledCandidate } from "./run-p08-mercury-media-session.mjs";

const ROOT = path.resolve(
  path.dirname(fileURLToPath(import.meta.url)),
  "../..",
);

function assert(value, message) {
  if (!value) throw new Error(message);
}
function stable(value) {
  return JSON.stringify(value);
}
function now(clock) {
  const value = Math.max(Date.now(), clock.value + 1);
  clock.value = value;
  return new Date(value).toISOString();
}
function privateOutput(directory) {
  fs.mkdirSync(directory, { recursive: true, mode: 0o700 });
  const stat = fs.lstatSync(directory);
  assert(
    stat.isDirectory() &&
      !stat.isSymbolicLink() &&
      stat.uid === process.getuid?.() &&
      (stat.mode & 0o077) === 0,
    "P-24 output must be owner-only",
  );
  assert(fs.readdirSync(directory).length === 0, "P-24 output must be empty");
  return fs.realpathSync(directory);
}
function screenshot(file, output, label) {
  const absolute = fs.realpathSync(file);
  const stat = fs.lstatSync(absolute);
  assert(
    path.dirname(absolute) === output &&
      stat.isFile() &&
      !stat.isSymbolicLink() &&
      stat.size >= 1024,
    `${label} screenshot is invalid`,
  );
  return path.basename(absolute);
}
function tree(value, title) {
  assert(
    Array.isArray(value?.nodes) && value.nodes.length >= 10,
    `P-24 ${title} AT-SPI tree is incomplete`,
  );
  assert(
    value.nodes.some(
      (node) =>
        node.name === "Search settings" && node.states?.includes("focusable"),
    ),
    `P-24 ${title} omitted Settings search`,
  );
  assert(
    value.nodes.some(
      (node) =>
        node.name === title &&
        node.states?.includes("focused") &&
        node.actions?.length > 0,
    ),
    `P-24 ${title} is not focused and actionable`,
  );
  return value.nodes;
}

async function restore(context) {
  for (const receipt of [...context.receipts].reverse()) {
    if (receipt.kind === "daemon-config") {
      await context.dependencies.settings.restoreField(
        receipt.field,
        receipt.before,
      );
      const restored = await context.dependencies.settings.readField(
        receipt.field,
      );
      assert(
        stable(restored) === stable(receipt.before),
        `P-24 ${receipt.field} restoration failed`,
      );
      receipt.restored = restored;
    } else {
      const restored = await context.dependencies.native.restoreLaunchAtLogin(
        receipt.before,
      );
      assert(
        restored.enabled === receipt.before.enabled,
        "P-24 launch-at-login restoration failed",
      );
      receipt.restored = restored;
    }
    receipt.status = "passed";
  }
  if (context.receipts.length > 0) {
    await context.dependencies.daemon.restart();
    context.restartCount += 1;
  }
}

export async function runP24NativeSettingsProbes(options, dependencies) {
  assert(
    (dependencies.platform ?? process.platform) === "linux",
    "P-24 requires Linux",
  );
  assert(
    dependencies.desktopSession === true,
    "P-24 requires a real desktop session",
  );
  (dependencies.installedVerifier ?? verifyInstalledCandidate)(options);
  const output = privateOutput(options.rawOutputDir);
  assert(
    (await dependencies.desktopProcessIDs()).length === 0,
    "P-24 requires no pre-existing installed desktop process",
  );
  for (const name of ["readField", "writeField", "restoreField"])
    assert(
      typeof dependencies.settings?.[name] === "function",
      `P-24 Settings ${name} adapter is required`,
    );
  for (const name of ["restart", "stop", "start"])
    assert(
      typeof dependencies.daemon?.[name] === "function",
      `P-24 daemon ${name} adapter is required`,
    );
  for (const name of [
    "launchAtLoginStatus",
    "launchAtLoginSet",
    "restoreLaunchAtLogin",
  ])
    assert(
      typeof dependencies.native?.[name] === "function",
      `P-24 native ${name} adapter is required`,
    );
  const marker =
    dependencies.marker ?? `p24-${crypto.randomBytes(8).toString("hex")}`;
  assert(/^p24-[a-f0-9]{16}$/u.test(marker), "P-24 marker is invalid");
  const context = {
    dependencies,
    receipts: [],
    restartCount: 0,
  };
  const clock = { value: 0 };
  const tabs = [];
  let launched = false;
  let completed = false;
  try {
    await dependencies.ui.launch(P24_SETTINGS_DEEP_LINK);
    launched = true;
    for (const [tabId, title] of P24_SETTINGS_TABS) {
      const observed = await dependencies.ui.auditTab({
        deepLink: P24_SETTINGS_DEEP_LINK,
        marker,
        query: title,
        tabId,
        title,
      });
      const nodes = tree(observed.tree, title);
      assert(
        observed.selectedName === title && observed.focusedName === title,
        `P-24 ${tabId} selection drifted`,
      );
      tabs.push({
        tabId,
        query: title,
        deepLink: P24_SETTINGS_DEEP_LINK,
        selectedName: title,
        focusedName: title,
        action: observed.action,
        nodes,
        screenshot: screenshot(observed.screenshot, output, `P-24 ${tabId}`),
        at: now(clock),
      });
    }

    for (const write of P24_CONFIG_WRITES) {
      const before = await dependencies.settings.readField(write.field);
      const receipt = {
        kind: "daemon-config",
        tabId: "data-privacy",
        control: write.control,
        field: write.field,
        method: "daemon.config.update",
        before,
        requested: null,
        readback: null,
        afterRestart: null,
        restored: null,
        status: "pending-restoration",
      };
      context.receipts.push(receipt);
      const requested = await dependencies.settings.writeField(
        write.field,
        !before.value,
      );
      receipt.requested = requested;
      assert(
        requested.field === write.field && requested.value !== before.value,
        `P-24 ${write.field} mutation was a no-op`,
      );
      const readback = await dependencies.settings.readField(write.field);
      receipt.readback = readback;
      assert(
        stable(readback) === stable(requested),
        `P-24 ${write.field} daemon readback failed`,
      );
      await dependencies.daemon.restart();
      context.restartCount += 1;
      const afterRestart = await dependencies.settings.readField(write.field);
      receipt.afterRestart = afterRestart;
      assert(
        stable(afterRestart) === stable(requested),
        `P-24 ${write.field} restart persistence failed`,
      );
    }

    const launchBefore = await dependencies.native.launchAtLoginStatus();
    const launchReceipt = {
      kind: "native",
      tabId: "general",
      control: "Launch OpenBurnBar at login",
      field: "launchAtLogin",
      method: "launch_at_login_set",
      before: launchBefore,
      requested: null,
      readback: null,
      afterRestart: null,
      restored: null,
      status: "pending-restoration",
    };
    context.receipts.push(launchReceipt);
    const launchRequested = await dependencies.native.launchAtLoginSet(
      !launchBefore.enabled,
    );
    launchReceipt.requested = launchRequested;
    assert(
      launchRequested.enabled === !launchBefore.enabled,
      "P-24 launch-at-login mutation was a no-op",
    );
    const launchReadback = await dependencies.native.launchAtLoginStatus();
    launchReceipt.readback = launchReadback;
    assert(
      launchReadback.enabled === launchRequested.enabled,
      "P-24 launch-at-login readback failed",
    );
    await dependencies.daemon.restart();
    context.restartCount += 1;
    const launchAfterRestart = await dependencies.native.launchAtLoginStatus();
    launchReceipt.afterRestart = launchAfterRestart;
    assert(
      launchAfterRestart.enabled === launchRequested.enabled,
      "P-24 launch-at-login restart persistence failed",
    );
    await dependencies.daemon.stop();
    const degradedRaw = await dependencies.ui.captureRecovery("degraded");
    const degraded = {
      state: "degraded",
      at: now(clock),
      focusedName: degradedRaw.focusedName,
      nodes: tree(degradedRaw.tree, degradedRaw.focusedName),
      screenshot: screenshot(degradedRaw.screenshot, output, "P-24 degraded"),
    };
    await dependencies.daemon.start();
    context.restartCount += 1;
    const recoveredRaw = await dependencies.ui.captureRecovery("recovered");
    const recovered = {
      state: "recovered",
      at: now(clock),
      focusedName: recoveredRaw.focusedName,
      nodes: tree(recoveredRaw.tree, recoveredRaw.focusedName),
      screenshot: screenshot(recoveredRaw.screenshot, output, "P-24 recovered"),
    };

    await restore(context);
    const transcript = {
      schemaVersion: 2,
      producer: "openburnbar-p24-installed-settings-probes-v2",
      marker,
      fixtureMode: false,
      tabs,
      tabOwnership: P24_SETTINGS_TAB_OWNERSHIP,
      writeReceipts: context.receipts,
      recovery: { restartCount: context.restartCount, degraded, recovered },
      originalStateRestored: true,
    };
    fs.writeFileSync(
      path.join(output, "settings-native-transcript.json"),
      `${JSON.stringify(transcript, null, 2)}\n`,
      { flag: "wx", mode: 0o600 },
    );
    completed = true;
    return { output, marker, transcript };
  } finally {
    if (launched) await dependencies.ui.stop();
    if (!completed) await restore(context);
  }
}

if (
  process.argv[1] &&
  path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)
) {
  import("./run-p24-installed-settings-workflow.mjs")
    .then(({ runP24InstalledSettingsWorkflow }) =>
      runP24InstalledSettingsWorkflow(process.argv.slice(2)),
    )
    .then((result) => process.stdout.write(`${JSON.stringify(result)}\n`))
    .catch((error) => {
      process.stderr.write(
        `P-24 installed Settings workflow failed: ${error.message}\n`,
      );
      process.exitCode = 1;
    });
}

export const P24_RUNNER_ROOT = ROOT;
