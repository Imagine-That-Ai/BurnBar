import crypto from "node:crypto";
import {
  exactKeys,
  parseJson,
  validateArtifact,
  validateCollectedAt,
  validateInstalledSessionEnvelope,
  validatePng,
} from "./installed-ui-proof.mjs";

export const P26_REQUIREMENT_ID = "P-26";
export const P26_PROOF_ROLE = "feature.tray-native-shell-installed";
export const P26_PROOF_FILENAME = "p26-installed-tray-proof.json";
export const P26_SESSION_FILENAME = "p26-installed-tray-session.json";

const MARKER = /^p26-[a-f0-9]{16}$/u;
const SHA256 = /^[a-f0-9]{64}$/u;
const ROUTES = Object.freeze([
  ["dashboard", "Open dashboard", "Overview"],
  ["chat", "Open chat", "Chat / Hermes"],
  ["usage", "Open usage", "Insights"],
  ["updates", "Open updates", "Updates"],
  ["settings", "Open settings", "Settings"],
]);
const ACTIONS = Object.freeze([
  ...ROUTES.map(([phase, label]) => [phase, label]),
  ["reopen", "Open dashboard"],
  ["refresh", "Refresh status"],
  ["reconnect", "Reconnect daemon"],
  ["quit", "Quit OpenBurnBar"],
]);
const SCREENSHOTS = Object.freeze([
  "backgroundScreenshot",
  "dashboardScreenshot",
  "chatScreenshot",
  "usageScreenshot",
  "updatesScreenshot",
  "settingsScreenshot",
]);
const ATSPI = Object.freeze([
  "dashboardAccessibility",
  "chatAccessibility",
  "usageAccessibility",
  "updatesAccessibility",
  "settingsAccessibility",
]);

