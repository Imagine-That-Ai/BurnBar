import crypto from "node:crypto";
import {
  exactKeys,
  parseJson,
  validateArtifact,
  validateCollectedAt,
  validateInstalledSessionEnvelope,
  validatePng,
} from "./installed-ui-proof.mjs";

export const P30_REQUIREMENT_ID = "P-30";
export const P30_PROOF_ROLE = "feature.pet-companion-installed";
export const P30_PROOF_FILENAME = "p30-installed-pet-proof.json";
export const P30_SESSION_FILENAME = "p30-installed-pet-session.json";

const MARKER = /^p30-[a-f0-9]{16}$/u;
const SHA256 = /^[a-f0-9]{64}$/u;
const SCREENSHOTS = [
  "initialScreenshot",
  "selectedScreenshot",
  "movedScreenshot",
  "relaunchScreenshot",
];
const ACCESSIBILITY = [
  "initialAccessibility",
  "selectedAccessibility",
  "movedAccessibility",
  "relaunchAccessibility",
];

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
    P30_REQUIREMENT_ID,
    environmentId,
    label,
    options,
  );
}

function validateMarker(value, expected) {
  exactKeys(
    value,
    ["installed", "marker", "runtimeManifest", "safety"],
    "P-30 marker",
  );
  if (!MARKER.test(value.marker ?? "")) fail("P-30 marker identity is invalid");
  exactKeys(
    value.installed,
    ["daemon", "desktop", "packageManager", "packageName", "packageOwned"],
    "P-30 installed identity",
  );
  if (
    value.installed.daemon !== "/usr/bin/openburnbar-daemon" ||
    value.installed.desktop !== "/usr/bin/openburnbar-linux-desktop" ||
    value.installed.packageName !== "openburnbar" ||
    value.installed.packageOwned !== true ||
    !["dpkg", "rpm", "pacman"].includes(value.installed.packageManager) ||
    value.installed.packageManager !==
      { deb: "dpkg", rpm: "rpm", arch: "pacman" }[expected.format]
  ) {
    fail("P-30 did not use canonical package-owned executables");
  }
  exactKeys(
    value.runtimeManifest,
    ["capturedFrom", "petOverlayState", "sha256"],
    "P-30 runtime manifest marker",
  );
  if (
    value.runtimeManifest.capturedFrom !==
      "/usr/bin/openburnbar-linux-desktop --runtime-capabilities" ||
    !["available", "degraded", "unavailable"].includes(
      value.runtimeManifest.petOverlayState,
    ) ||
    !SHA256.test(value.runtimeManifest.sha256 ?? "")
  )
    fail("P-30 runtime manifest marker is invalid");
  exactKeys(
    value.safety,
    [
      "daemonRestored",
      "desktopProcessesRestored",
      "fixtureMode",
      "isolatedHome",
      "preexistingDesktopProcesses",
    ],
    "P-30 safety",
  );
  if (
    value.safety.fixtureMode !== false ||
    value.safety.isolatedHome !== true ||
    value.safety.daemonRestored !== true ||
    value.safety.desktopProcessesRestored !== true ||
    !Array.isArray(value.safety.preexistingDesktopProcesses) ||
    value.safety.preexistingDesktopProcesses.length !== 0
  )
    fail("P-30 process/state restoration is incomplete");
  if (
    expected.session === "Wayland" &&
    value.runtimeManifest.petOverlayState === "available"
  ) {
    fail(
      "P-30 Wayland runtime manifest optimistically claims overlay availability",
    );
  }
}

function validateAccessibility(
  value,
  label,
  expectedStatus,
  x11,
  startedAt,
  endedAt,
) {
  const document = parseJson(value.bytes, label);
  exactKeys(
    document,
    [
      "application",
      "ariaKeyshortcuts",
      "capturedAt",
      "focusedName",
      "namedNodes",
      "producer",
      "statusText",
    ],
    label,
  );
  if (
    document.application !== "OpenBurnBar" ||
    document.producer !== "openburnbar-p30-atspi-live-v1" ||
    typeof document.focusedName !== "string" ||
    !/pet companion contained preview/iu.test(document.focusedName) ||
    !Array.isArray(document.namedNodes) ||
    document.namedNodes.length < 6 ||
    document.ariaKeyshortcuts !==
      (x11 ? "Ctrl+Alt+Super+P" : "unavailable-on-contained-fallback") ||
    typeof document.statusText !== "string" ||
    !document.statusText.includes(expectedStatus)
  ) {
    fail(
      `${label} does not prove focus, status, semantics, and aria-keyshortcuts`,
    );
  }
  const capturedAt = timestamp(document.capturedAt, `${label} capture`);
  if (capturedAt < startedAt || capturedAt > endedAt)
    fail(`${label} is outside the live session`);
  return document;
}

