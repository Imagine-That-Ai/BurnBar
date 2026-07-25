import assert from "node:assert/strict";
import test from "node:test";
import {
  EXPECTED_REPOSITORY,
  EXPECTED_VM,
  READ_ONLY_COMMANDS,
  REQUIRED_RUNNER_LABELS,
  collectReadOnlyCommandOutputs,
  evaluateP16HostPreflight,
  parseOrganizationRunnersOutput,
  parseRepositoryIdentityOutput,
  parseRepositoryVariablesOutput,
  parseUtmListOutput,
  parseXcrunDeviceOutput,
  validateLinuxGuestCoordinationRoot,
  validateMacCoordinationRoot,
} from "./preflight-p16-live-certification.mjs";

const MAC_ROOT = "/Users/tester/P16";
const LINUX_ROOT = "/mnt/utm-share/P16";

function repositoryOutput() {
  return JSON.stringify({ nameWithOwner: EXPECTED_REPOSITORY });
}

function utmOutput(status = "started") {
  return [
    "UUID                                 Status   Name",
    `076396F7-F96D-42C1-991F-840FFEB156CF stopped  ImagineThat CI Runner`,
    `${EXPECTED_VM.uuid} ${status.padEnd(8, " ")} ${EXPECTED_VM.name}`,
    "",
  ].join("\n");
}

function variablesOutput(rows = [
  { name: "OPENBURNBAR_P16_MACOS_COORDINATION_ROOT", value: MAC_ROOT },
  { name: "OPENBURNBAR_P16_LINUX_COORDINATION_ROOT", value: LINUX_ROOT },
]) {
  return JSON.stringify([{ total_count: rows.length, variables: rows }]);
}

function devicesOutput({ available = true, offline = false, duplicate = false } = {}) {
  const availableLine = "QA iPad (27.0) (00008132-001158191E9A401C)";
  const lines = [
    "== Devices ==",
    "QA Mac (AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE)",
  ];
  if (available) lines.push(availableLine);
  lines.push("", "== Devices Offline ==");
  if (offline) lines.push("Offline iPad (27.0) (00008132-001158191E9A402D)");
  if (duplicate) lines.push(availableLine);
  lines.push("", "== Simulators ==", "QA iPad Simulator (27.0) (4CD09CFC-5105-4FF7-AB44-A33E723E06CD)", "");
  return lines.join("\n");
}

function runner({
  id = 129,
  name = "ImagineThat-CI-M5Max-macOS",
  os = "macOS",
  status = "online",
  busy = false,
  labels = REQUIRED_RUNNER_LABELS,
} = {}) {
  return {
    id,
    name,
    os,
    status,
    busy,
    labels: labels.map((label) => ({ id: 0, name: label, type: "custom" })),
  };
}

function runnersOutput(rows = [runner()]) {
  return JSON.stringify([{ total_count: rows.length, runners: rows }]);
}

function trustedRootMetadata(overrides = {}) {
  return {
    isDirectory: true,
    isSymbolicLink: false,
    uid: 501,
    mode: 0o40700,
    realpath: MAC_ROOT,
    ...overrides,
  };
}

function readyInput(overrides = {}) {
  return {
    repositoryOutput: repositoryOutput(),
    utmOutput: utmOutput(),
    variablesOutput: variablesOutput(),
    devicesOutput: devicesOutput(),
    runnersOutput: runnersOutput(),
    currentUid: 501,
    inspectMacRoot: () => trustedRootMetadata(),
    commandErrors: {},
    ...overrides,
  };
}

test("ready host fixtures pass while live guest/share equivalence remains explicitly deferred", () => {
  const report = evaluateP16HostPreflight(readyInput());
  assert.equal(report.ready, true);
  assert.deepEqual(report.blockers, []);
  assert.equal(report.deferredChecks.length, 1);
  assert.match(report.deferredChecks[0].message, /not proven|validate them live/u);
  assert.equal(
    report.checks.find((check) => check.id === "linuxGuestCoordinationRoot").details.shareEquivalenceValidated,
    false,
  );
  assert.equal(
    report.checks.find((check) => check.id === "physicalIPad").details.simulator,
    false,
  );
});