function fail(message) {
  throw new Error(message);
}
function timestamp(value, label) {
  const parsed = Date.parse(value);
  if (!Number.isFinite(parsed)) fail(`${label} timestamp is invalid`);
  return parsed;
}
function artifact(root, environmentId, record, label, options = {}) {
  return validateArtifact(
    root,
    record,
    P26_REQUIREMENT_ID,
    environmentId,
    label,
    options,
  );
}
function labels(menu) {
  return menu.map((item) => item.label);
}
function validateMenu(menu, label, expectedDaemon) {
  if (!Array.isArray(menu) || menu.length < 11) fail(`${label} is incomplete`);
  for (const [index, item] of menu.entries()) {
    exactKeys(item, ["enabled", "id", "label"], `${label} item ${index}`);
    if (
      !Number.isSafeInteger(item.id) ||
      typeof item.label !== "string" ||
      !item.label.trim() ||
      typeof item.enabled !== "boolean"
    )
      fail(`${label} item ${index} is invalid`);
  }
  const values = labels(menu);
  for (const [, expected] of ACTIONS)
    if (!values.includes(expected)) fail(`${label} omits ${expected}`);
  if (
    !values.includes(expectedDaemon) ||
    !values.some((value) =>
      /^Recent usage: (?!checking|unavailable).+/u.test(value),
    ) ||
    !values.some((value) => /^Updates: (?!checking).+/u.test(value))
  )
    fail(`${label} omits live daemon, usage, or update state`);
  return values;
}
function validateMarker(value, environmentId) {
  exactKeys(
    value,
    ["autostart", "installedExecutable", "marker", "safety"],
    "P-26 marker",
  );
  const expectedManager = environmentId.includes("ubuntu")
    ? "dpkg"
    : environmentId.includes("fedora")
      ? "rpm"
      : "pacman";
  if (
    !MARKER.test(value.marker ?? "") ||
    value.installedExecutable !== "/usr/bin/openburnbar-linux-desktop"
  )
    fail("P-26 marker identity is invalid");
  exactKeys(
    value.autostart,
    ["exec", "manager", "packageName", "packageOwned", "path", "sha256"],
    "P-26 autostart",
  );
  if (
    value.autostart.path !== "/etc/xdg/autostart/openburnbar.desktop" ||
    value.autostart.exec !== "openburnbar-linux-desktop --background" ||
    value.autostart.manager !== expectedManager ||
    value.autostart.packageName !== "openburnbar" ||
    value.autostart.packageOwned !== true ||
    !SHA256.test(value.autostart.sha256 ?? "")
  )
    fail("P-26 packaged autostart receipt is invalid");
  exactKeys(
    value.safety,
    [
      "daemonServiceRestored",
      "desktopProcessesRestored",
      "fixtureMode",
      "isolatedDaemon",
      "preexistingDesktopProcesses",
    ],
    "P-26 safety",
  );
  if (
    value.safety.fixtureMode !== false ||
    value.safety.isolatedDaemon !== true ||
    value.safety.daemonServiceRestored !== true ||
    value.safety.desktopProcessesRestored !== true ||
    value.safety.preexistingDesktopProcesses !== 0
  )
    fail("P-26 probe did not preserve the native process/service boundary");
}
function validateNative(
  value,
  marker,
  manifestSha256,
  packageVersion,
  startedAt,
  endedAt,
) {
  exactKeys(
    value,
    [
      "accessibility",
      "actions",
      "background",
      "daemon",
      "endedAt",
      "marker",
      "persistence",
      "producer",
      "restoration",
      "routes",
      "startedAt",
      "tray",
    ],
    "P-26 native transcript",
  );
  const nativeStart = timestamp(value.startedAt, "P-26 native start");
  const nativeEnd = timestamp(value.endedAt, "P-26 native end");
  if (
    nativeStart < startedAt ||
    nativeEnd > endedAt ||
    nativeEnd <= nativeStart ||
    value.producer !== "openburnbar-p26-installed-tray-probe-v1" ||
    value.marker !== marker.marker
  )
    fail("P-26 native transcript is not bound to the live session");
  exactKeys(
    value.background,
    ["command", "noVisibleWindow", "pid", "processAlive", "trayRegistered"],
    "P-26 background launch",
  );
  if (
    value.background.command !==
      "/usr/bin/openburnbar-linux-desktop --background" ||
    !Number.isSafeInteger(value.background.pid) ||
    value.background.pid <= 1 ||
    value.background.noVisibleWindow !== true ||
    value.background.processAlive !== true ||
    value.background.trayRegistered !== true
  )
    fail("P-26 did not prove tray-first background startup");
  exactKeys(
    value.tray,
    [
      "initialMenu",
      "initialMenuRevision",
      "menuPath",
      "path",
      "protocol",
      "disconnectedMenu",
      "disconnectedMenuRevision",
      "reconnectedMenu",
      "reconnectedMenuRevision",
      "refreshedMenu",
      "refreshedMenuRevision",
      "service",
      "tooltip",
    ],
    "P-26 tray",
  );
  if (
    !["StatusNotifierItem", "AppIndicator"].includes(value.tray.protocol) ||
    !/^:[0-9]+\.[0-9]+$/u.test(value.tray.service ?? "") ||
    !/^\/(?:org\/kde\/StatusNotifierItem|org\/ayatana\/NotificationItem)/u.test(
      value.tray.path ?? "",
    ) ||
    !/^\//u.test(value.tray.menuPath ?? "") ||
    value.tray.tooltip !== "OpenBurnBar — Linux desktop assistant"
  )
    fail("P-26 native tray registration is invalid");
  const connectedLabel = `Daemon: connected - p26-installed-${packageVersion}`;
  const initialLabels = validateMenu(
    value.tray.initialMenu,
    "P-26 initial menu",
    connectedLabel,
  );
  const refreshedLabels = validateMenu(
    value.tray.refreshedMenu,
    "P-26 refreshed menu",
    connectedLabel,
  );
  const disconnectedLabels = validateMenu(
    value.tray.disconnectedMenu,
    "P-26 disconnected menu",
    "Daemon: offline",
  );
  const reconnectedLabels = validateMenu(
    value.tray.reconnectedMenu,
    "P-26 reconnected menu",
    connectedLabel,
  );
  const revisions = [
    value.tray.initialMenuRevision,
    value.tray.refreshedMenuRevision,
    value.tray.disconnectedMenuRevision,
    value.tray.reconnectedMenuRevision,
  ];
  if (
    revisions.some(
      (revision) => !Number.isSafeInteger(revision) || revision < 0,
    ) ||
    revisions.some(
      (revision, index) => index > 0 && revision <= revisions[index - 1],
    )
  )
    fail("P-26 DBusMenu revisions do not prove refresh and reconnect changes");
  if (!Array.isArray(value.actions) || value.actions.length !== ACTIONS.length)
    fail("P-26 native action receipt count is invalid");
  let prior = nativeStart - 1;
  for (const [index, action] of value.actions.entries()) {
    exactKeys(
      action,
      ["at", "dbusReply", "label", "menuId", "phase"],
      `P-26 action ${index}`,
    );
    const at = timestamp(action.at, `P-26 action ${index}`);
    const [phase, label] = ACTIONS[index];
    const menu =
      index <= 6
        ? value.tray.initialMenu
        : index === 7
          ? value.tray.disconnectedMenu
          : value.tray.reconnectedMenu;
    const menuItem = menu.find((item) => item.label === label);
    if (
      action.phase !== phase ||
      action.label !== label ||
      !Number.isSafeInteger(action.menuId) ||
      action.menuId < 1 ||
      menuItem?.id !== action.menuId ||
      typeof action.dbusReply !== "string" ||
      !action.dbusReply.includes("method return") ||
      at <= prior ||
      at > nativeEnd
    )
      fail(`P-26 action ${phase} is invalid, reordered, or synthetic`);
    prior = at;
  }
  if (!Array.isArray(value.routes) || value.routes.length !== ROUTES.length)
    fail("P-26 route receipt count is invalid");
  for (const [index, route] of value.routes.entries()) {
    exactKeys(
      route,
      ["accessibleName", "appPid", "at", "manifestSha256", "route", "visible"],
      `P-26 route ${index}`,
    );
    const [expectedRoute, , accessibleName] = ROUTES[index];
    const at = timestamp(route.at, `P-26 route ${expectedRoute}`);
    const actionAt = timestamp(
      value.actions[index].at,
      `P-26 ${expectedRoute} action binding`,
    );
    const nextActionAt = timestamp(
      value.actions[index + 1].at,
      `P-26 ${expectedRoute} next action binding`,
    );
    if (
      route.route !== expectedRoute ||
      route.accessibleName !== accessibleName ||
      route.appPid !== value.background.pid ||
      route.manifestSha256 !== manifestSha256 ||
      route.visible !== true ||
      at <= actionAt ||
      at >= nextActionAt
    )
      fail(`P-26 route ${expectedRoute} is not candidate-bound UI evidence`);
  }
  exactKeys(
    value.accessibility,
    [
      "atspiApplication",
      "keyboardFocusObserved",
      "menuItemsEnabled",
      "semanticMenuItems",
    ],
    "P-26 accessibility",
  );
  if (
    value.accessibility.atspiApplication !== "OpenBurnBar" ||
    value.accessibility.keyboardFocusObserved !== true ||
    value.accessibility.menuItemsEnabled !== true ||
    value.accessibility.semanticMenuItems !==
      new Set(ACTIONS.map(([, label]) => label)).size
  )
    fail("P-26 accessibility or keyboard proof is incomplete");
  exactKeys(
    value.persistence,
    [
      "distinctRegistration",
      "quitTerminated",
      "relaunchNoVisibleWindow",
      "relaunchPid",
      "relaunchRegistration",
      "relaunchTerminated",
      "reopenSamePid",
      "trayReregistered",
      "windowHideLeftProcessAlive",
    ],
    "P-26 persistence",
  );
  if (
    !Number.isSafeInteger(value.persistence.relaunchPid) ||
    value.persistence.relaunchPid === value.background.pid ||
    !/^:[0-9]+\.[0-9]+\/(?:org\/kde\/StatusNotifierItem|org\/ayatana\/NotificationItem)/u.test(
      value.persistence.relaunchRegistration ?? "",
    ) ||
    value.persistence.relaunchRegistration ===
      `${value.tray.service}${value.tray.path}` ||
    [
      "distinctRegistration",
      "quitTerminated",
      "relaunchNoVisibleWindow",
      "relaunchTerminated",
      "reopenSamePid",
      "trayReregistered",
      "windowHideLeftProcessAlive",
    ].some((field) => value.persistence[field] !== true)
  )
    fail("P-26 background persistence/relaunch lifecycle is incomplete");
  exactKeys(
    value.daemon,
    [
      "afterReconnectHealth",
      "beforeHealth",
      "beforeReconnectHealth",
      "updateState",
      "usageState",
    ],
    "P-26 daemon state",
  );
  if (
    value.daemon.beforeHealth !== "connected" ||
    value.daemon.beforeReconnectHealth !== "disconnected" ||
    value.daemon.afterReconnectHealth !== "connected" ||
    !String(value.daemon.usageState ?? "").startsWith("Recent usage: ") ||
    /checking|unavailable/iu.test(value.daemon.usageState) ||
    !String(value.daemon.updateState ?? "").startsWith("Updates: ") ||
    /checking/iu.test(value.daemon.updateState)
  )
    fail("P-26 daemon, usage, or signed-update state is not live");
  if (
    !initialLabels.includes(connectedLabel) ||
    !initialLabels.includes(value.daemon.usageState) ||
    !initialLabels.includes(value.daemon.updateState) ||
    !refreshedLabels.includes(connectedLabel) ||
    !refreshedLabels.some((label) =>
      /^Recent usage: (?!checking|unavailable)/u.test(label),
    ) ||
    !refreshedLabels.some((label) => /^Updates: (?!checking)/u.test(label)) ||
    !disconnectedLabels.includes("Daemon: offline") ||
    !reconnectedLabels.includes(connectedLabel)
  )
    fail("P-26 daemon summary is not derived from its native menu snapshots");
  exactKeys(
    value.restoration,
    [
      "daemonActiveAfter",
      "daemonWasActive",
      "desktopPidsAfter",
      "desktopPidsBefore",
    ],
    "P-26 restoration",
  );
  if (
    typeof value.restoration.daemonWasActive !== "boolean" ||
    value.restoration.daemonActiveAfter !== value.restoration.daemonWasActive ||
    !Array.isArray(value.restoration.desktopPidsBefore) ||
    !Array.isArray(value.restoration.desktopPidsAfter) ||
    value.restoration.desktopPidsBefore.length !== 0 ||
    value.restoration.desktopPidsAfter.length !== 0 ||
    marker.safety.daemonServiceRestored !== true ||
    marker.safety.desktopProcessesRestored !== true
  )
    fail("P-26 did not restore the pre-capture process/service state");
  return { actionCount: value.actions.length, routeCount: value.routes.length };
}