function validateTranscript(
  value,
  marker,
  expected,
  manifestSha256,
  startedAt,
  endedAt,
) {
  exactKeys(
    value,
    [
      "accessibility",
      "compositor",
      "endedAt",
      "interactions",
      "marker",
      "producer",
      "relaunch",
      "restoration",
      "runtime",
      "startedAt",
    ],
    "P-30 native transcript",
  );
  const start = timestamp(value.startedAt, "P-30 transcript start");
  const end = timestamp(value.endedAt, "P-30 transcript end");
  if (
    start < startedAt ||
    end > endedAt ||
    end <= start ||
    value.marker !== marker.marker ||
    value.producer !== "openburnbar-p30-installed-pet-probe-v1"
  )
    fail("P-30 transcript is not bound to the live session");
  exactKeys(
    value.runtime,
    ["manifestSha256", "petOverlayState", "source"],
    "P-30 runtime transcript",
  );
  if (
    value.runtime.manifestSha256 !== manifestSha256 ||
    value.runtime.manifestSha256 !== marker.runtimeManifest.sha256 ||
    value.runtime.petOverlayState !== marker.runtimeManifest.petOverlayState ||
    value.runtime.source !== "installed-runtime-command"
  ) {
    fail("P-30 runtime transcript is substituted or stale");
  }
  exactKeys(
    value.compositor,
    ["desktop", "displayServer", "mode", "nativeWindowContract"],
    "P-30 compositor transcript",
  );
  if (
    value.compositor.desktop !== expected.desktop ||
    value.compositor.displayServer !== expected.session
  )
    fail("P-30 compositor transcript does not match the environment");
  const x11 = expected.session === "X11";
  if (
    x11
      ? value.compositor.mode !== "x11-native-overlay" ||
        value.compositor.nativeWindowContract !== "tauri-x11-companion-v1"
      : value.compositor.mode !== "wayland-contained-fallback" ||
        value.compositor.nativeWindowContract !== "none"
  ) {
    fail("P-30 compositor-specific mode is dishonest");
  }
  exactKeys(
    value.interactions,
    [
      "clickThrough",
      "keyboardReposition",
      "pointerReposition",
      "selection",
      "summon",
    ],
    "P-30 interactions",
  );
  const selection = value.interactions.selection;
  exactKeys(
    selection,
    ["cleared", "selected", "statusAfterClear", "statusAfterSelect"],
    "P-30 selection",
  );
  if (
    selection.selected !== true ||
    selection.cleared !== true ||
    !/selected/iu.test(selection.statusAfterSelect ?? "") ||
    !/cleared/iu.test(selection.statusAfterClear ?? "")
  )
    fail("P-30 selection/clear was not observed");
  const keyboard = value.interactions.keyboardReposition;
  exactKeys(
    keyboard,
    ["after", "before", "focused", "reset", "status"],
    "P-30 keyboard reposition",
  );
  if (
    keyboard.focused !== true ||
    keyboard.before !== "0,0" ||
    keyboard.after === keyboard.before ||
    keyboard.reset !== "0,0" ||
    !/keyboard/iu.test(keyboard.status ?? "")
  )
    fail("P-30 keyboard reposition/reset was not observed");
  const pointer = value.interactions.pointerReposition;
  exactKeys(pointer, ["after", "before", "status"], "P-30 pointer reposition");
  if (
    pointer.before === pointer.after ||
    !/pointer/iu.test(pointer.status ?? "")
  )
    fail("P-30 pointer reposition was not observed");
  exactKeys(
    value.interactions.summon,
    ["ariaKeyshortcuts", "globalShortcut", "mode", "routeFocused", "shortcut"],
    "P-30 summon",
  );
  if (
    value.interactions.summon.shortcut !== "Ctrl+Alt+Super+P" ||
    value.interactions.summon.ariaKeyshortcuts !==
      (x11 ? "Ctrl+Alt+Super+P" : "unavailable-on-contained-fallback") ||
    value.interactions.summon.routeFocused !== true ||
    (x11
      ? value.interactions.summon.globalShortcut !== true ||
        value.interactions.summon.mode !== "native-global"
      : value.interactions.summon.globalShortcut !== false ||
        value.interactions.summon.mode !== "focused-contained-fallback")
  )
    fail("P-30 summon contract is invalid");
  exactKeys(
    value.interactions.clickThrough,
    ["enabled", "nativeWindowObserved", "restored", "supported"],
    "P-30 click-through",
  );
  if (
    x11
      ? value.interactions.clickThrough.supported !== true ||
        value.interactions.clickThrough.enabled !== true ||
        value.interactions.clickThrough.restored !== true ||
        value.interactions.clickThrough.nativeWindowObserved !== true
      : value.interactions.clickThrough.supported !== false ||
        value.interactions.clickThrough.enabled !== false ||
        value.interactions.clickThrough.nativeWindowObserved !== false
  )
    fail("P-30 click-through proof contradicts the compositor");
  exactKeys(
    value.accessibility,
    ["focusObserved", "liveStatusObserved", "shortcutMetadataObserved"],
    "P-30 accessibility transcript",
  );
  if (!Object.values(value.accessibility).every((item) => item === true))
    fail("P-30 accessibility behavior was not observed");
  exactKeys(
    value.relaunch,
    [
      "fallbackAvailable",
      "nativeTierSame",
      "newPid",
      "oldPid",
      "staleInteractionCleared",
    ],
    "P-30 relaunch",
  );
  if (
    !Number.isSafeInteger(value.relaunch.oldPid) ||
    !Number.isSafeInteger(value.relaunch.newPid) ||
    value.relaunch.oldPid === value.relaunch.newPid ||
    value.relaunch.fallbackAvailable !== true ||
    value.relaunch.nativeTierSame !== true ||
    value.relaunch.staleInteractionCleared !== true
  )
    fail("P-30 relaunch behavior is incomplete");
  exactKeys(
    value.restoration,
    [
      "daemonActiveAfter",
      "daemonWasActive",
      "desktopPidsAfter",
      "desktopPidsBefore",
    ],
    "P-30 restoration",
  );
  if (
    value.restoration.daemonActiveAfter !== value.restoration.daemonWasActive ||
    JSON.stringify(value.restoration.desktopPidsAfter) !==
      JSON.stringify(value.restoration.desktopPidsBefore)
  )
    fail("P-30 did not restore the exact daemon/desktop state");
  return { x11 };
}

