import crypto from "node:crypto";
import {
  exactKeys,
  parseJson,
  validateArtifact,
  validateCollectedAt,
  validateInstalledSessionEnvelope,
  validatePng,
} from "./installed-ui-proof.mjs";

export const P24_REQUIREMENT_ID = "P-24";
export const P24_PROOF_ROLE = "feature.settings-installed";
export const P24_PROOF_FILENAME = "p24-installed-settings-proof.json";
export const P24_SESSION_FILENAME = "p24-installed-settings-session.json";
export const P24_SETTINGS_DEEP_LINK = "openburnbar://settings";
export const P24_SETTINGS_TABS = Object.freeze([
  ["home", "Home"],
  ["general", "General"],
  ["updates", "Updates"],
  ["daemon", "Engine Room"],
  ["account", "Account"],
  ["cloud", "Cloud"],
  ["agents", "Agents"],
  ["model-proxy", "Model Proxy"],
  ["alerts", "Alerts"],
  ["notifications", "Notifications"],
  ["devices-and-sync", "Devices & Sync"],
  ["text-expansion", "Text Expansion"],
  ["media", "Media & Sharing"],
  ["data-privacy", "Data & Privacy"],
  ["computer-use", "Computer Use"],
  ["pets", "Pets"],
]);
export const P24_CONFIG_WRITES = Object.freeze([
  { field: "telemetryEnabled", control: "Telemetry" },
  { field: "privacyOptIn", control: "Privacy opt-in" },
  { field: "cloudSyncEnabled", control: "Cloud sync" },
]);
export const P24_SETTINGS_TAB_OWNERSHIP = Object.freeze([
  {
    tabId: "home",
    title: "Home",
    mode: "read-only",
    ownerRequirement: "P-24",
    note: "Settings inventory and routing summary only",
  },
  {
    tabId: "general",
    title: "General",
    mode: "owned-write",
    ownerRequirement: "P-24",
    note: "Launch at login via launch_at_login_set",
  },
  {
    tabId: "updates",
    title: "Updates",
    mode: "delegated",
    ownerRequirement: "P-25",
    note: "Update lifecycle writes are certified by P-25",
  },
  {
    tabId: "daemon",
    title: "Engine Room",
    mode: "delegated",
    ownerRequirement: "P-33",
    note: "Daemon reliability controls are certified by P-33",
  },
  {
    tabId: "account",
    title: "Account",
    mode: "delegated",
    ownerRequirement: "P-15",
    note: "Account and billing writes are certified by P-15",
  },
  {
    tabId: "cloud",
    title: "Cloud",
    mode: "delegated",
    ownerRequirement: "P-16",
    note: "Cloud and device writes are certified by P-16",
  },
  {
    tabId: "agents",
    title: "Agents",
    mode: "delegated",
    ownerRequirement: "P-20",
    note: "Mission and agent writes are certified by P-20",
  },
  {
    tabId: "model-proxy",
    title: "Model Proxy",
    mode: "delegated",
    ownerRequirement: "P-23",
    note: "Provider workspace writes are certified by P-23",
  },
  {
    tabId: "alerts",
    title: "Alerts",
    mode: "delegated",
    ownerRequirement: "P-27",
    note: "Alert routing writes are certified by P-27",
  },
  {
    tabId: "notifications",
    title: "Notifications",
    mode: "delegated",
    ownerRequirement: "P-27",
    note: "Notification writes are certified by P-27",
  },
  {
    tabId: "devices-and-sync",
    title: "Devices & Sync",
    mode: "delegated",
    ownerRequirement: "P-16",
    note: "Pairing and sync writes are certified by P-16",
  },
  {
    tabId: "text-expansion",
    title: "Text Expansion",
    mode: "delegated",
    ownerRequirement: "P-29",
    note: "Text expansion writes are certified by P-29",
  },
  {
    tabId: "media",
    title: "Media & Sharing",
    mode: "delegated",
    ownerRequirement: "P-08",
    note: "Media capability writes are certified by P-08",
  },
  {
    tabId: "data-privacy",
    title: "Data & Privacy",
    mode: "owned-write",
    ownerRequirement: "P-24",
    note: "Three canonical daemon.config.update privacy fields",
  },
  {
    tabId: "computer-use",
    title: "Computer Use",
    mode: "delegated",
    ownerRequirement: "P-19",
    note: "Computer Use policy writes are certified by P-19",
  },
  {
    tabId: "pets",
    title: "Pets",
    mode: "delegated",
    ownerRequirement: "P-30",
    note: "Pet writes are certified by P-30",
  },
]);