export function validateP26InstalledSession(
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
      "requirementId",
      "schemaVersion",
      "targetHead",
    ],
    "P-26 installed session",
  );
  if (
    document.schemaVersion !== 1 ||
    document.id !== "openburnbar-linux-p26-installed-tray-session-v1"
  )
    fail("P-26 installed session identity is invalid");
  const envelope = validateInstalledSessionEnvelope(
    document,
    { ...binding, repoRoot },
    P26_REQUIREMENT_ID,
    "P-26 installed session",
  );
  validateMarker(document.marker, document.environmentId);
  exactKeys(
    document.evidence,
    ["nativeTranscript", ...SCREENSHOTS, ...ATSPI],
    "P-26 evidence",
  );
  const native = artifact(
    repoRoot,
    document.environmentId,
    document.evidence.nativeTranscript,
    "P-26 native transcript",
    { mediaType: "json", minimumBytes: 1500 },
  );
  const summary = validateNative(
    parseJson(native.bytes, "P-26 native transcript"),
    document.marker,
    binding.manifestSha256,
    binding.packageVersion,
    envelope.startedAt,
    envelope.endedAt,
  );
  const hashes = new Set();
  for (const field of SCREENSHOTS) {
    const record = artifact(
      repoRoot,
      document.environmentId,
      document.evidence[field],
      `P-26 ${field}`,
      { mediaType: "png", minimumBytes: 1024 },
    );
    const png = validatePng(record.bytes, `P-26 ${field}`);
    if (png.nonBlankPixelRatio < 0.05) fail(`P-26 ${field} is blank`);
    hashes.add(crypto.createHash("sha256").update(png.pixels).digest("hex"));
  }
  if (hashes.size !== SCREENSHOTS.length)
    fail("P-26 screenshots replay a prior native-shell state");
  for (const [index, field] of ATSPI.entries()) {
    const snapshot = artifact(
      repoRoot,
      document.environmentId,
      document.evidence[field],
      `P-26 ${field}`,
      { mediaType: "json", minimumBytes: 100 },
    );
    const tree = parseJson(snapshot.bytes, `P-26 ${field}`);
    const [route, , expected] = ROUTES[index];
    if (
      JSON.stringify(tree).includes("fixture") ||
      tree.application !== "OpenBurnBar" ||
      tree.route !== route ||
      tree.expectedName !== expected ||
      tree.expectedNamePresent !== true ||
      tree.pass !== true ||
      !Array.isArray(tree.namedSamples) ||
      !tree.namedSamples.some(
        (node) => node?.role === "heading" && node?.name === expected,
      )
    )
      fail(
        `P-26 ${field} does not expose active ${expected} route through AT-SPI`,
      );
  }
  const evidence = [
    ...envelope.attestation,
    ...Object.values(document.evidence),
  ];
  if (new Set(evidence.map((record) => record.path)).size !== evidence.length)
    fail("P-26 reuses an evidence artifact");
  return { document, evidence, endedAt: envelope.endedAt, ...summary };
}