export function validateP30InstalledSession(
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
    "P-30 installed session",
  );
  if (
    document.schemaVersion !== 1 ||
    document.id !== "openburnbar-linux-p30-installed-pet-session-v1"
  )
    fail("P-30 session identity is invalid");
  const envelope = validateInstalledSessionEnvelope(
    document,
    binding,
    P30_REQUIREMENT_ID,
    "P-30 installed session",
  );
  validateMarker(document.marker, envelope.expected);
  exactKeys(
    document.evidence,
    [
      "initialAccessibility",
      "initialScreenshot",
      "movedAccessibility",
      "movedScreenshot",
      "nativeTranscript",
      "relaunchAccessibility",
      "relaunchScreenshot",
      "runtimeManifest",
      "selectedAccessibility",
      "selectedScreenshot",
    ],
    "P-30 evidence",
  );
  const runtime = artifact(
    repoRoot,
    binding.environmentId,
    document.evidence.runtimeManifest,
    "P-30 live runtime manifest",
    { mediaType: "json" },
  );
  if (runtime.sha256 !== document.marker.runtimeManifest.sha256)
    fail("P-30 runtime manifest digest changed");
  const manifest = parseJson(runtime.bytes, "P-30 live runtime manifest");
  const expectedDesktop = envelope.expected.desktop.startsWith("KDE")
    ? "kde"
    : envelope.expected.desktop.toLowerCase().split("/")[0];
  if (
    String(manifest.sessionType ?? "").toLowerCase() !==
      envelope.expected.session.toLowerCase() ||
    !String(manifest.desktop ?? "")
      .toLowerCase()
      .includes(expectedDesktop)
  )
    fail(
      "P-30 runtime manifest desktop/session does not match the environment",
    );
  const entry = manifest.capabilities?.find?.(
    (item) => item.id === "pet.overlay",
  );
  if (!entry || entry.state !== document.marker.runtimeManifest.petOverlayState)
    fail("P-30 runtime manifest omits or changes pet.overlay");
  const native = artifact(
    repoRoot,
    binding.environmentId,
    document.evidence.nativeTranscript,
    "P-30 native transcript",
    { mediaType: "json" },
  );
  const transcript = parseJson(native.bytes, "P-30 native transcript");
  const tier = validateTranscript(
    transcript,
    document.marker,
    envelope.expected,
    runtime.sha256,
    envelope.startedAt,
    envelope.endedAt,
  );
  const screenshotHashes = new Set();
  const accessibilityHashes = new Set();
  const expectedStatuses = ["summoned", "selected", "moved", "summoned"];
  for (const [index, key] of SCREENSHOTS.entries()) {
    const snapshot = artifact(
      repoRoot,
      binding.environmentId,
      document.evidence[key],
      `P-30 ${key}`,
      { mediaType: "png", minimumBytes: 256 },
    );
    const image = validatePng(snapshot.bytes, `P-30 ${key}`);
    if (
      image.nonBlankPixelRatio < 0.05 ||
      screenshotHashes.has(snapshot.sha256)
    )
      fail("P-30 screenshots are blank or replayed");
    screenshotHashes.add(snapshot.sha256);
    const a11y = artifact(
      repoRoot,
      binding.environmentId,
      document.evidence[ACCESSIBILITY[index]],
      `P-30 ${ACCESSIBILITY[index]}`,
      { mediaType: "json" },
    );
    if (accessibilityHashes.has(a11y.sha256))
      fail("P-30 AT-SPI snapshots are replayed");
    accessibilityHashes.add(a11y.sha256);
    validateAccessibility(
      a11y,
      `P-30 ${ACCESSIBILITY[index]}`,
      expectedStatuses[index],
      tier.x11,
      envelope.startedAt,
      envelope.endedAt,
    );
  }
  const evidence = [
    ...Object.values(document.evidence),
    ...envelope.attestation,
  ];
  if (new Set(evidence.map((record) => record.path)).size !== evidence.length)
    fail("P-30 reuses an evidence artifact");
  return {
    document,
    transcript,
    nativeSha256: native.sha256,
    runtimeSha256: runtime.sha256,
    tier,
    evidence,
  };
}