const MARKER = /^p24-[a-f0-9]{16}$/u;
const WRITE_KEYS = Object.freeze([
  "afterRestart",
  "before",
  "control",
  "field",
  "kind",
  "method",
  "readback",
  "requested",
  "restored",
  "status",
  "tabId",
]);

function fail(message) {
  throw new Error(message);
}
function stable(value) {
  if (Array.isArray(value)) return `[${value.map(stable).join(",")}]`;
  if (value && typeof value === "object")
    return `{${Object.keys(value)
      .sort()
      .map((key) => `${JSON.stringify(key)}:${stable(value[key])}`)
      .join(",")}}`;
  return JSON.stringify(value);
}
function artifact(root, environmentId, record, label, options = {}) {
  return validateArtifact(
    root,
    record,
    P24_REQUIREMENT_ID,
    environmentId,
    label,
    options,
  );
}
function screenshot(root, environmentId, record, label) {
  const snapshot = artifact(root, environmentId, record, label, {
    mediaType: "png",
    minimumBytes: 1024,
  });
  const decoded = validatePng(snapshot.bytes, label);
  if (decoded.nonBlankPixelRatio < 0.05) fail(`${label} is blank`);
  return crypto.createHash("sha256").update(decoded.pixels).digest("hex");
}
function validateTab(event, [tabId, title], root, environmentId) {
  exactKeys(
    event,
    [
      "action",
      "at",
      "deepLink",
      "focusedName",
      "nodes",
      "query",
      "screenshot",
      "selectedName",
      "tabId",
    ],
    `P-24 ${tabId} UI event`,
  );
  if (
    event.tabId !== tabId ||
    event.query !== title ||
    event.deepLink !== P24_SETTINGS_DEEP_LINK ||
    event.selectedName !== title ||
    event.focusedName !== title ||
    !["click", "press", "activate", "select"].includes(event.action) ||
    !Number.isFinite(Date.parse(event.at)) ||
    !Array.isArray(event.nodes) ||
    event.nodes.length < 10 ||
    !event.nodes.some(
      (node) =>
        node?.name === "Search settings" && node.states?.includes("focusable"),
    ) ||
    !event.nodes.some(
      (node) =>
        node?.name === title &&
        node.states?.includes("focused") &&
        node.actions?.length > 0,
    )
  )
    fail(
      `P-24 ${tabId} is not searchable, actionable, selected, and focused through AT-SPI`,
    );
  return screenshot(root, environmentId, event.screenshot, `P-24 ${tabId}`);
}
function validateOwnership(rows) {
  if (
    !Array.isArray(rows) ||
    stable(rows) !== stable(P24_SETTINGS_TAB_OWNERSHIP)
  )
    fail("P-24 Settings tab ownership is incomplete or overclaims writes");
}
function expectedWrite(index) {
  if (index < P24_CONFIG_WRITES.length)
    return {
      kind: "daemon-config",
      tabId: "data-privacy",
      field: P24_CONFIG_WRITES[index].field,
      control: P24_CONFIG_WRITES[index].control,
      method: "daemon.config.update",
    };
  return {
    kind: "native",
    tabId: "general",
    field: "launchAtLogin",
    control: "Launch OpenBurnBar at login",
    method: "launch_at_login_set",
  };
}
function validateReceipt(receipt, index) {
  const expected = expectedWrite(index);
  exactKeys(receipt, WRITE_KEYS, `P-24 write receipt ${index}`);
  if (
    receipt.kind !== expected.kind ||
    receipt.tabId !== expected.tabId ||
    receipt.field !== expected.field ||
    receipt.control !== expected.control ||
    receipt.method !== expected.method ||
    receipt.status !== "passed" ||
    stable(receipt.requested) !== stable(receipt.readback) ||
    stable(receipt.requested) !== stable(receipt.afterRestart) ||
    stable(receipt.before) !== stable(receipt.restored) ||
    stable(receipt.before) === stable(receipt.requested)
  )
    fail(`P-24 ${expected.field} write did not round-trip and restore exactly`);
  if (expected.kind === "daemon-config") {
    for (const value of [
      receipt.before,
      receipt.requested,
      receipt.readback,
      receipt.afterRestart,
      receipt.restored,
    ])
      if (value?.field !== expected.field || typeof value.value !== "boolean")
        fail(`P-24 ${expected.field} is not a canonical boolean config write`);
  } else {
    for (const value of [
      receipt.before,
      receipt.requested,
      receipt.readback,
      receipt.afterRestart,
      receipt.restored,
    ])
      if (
        typeof value?.enabled !== "boolean" ||
        !String(value.path).endsWith(
          "/.config/autostart/openburnbar.desktop",
        ) ||
        !["packaged", "user"].includes(value.source) ||
        typeof value.userOverride !== "boolean"
      )
        fail("P-24 launch-at-login receipt is not native XDG state");
  }
}
function validateRecovery(event, state, root, environmentId, hashes) {
  exactKeys(
    event,
    ["at", "focusedName", "nodes", "screenshot", "state"],
    `P-24 ${state} state`,
  );
  const expected =
    state === "degraded"
      ? /did not respond|retry|unavailable/iu
      : /connected|settings|healthy/iu;
  if (
    event.state !== state ||
    !Number.isFinite(Date.parse(event.at)) ||
    !Array.isArray(event.nodes) ||
    !event.nodes.some((node) => expected.test(node?.name ?? "")) ||
    !event.nodes.some(
      (node) =>
        node?.name === event.focusedName &&
        node.states?.includes("focused") &&
        node.actions?.length > 0,
    )
  )
    fail(`P-24 ${state} state is not truthful and accessible`);
  const hash = screenshot(
    root,
    environmentId,
    event.screenshot,
    `P-24 ${state}`,
  );
  if (hashes.has(hash)) fail(`P-24 ${state} screenshot replays another state`);
  hashes.add(hash);
}

