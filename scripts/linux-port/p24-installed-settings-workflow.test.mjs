import assert from "node:assert/strict";
import path from "node:path";
import test from "node:test";
import {
  parseP24InstalledArguments,
  runP24InstalledSettingsWorkflow,
} from "./run-p24-installed-settings-workflow.mjs";

function argumentsFor(root = "/tmp/openburnbar-p24-workflow") {
  return [
    "--raw-output-dir",
    path.join(root, "raw"),
    "--support-dir",
    path.join(root, "support"),
    "--home-dir",
    path.join(root, "home"),
    "--socket-path",
    path.join(root, "support/daemon.sock"),
    "--token-file",
    path.join(root, "support/token"),
    "--index-database",
    path.join(root, "support/index.sqlite"),
    "--environment",
    "ubuntu-24.04-gnome-x11-aarch64",
    "--target-head",
    "a".repeat(40),
    "--candidate-run-id",
    "242424",
    "--candidate-artifact-digest",
    `sha256:${"b".repeat(64)}`,
    "--package-version",
    "1.2.3",
    "--manifest-sha256",
    "c".repeat(64),
    "--manifest-signature-sha256",
    "d".repeat(64),
    "--compositor",
    "Mutter",
  ];
}

test("P-24 installed workflow parses every isolated candidate binding", () => {
  const options = parseP24InstalledArguments(argumentsFor());
  assert.equal(options.environmentId, "ubuntu-24.04-gnome-x11-aarch64");
  assert.equal(options.targetHead, "a".repeat(40));
  assert.equal(
    options.socketPath,
    "/tmp/openburnbar-p24-workflow/support/daemon.sock",
  );
  assert.throws(
    () => parseP24InstalledArguments(argumentsFor().slice(0, -2)),
    /--compositor is required/u,
  );
});

test("P-24 installed CLI wires the real dependency boundary and always restores", async () => {
  const dependencies = { marker: "installed-adapter" };
  let restored = 0;
  let observed;
  const result = await runP24InstalledSettingsWorkflow(argumentsFor(), {
    async createWorkflow(options) {
      assert.equal(options.packageVersion, "1.2.3");
      return {
        dependencies,
        async restore() {
          restored += 1;
        },
      };
    },
    async runProbe(options, received) {
      observed = { options, received };
      return { output: options.rawOutputDir, marker: "p24-0123456789abcdef" };
    },
  });
  assert.equal(observed.received, dependencies);
  assert.equal(result.marker, "p24-0123456789abcdef");
  assert.equal(restored, 1);
});

test("P-24 installed CLI restores external service state after probe failure", async () => {
  let restored = 0;
  await assert.rejects(
    runP24InstalledSettingsWorkflow(argumentsFor(), {
      async createWorkflow() {
        return {
          dependencies: {},
          async restore() {
            restored += 1;
          },
        };
      },
      async runProbe() {
        throw new Error("forced P-24 Settings failure");
      },
    }),
    /forced P-24 Settings failure/u,
  );
  assert.equal(restored, 1);
});

test("P-24 installed CLI makes restoration failure critical", async () => {
  await assert.rejects(
    runP24InstalledSettingsWorkflow(argumentsFor(), {
      async createWorkflow() {
        return {
          dependencies: {},
          async restore() {
            throw new Error("restore user daemon failed");
          },
        };
      },
      async runProbe() {
        throw new Error("primary probe failed");
      },
    }),
    (error) =>
      error instanceof AggregateError &&
      /CRITICAL workflow restoration failed/u.test(error.message) &&
      error.errors.length === 2,
  );
});