export function buildP30Proof({ session, source, collectedAt, validated }) {
  return {
    schemaVersion: 1,
    id: "openburnbar-linux-p30-pet-proof-v1",
    requirementId: P30_REQUIREMENT_ID,
    environmentId: session.environmentId,
    targetHead: session.targetHead,
    candidate: session.candidate,
    collectedAt,
    source,
    claim: {
      installedCandidate: true,
      runtimeManifestBound: true,
      compositorMode: validated.transcript.compositor.mode,
      nativeOverlayProven: validated.tier.x11,
      containedFallbackProven: !validated.tier.x11,
      selectionAndClear: true,
      pointerAndKeyboardReposition: true,
      accessibleFocusStatusShortcut: true,
      relaunchAndRestoration: true,
    },
  };
}

export function validateP30Proof({ snapshot, ...binding }) {
  const proof = parseJson(snapshot.bytes, "P-30 proof");
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
    "P-30 proof",
  );
  if (
    proof.schemaVersion !== 1 ||
    proof.id !== "openburnbar-linux-p30-pet-proof-v1" ||
    proof.requirementId !== P30_REQUIREMENT_ID ||
    proof.environmentId !== binding.environmentId ||
    proof.targetHead !== binding.targetHead
  )
    fail("P-30 proof identity is invalid");
  exactKeys(
    proof.candidate,
    ["artifactDigest", "runId"],
    "P-30 proof candidate",
  );
  if (
    proof.candidate.runId !== String(binding.candidateRunId) ||
    proof.candidate.artifactDigest !== binding.candidateArtifactDigest
  )
    fail("P-30 proof candidate binding is invalid");
  const source = artifact(
    binding.repoRoot,
    binding.environmentId,
    proof.source,
    "P-30 proof source",
    { mediaType: "json" },
  );
  const validated = validateP30InstalledSession(
    parseJson(source.bytes, "P-30 proof source"),
    binding,
  );
  validateCollectedAt(
    proof.collectedAt,
    Date.parse(validated.document.capture.endedAt),
  );
  const expectedClaim = buildP30Proof({
    session: validated.document,
    source: proof.source,
    collectedAt: proof.collectedAt,
    validated,
  }).claim;
  if (
    crypto
      .createHash("sha256")
      .update(JSON.stringify(proof.claim))
      .digest("hex") !==
    crypto
      .createHash("sha256")
      .update(JSON.stringify(expectedClaim))
      .digest("hex")
  )
    fail("P-30 proof claim is forged");
  return {
    proof,
    validated,
    source: proof.source,
    evidence: validated.evidence,
  };
}