export function validateP24InstalledSession(
  document,
  binding,
  { repoRoot = binding.repoRoot } = {},
) {
  exactKeys(
    document,
    [
      "candidate",
      "capture",
      "desktop",
      "environmentId",
      "evidence",
      "id",
      "marker",
      "package",
      "recovery",
      "requirementId",
      "schemaVersion",
      "settings",
      "targetHead",
    ],
    "P-24 installed session",
  );
  if (
    document.schemaVersion !== 2 ||
    document.id !== "openburnbar-linux-p24-installed-settings-session-v2" ||
    !MARKER.test(document.marker ?? "")
  )
    fail("P-24 installed session identity is invalid");
  const envelope = validateInstalledSessionEnvelope(
    document,
    { ...binding, repoRoot },
    P24_REQUIREMENT_ID,
    "P-24 installed Settings session",
  );
  exactKeys(
    document.settings,
    ["deepLink", "tabOwnership", "tabs", "writeReceipts"],
    "P-24 Settings evidence",
  );
  if (
    document.settings.deepLink !== P24_SETTINGS_DEEP_LINK ||
    document.settings.tabs?.length !== P24_SETTINGS_TABS.length ||
    document.settings.writeReceipts?.length !== 4
  )
    fail("P-24 requires 16 navigable tabs and exactly four real writes");
  validateOwnership(document.settings.tabOwnership);
  const hashes = new Set();
  P24_SETTINGS_TABS.forEach((expected, index) => {
    const hash = validateTab(
      document.settings.tabs[index],
      expected,
      repoRoot,
      document.environmentId,
    );
    if (hashes.has(hash))
      fail("P-24 tab screenshots must be visually distinct captures");
    hashes.add(hash);
  });
  document.settings.writeReceipts.forEach(validateReceipt);
  exactKeys(
    document.recovery,
    ["degraded", "recovered", "restartCount"],
    "P-24 recovery receipt",
  );
  if (
    !Number.isSafeInteger(document.recovery.restartCount) ||
    document.recovery.restartCount < 6
  )
    fail("P-24 restart evidence is incomplete");
  validateRecovery(
    document.recovery.degraded,
    "degraded",
    repoRoot,
    document.environmentId,
    hashes,
  );
  validateRecovery(
    document.recovery.recovered,
    "recovered",
    repoRoot,
    document.environmentId,
    hashes,
  );
  exactKeys(document.evidence, ["nativeTranscript"], "P-24 evidence index");
  const transcript = artifact(
    repoRoot,
    document.environmentId,
    document.evidence.nativeTranscript,
    "P-24 native transcript",
    { mediaType: "json", minimumBytes: 1000 },
  );
  const raw = parseJson(transcript.bytes, "P-24 native transcript");
  if (
    raw.schemaVersion !== 2 ||
    raw.producer !== "openburnbar-p24-installed-settings-probes-v2" ||
    raw.marker !== document.marker ||
    raw.fixtureMode !== false ||
    raw.tabs?.length !== P24_SETTINGS_TABS.length ||
    raw.writeReceipts?.length !== 4 ||
    raw.originalStateRestored !== true ||
    stable(raw.tabOwnership) !== stable(document.settings.tabOwnership) ||
    stable(raw.writeReceipts) !== stable(document.settings.writeReceipts)
  )
    fail(
      "P-24 transcript is synthetic, incomplete, overclaimed, or unrestored",
    );
  const evidence = [
    ...envelope.attestation,
    document.evidence.nativeTranscript,
    ...document.settings.tabs.map((tab) => tab.screenshot),
    document.recovery.degraded.screenshot,
    document.recovery.recovered.screenshot,
  ];
  if (new Set(evidence.map((record) => record.path)).size !== evidence.length)
    fail("P-24 reuses an evidence artifact");
  return { document, evidence, endedAt: envelope.endedAt };
}