test("stopped VM, missing roots, offline iPad, and unavailable runner are reported together", () => {
  const report = evaluateP16HostPreflight(readyInput({
    utmOutput: utmOutput("stopped"),
    variablesOutput: variablesOutput([]),
    devicesOutput: devicesOutput({ available: false, offline: true }),
    runnersOutput: runnersOutput([runner({ status: "offline", busy: false })]),
  }));
  assert.equal(report.ready, false);
  assert.deepEqual(
    new Set(report.blockers.map((blocker) => blocker.code)),
    new Set([
      "vm_not_running",
      "required_variables_missing",
      "dependency_unavailable",
      "physical_ipad_unavailable",
      "eligible_mac_runner_unavailable",
    ]),
  );
  const vm = report.checks.find((check) => check.id === "utmVm");
  assert.equal(vm.details.status, "stopped");
});

test("repository identity parser requires the exact expected repository and exact response shape", () => {
  assert.equal(parseRepositoryIdentityOutput(repositoryOutput()), EXPECTED_REPOSITORY);
  assert.throws(
    () => parseRepositoryIdentityOutput(JSON.stringify({ nameWithOwner: "attacker/BurnBar" })),
    /exact expected repository/u,
  );
  assert.throws(
    () => parseRepositoryIdentityOutput(JSON.stringify({
      nameWithOwner: EXPECTED_REPOSITORY,
      spoofed: EXPECTED_REPOSITORY,
    })),
    /exact expected repository/u,
  );
});

test("UTM parser binds exact name and UUID and rejects duplicates or split spoofed identities", () => {
  assert.deepEqual(parseUtmListOutput(utmOutput()), {
    uuid: EXPECTED_VM.uuid,
    status: "started",
    name: EXPECTED_VM.name,
  });
  assert.throws(
    () => parseUtmListOutput([
      "UUID                                 Status   Name",
      `${EXPECTED_VM.uuid} started  Decoy`,
      `AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE started  ${EXPECTED_VM.name}`,
    ].join("\n")),
    /different records/u,
  );
  assert.throws(
    () => parseUtmListOutput(`${utmOutput()}${EXPECTED_VM.uuid} stopped  Duplicate\n`),
    /duplicate or malformed UUID/u,
  );
});

test("repository variable parser supports deterministic pagination and rejects duplicates or truncation", () => {
  const parsed = parseRepositoryVariablesOutput(variablesOutput());
  assert.equal(parsed.get("OPENBURNBAR_P16_MACOS_COORDINATION_ROOT"), MAC_ROOT);
  assert.throws(
    () => parseRepositoryVariablesOutput(variablesOutput([
      { name: "OPENBURNBAR_P16_MACOS_COORDINATION_ROOT", value: MAC_ROOT },
      { name: "OPENBURNBAR_P16_MACOS_COORDINATION_ROOT", value: "/other" },
    ])),
    /duplicate name/u,
  );
  assert.throws(
    () => parseRepositoryVariablesOutput(JSON.stringify([{
      total_count: 2,
      variables: [{ name: "ONE", value: "/one" }],
    }])),
    /truncated, duplicated, or ambiguously paginated/u,
  );
});

test("coordination roots fail closed on lexical ambiguity and untrusted host metadata", () => {
  assert.deepEqual(validateLinuxGuestCoordinationRoot(LINUX_ROOT), {
    path: LINUX_ROOT,
    validation: "lexical-only",
    shareEquivalenceValidated: false,
  });
  for (const candidate of [
    "relative/path",
    "/",
    "/mnt/../tmp/p16",
    "/mnt//p16",
    "/mnt/p16/",
    "/mnt/p16\nspoof",
  ]) {
    assert.throws(() => validateLinuxGuestCoordinationRoot(candidate), /canonical absolute non-root/u);
  }
  assert.equal(validateMacCoordinationRoot(MAC_ROOT, trustedRootMetadata(), 501).mode, "0700");
  assert.throws(
    () => validateMacCoordinationRoot(MAC_ROOT, trustedRootMetadata({ isSymbolicLink: true }), 501),
    /real non-symlink directory/u,
  );
  assert.throws(
    () => validateMacCoordinationRoot(MAC_ROOT, trustedRootMetadata({ realpath: "/private/redirect" }), 501),
    /real non-symlink directory/u,
  );
  assert.throws(
    () => validateMacCoordinationRoot(MAC_ROOT, trustedRootMetadata({ uid: 502 }), 501),
    /owned by the invoking user/u,
  );
  assert.throws(
    () => validateMacCoordinationRoot(MAC_ROOT, trustedRootMetadata({ mode: 0o40750 }), 501),
    /exactly 0700/u,
  );
});

