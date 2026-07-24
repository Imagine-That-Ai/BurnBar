import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import test from "node:test";
import {
  P24_CONFIG_WRITES,
  P24_SETTINGS_TAB_OWNERSHIP,
  P24_SETTINGS_TABS,
} from "./lib/p24-settings-proof.mjs";
import { runP24NativeSettingsProbes } from "./run-p24-native-settings-probes.mjs";

function fixture() {
  const root = fs.mkdtempSync(
    path.join(os.tmpdir(), "openburnbar-p24-native-"),
  );
  const rawOutputDir = path.join(root, "raw");
  const config = new Map(P24_CONFIG_WRITES.map(({ field }) => [field, false]));
  let launch = {
    enabled: false,
    path: "/home/test/.config/autostart/openburnbar.desktop",
    source: "packaged",
    userOverride: false,
  };
  let restarts = 0;
  const screenshot = (name, seed) => {
    const file = path.join(rawOutputDir, name);
    fs.writeFileSync(file, Buffer.alloc(2048, seed));
    return file;
  };
  const tree = (name, extra = []) => ({
    nodes: [
      { name: "Search settings", states: ["focusable"], actions: ["focus"] },
      { name, states: ["focusable", "focused"], actions: ["click"] },
      ...extra.map((value) => ({ name: value, states: [], actions: [] })),
      ...Array.from({ length: 8 }, (_, index) => ({
        name: `node-${index}`,
        states: [],
        actions: [],
      })),
    ],
  });
  const writes = [];
  const dependencies = {
    platform: "linux",
    desktopSession: true,
    marker: "p24-fedcba0987654321",
    installedVerifier() {},
    async desktopProcessIDs() {
      return [];
    },
    settings: {
      async readField(field) {
        return { field, value: config.get(field) };
      },
      async writeField(field, value) {
        writes.push({ method: "daemon.config.update", field, value });
        config.set(field, value);
        return { field, value };
      },
      async restoreField(field, before) {
        config.set(field, before.value);
      },
    },
    daemon: {
      async restart() {
        restarts += 1;
      },
      async stop() {},
      async start() {
        restarts += 1;
      },
    },
    native: {
      async launchAtLoginStatus() {
        return structuredClone(launch);
      },
      async launchAtLoginSet(enabled) {
        writes.push({ method: "launch_at_login_set", enabled });
        launch = { ...launch, enabled, source: "user", userOverride: true };
        return structuredClone(launch);
      },
      async restoreLaunchAtLogin(before) {
        launch = structuredClone(before);
        return structuredClone(launch);
      },
    },
    ui: {
      async launch(uri) {
        assert.equal(uri, "openburnbar://settings");
      },
      async auditTab({ tabId, title }) {
        return {
          tree: tree(title),
          selectedName: title,
          focusedName: title,
          action: "click",
          screenshot: screenshot(
            `settings-${tabId}.png`,
            P24_SETTINGS_TABS.findIndex(([id]) => id === tabId) + 1,
          ),
        };
      },
      async captureRecovery(state) {
        const name =
          state === "degraded" ? "degraded Settings" : "recovered Settings";
        const extra =
          state === "degraded"
            ? ["Settings config did not respond", "Retry"]
            : ["Connected", "Settings healthy"];
        return {
          tree: tree(name, extra),
          focusedName: name,
          screenshot: screenshot(
            `settings-${state}.png`,
            state === "degraded" ? 91 : 92,
          ),
        };
      },
      async stop() {},
    },
  };
  return {
    root,
    rawOutputDir,
    dependencies,
    config,
    writes,
    launch: () => launch,
    restarts: () => restarts,
  };
}

test("P-24 proves 16 searchable tabs but exactly four real reversible writes", async () => {
  const value = fixture();
  try {
    const result = await runP24NativeSettingsProbes(
      { rawOutputDir: value.rawOutputDir, manifestSha256: "a".repeat(64) },
      value.dependencies,
    );
    assert.equal(result.transcript.tabs.length, 16);
    assert.deepEqual(
      result.transcript.tabOwnership,
      P24_SETTINGS_TAB_OWNERSHIP,
    );
    assert.equal(result.transcript.writeReceipts.length, 4);
    assert.deepEqual(
      result.transcript.writeReceipts.map(({ method, field }) => ({
        method,
        field,
      })),
      [
        ...P24_CONFIG_WRITES.map(({ field }) => ({
          method: "daemon.config.update",
          field,
        })),
        { method: "launch_at_login_set", field: "launchAtLogin" },
      ],
    );
    assert.ok(
      result.transcript.writeReceipts.every(
        (receipt) => receipt.status === "passed",
      ),
    );
    assert.equal(result.transcript.originalStateRestored, true);
    assert.ok(result.transcript.recovery.restartCount >= 6);
    assert.ok([...value.config.values()].every((item) => item === false));
    assert.deepEqual(value.launch(), {
      enabled: false,
      path: "/home/test/.config/autostart/openburnbar.desktop",
      source: "packaged",
      userOverride: false,
    });
    assert.deepEqual(
      value.writes.map(({ method }) => method),
      [
        "daemon.config.update",
        "daemon.config.update",
        "daemon.config.update",
        "launch_at_login_set",
      ],
    );
  } finally {
    fs.rmSync(value.root, { recursive: true, force: true });
  }
});

test("P-24 restores completed writes when a later real write fails", async () => {
  const value = fixture();
  value.dependencies.settings.writeField = async (field, requested) => {
    if (field === "cloudSyncEnabled")
      throw new Error("forced cloudSyncEnabled mutation failure");
    value.writes.push({ method: "daemon.config.update", field, requested });
    value.config.set(field, requested);
    return { field, value: requested };
  };
  try {
    await assert.rejects(
      runP24NativeSettingsProbes(
        { rawOutputDir: value.rawOutputDir, manifestSha256: "a".repeat(64) },
        value.dependencies,
      ),
      /forced cloudSyncEnabled mutation failure/u,
    );
    assert.ok([...value.config.values()].every((item) => item === false));
  } finally {
    fs.rmSync(value.root, { recursive: true, force: true });
  }
});