export function buildP24Proof({ session, source, collectedAt }) {
  return {
    schemaVersion: 2,
    id: "openburnbar-linux-p24-installed-settings-proof-v2",
    requirementId: P24_REQUIREMENT_ID,
    environmentId: session.environmentId,
    targetHead: session.targetHead,
    candidate: session.candidate,
    package: {
      architecture: session.package.architecture,
      format: session.package.format,
      version: session.package.version,
      manifest: session.package.manifest,
      signature: session.package.signature,
    },
    collectedAt,
    source,
    claim: {
      passed: true,
      navigableTabs: P24_SETTINGS_TABS.length,
      searchableTabs: P24_SETTINGS_TABS.length,
      verifiedWrites: 4,
      ownedWritableTabs: 2,
      delegatedOrReadOnlyTabs: 14,
      deepLink: P24_SETTINGS_DEEP_LINK,
      daemonRestartPersistence: true,
      xdgAutostartPersistence: true,
      degradedRecovery: true,
      exactStateRestoration: true,
      accessibleUI: true,
    },
    evidence: [
      session.evidence.nativeTranscript,
      ...session.settings.tabs.map((tab) => tab.screenshot),
      session.recovery.degraded.screenshot,
      session.recovery.recovered.screenshot,
    ],
  };
}

export function validateP24Proof(
  { repoRoot, snapshot, ...binding },
  now = Date.now(),
) {
  const proof = parseJson(snapshot.bytes, "P-24 proof");
  exactKeys(
    proof,
    [
      "candidate",
      "claim",
      "collectedAt",
      "environmentId",
      "evidence",
      "id",
      "package",
      "requirementId",
      "schemaVersion",
      "source",
      "targetHead",
    ],
    "P-24 proof",
  );
  if (
    proof.schemaVersion !== 2 ||
    proof.id !== "openburnbar-linux-p24-installed-settings-proof-v2" ||
    proof.requirementId !== P24_REQUIREMENT_ID ||
    proof.environmentId !== binding.environmentId ||
    proof.targetHead !== binding.targetHead ||
    proof.candidate.runId !== String(binding.candidateRunId) ||
    proof.candidate.artifactDigest !== binding.candidateArtifactDigest ||
    proof.package.version !== binding.packageVersion ||
    proof.package.manifest.sha256 !== binding.manifestSha256 ||
    proof.package.signature.sha256 !== binding.manifestSignatureSha256
  )
    fail("P-24 proof is not bound to the selected installed candidate");
  const source = artifact(
    repoRoot,
    binding.environmentId,
    proof.source,
    "P-24 source session",
    { mediaType: "json", minimumBytes: 1000 },
  );
  const validated = validateP24InstalledSession(
    parseJson(source.bytes, "P-24 source session"),
    { ...binding, repoRoot },
    { repoRoot },
  );
  validateCollectedAt(proof.collectedAt, validated.endedAt, now);
  exactKeys(
    proof.claim,
    [
      "accessibleUI",
      "daemonRestartPersistence",
      "deepLink",
      "degradedRecovery",
      "delegatedOrReadOnlyTabs",
      "exactStateRestoration",
      "navigableTabs",
      "ownedWritableTabs",
      "passed",
      "searchableTabs",
      "verifiedWrites",
      "xdgAutostartPersistence",
    ],
    "P-24 claim",
  );
  if (
    proof.claim.passed !== true ||
    proof.claim.navigableTabs !== 16 ||
    proof.claim.searchableTabs !== 16 ||
    proof.claim.verifiedWrites !== 4 ||
    proof.claim.ownedWritableTabs !== 2 ||
    proof.claim.delegatedOrReadOnlyTabs !== 14 ||
    proof.claim.deepLink !== P24_SETTINGS_DEEP_LINK ||
    [
      "accessibleUI",
      "daemonRestartPersistence",
      "degradedRecovery",
      "exactStateRestoration",
      "xdgAutostartPersistence",
    ].some((field) => proof.claim[field] !== true) ||
    proof.evidence?.length !== 19 ||
    new Set(proof.evidence.map((record) => record.path)).size !== 19
  )
    fail("P-24 proof claim or evidence inventory is incomplete");
  proof.evidence.forEach((record) =>
    artifact(repoRoot, binding.environmentId, record, "P-24 proof evidence"),
  );
  return { ...proof, source, evidence: proof.evidence };
}