export function buildP26Proof({
  session,
  source,
  collectedAt,
  actionCount,
  routeCount,
}) {
  return {
    schemaVersion: 1,
    id: "openburnbar-linux-p26-tray-proof-v1",
    requirementId: P26_REQUIREMENT_ID,
    environmentId: session.environmentId,
    targetHead: session.targetHead,
    candidate: session.candidate,
    collectedAt,
    source: { method: "live-installed-tray-session", ...source },
    claim: {
      passed: true,
      actionCount,
      routeCount,
      backgroundPersistence: true,
      nativeStatusMenu: true,
      refreshReconnectQuit: true,
      accessibleRoutes: true,
      serviceRestoration: true,
    },
  };
}

export function validateP26Proof({ repoRoot, snapshot, ...binding }) {
  const proof = parseJson(snapshot.bytes, "P-26 proof");
  exactKeys(
    proof,
    [
      "candidate",
      "claim",
      "collectedAt",
      "environmentId",
      "id",
      "requirementId",
      "schemaVersion",
      "source",
      "targetHead",
    ],
    "P-26 proof",
  );
  if (
    proof.schemaVersion !== 1 ||
    proof.id !== "openburnbar-linux-p26-tray-proof-v1" ||
    proof.requirementId !== P26_REQUIREMENT_ID ||
    proof.environmentId !== binding.environmentId ||
    proof.targetHead !== binding.targetHead ||
    proof.candidate.runId !== String(binding.candidateRunId) ||
    proof.candidate.artifactDigest !== binding.candidateArtifactDigest
  )
    fail("P-26 proof binding is invalid");
  exactKeys(
    proof.candidate,
    ["artifactDigest", "runId"],
    "P-26 proof candidate",
  );
  exactKeys(
    proof.source,
    ["method", "path", "sha256", "size"],
    "P-26 proof source",
  );
  if (proof.source.method !== "live-installed-tray-session")
    fail("P-26 proof source is not live");
  const sourceRecord = {
    path: proof.source.path,
    sha256: proof.source.sha256,
    size: proof.source.size,
  };
  const source = artifact(
    repoRoot,
    binding.environmentId,
    sourceRecord,
    "P-26 source session",
    { mediaType: "json", minimumBytes: 500 },
  );
  const validated = validateP26InstalledSession(
    parseJson(source.bytes, "P-26 source session"),
    { ...binding, repoRoot },
    { repoRoot },
  );
  validateCollectedAt(proof.collectedAt, validated.endedAt);
  exactKeys(
    proof.claim,
    [
      "accessibleRoutes",
      "actionCount",
      "backgroundPersistence",
      "nativeStatusMenu",
      "passed",
      "refreshReconnectQuit",
      "routeCount",
      "serviceRestoration",
    ],
    "P-26 claim",
  );
  if (
    proof.claim.passed !== true ||
    proof.claim.actionCount !== validated.actionCount ||
    proof.claim.routeCount !== validated.routeCount ||
    [
      "accessibleRoutes",
      "backgroundPersistence",
      "nativeStatusMenu",
      "refreshReconnectQuit",
      "serviceRestoration",
    ].some((field) => proof.claim[field] !== true)
  )
    fail("P-26 proof claim is not derived from its installed session");
  return { proof, source: sourceRecord, evidence: validated.evidence };
}