test("xcrun parser accepts one available physical iPad and rejects duplicate, ambiguous, or spoofed devices", () => {
  const parsed = parseXcrunDeviceOutput(devicesOutput({ offline: true }));
  assert.equal(parsed.availableCount, 1);
  assert.equal(parsed.offlineCount, 1);
  assert.equal(parsed.selected.identifierSha256.length, 64);
  assert.equal(parsed.selected.identifierSha256.includes("00008132"), false);
  assert.throws(
    () => parseXcrunDeviceOutput(devicesOutput({ duplicate: true })),
    /duplicate device identifier/u,
  );
  assert.throws(
    () => parseXcrunDeviceOutput(devicesOutput().replace(
      "QA Mac (AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE)",
      "Second iPad (27.0) (00008132-001158191E9A4099)",
    )),
    /more than one available physical iPad/u,
  );
  assert.throws(
    () => parseXcrunDeviceOutput(devicesOutput().replace("QA iPad (27.0)", "Spoof Simulator iPad (27.0)")),
    /Simulator-labelled device/u,
  );
});

test("runner parser requires real macOS OS state, every label, online status, and non-busy capacity", () => {
  const parsed = parseOrganizationRunnersOutput(runnersOutput([
    runner(),
    runner({ id: 130, name: "Busy", busy: true }),
    runner({ id: 131, name: "Spoofed OS", os: "Linux" }),
    runner({ id: 132, name: "Missing label", labels: REQUIRED_RUNNER_LABELS.slice(0, -1) }),
  ]));
  assert.deepEqual(parsed.eligible, [{ id: 129, name: "ImagineThat-CI-M5Max-macOS" }]);
  assert.equal(parsed.labelMatchCount, 2);
  assert.throws(
    () => parseOrganizationRunnersOutput(runnersOutput([
      runner(),
      runner({ id: 129, name: "Duplicate id" }),
    ])),
    /duplicate id or name/u,
  );
  assert.throws(
    () => parseOrganizationRunnersOutput(runnersOutput([
      runner({ labels: [...REQUIRED_RUNNER_LABELS, "IOS"] }),
    ])),
    /duplicate label/u,
  );
});

test("malformed command output is a blocker and raw command output is never copied into the report", () => {
  const secretLikeText = "SUPER_SECRET_SHOULD_NOT_APPEAR";
  const report = evaluateP16HostPreflight(readyInput({
    runnersOutput: `{not-json:${secretLikeText}}`,
  }));
  assert.equal(report.ready, false);
  assert.equal(JSON.stringify(report).includes(secretLikeText), false);
  assert.equal(report.blockers.some((blocker) => blocker.code === "malformed_input"), true);
});

test("the live collector invokes only the bounded read-only command set", () => {
  const calls = [];
  const fixtures = new Map([
    ["gh repo view", repositoryOutput()],
    ["utmctl list", utmOutput()],
    ["gh api --paginate --slurp", variablesOutput()],
    ["xcrun xctrace list", devicesOutput()],
  ]);
  const outputs = collectReadOnlyCommandOutputs((command, args) => {
    calls.push([command, ...args]);
    let stdout = "";
    if (command === "gh" && args[0] === "api" && args.at(-1).startsWith("orgs/")) {
      stdout = runnersOutput();
    } else {
      stdout = fixtures.get([command, ...args.slice(0, 2)].join(" "))
        ?? fixtures.get([command, ...args.slice(0, 3)].join(" "))
        ?? "";
    }
    return { status: 0, stdout, failed: false };
  });
  assert.equal(calls.length, READ_ONLY_COMMANDS.length);
  assert.deepEqual(calls, READ_ONLY_COMMANDS.map((spec) => [spec.command, ...spec.args]));
  assert.deepEqual(outputs.commandErrors, {});
  assert.equal(calls.some((call) => call.includes("--method") || call.includes("POST")), false);
  assert.equal(calls.some((call) => call[0] === "utmctl" && call[1] !== "list"), false);
});
