import crypto from "node:crypto";
import {
  exactKeys,
  parseJson,
  validateArtifact,
  validateCollectedAt,
  validateInstalledSessionEnvelope,
  validatePng,
} from "./installed-ui-proof.mjs";
export const P36_REQUIREMENT_ID = "P-36";
export const P36_PROOF_ROLE = "feature.visual-interaction-polish-installed";
export const P36_PROOF_FILENAME = "p36-installed-visual-polish-proof.json";
export const P36_SESSION_FILENAME = "p36-installed-visual-polish-session.json";
export const P36_RAW_FILES = Object.freeze([
  "visual-marker.json",
  "visual-native-transcript.json",
  "visual-compact-light.png",
  "visual-standard-dark.png",
  "visual-wide-dark.png",
  "visual-reduced-motion.png",
  "visual-overflow-menu.png",
  "visual-compact-atspi.json",
  "visual-standard-atspi.json",
  "visual-wide-atspi.json",
  "visual-reduced-atspi.json",
  "visual-overflow-atspi.json",
]);
const MARKER = /^p36-[a-f0-9]{16}$/u;
const NONCE = /^[a-f0-9]{32}$/u;
const SCREENSHOTS = [
  "compactLightScreenshot",
  "standardDarkScreenshot",
  "wideDarkScreenshot",
  "reducedMotionScreenshot",
  "overflowMenuScreenshot",
];
const ACCESSIBILITY = [
  "compactAccessibility",
  "standardAccessibility",
  "wideAccessibility",
  "reducedAccessibility",
  "overflowAccessibility",
];
function fail(message) {
  throw new Error(message);
}
function instant(value, label) {
  const parsed = Date.parse(value);
  if (!Number.isFinite(parsed)) fail(`${label} timestamp is invalid`);
  return parsed;
}
function artifact(root, environmentId, record, label, options = {}) {
  return validateArtifact(
    root,
    record,
    P36_REQUIREMENT_ID,
    environmentId,
    label,
    options,
  );
}
function expectedChallenge(value, binding) {
  return crypto
    .createHash("sha256")
    .update(
      [
        binding.targetHead,
        String(binding.candidateRunId),
        binding.candidateArtifactDigest,
        value.marker,
        value.nonce,
      ].join("\n"),
    )
    .digest("hex");
}
function validateMarker(value, expected, binding) {
  exactKeys(
    value,
    ["challenge", "installed", "marker", "nonce", "package", "producer"],
    "P-36 marker",
  );
  if (
    !MARKER.test(value.marker ?? "") ||
    !NONCE.test(value.nonce ?? "") ||
    value.producer !== "openburnbar-p36-installed-visual-polish-probe-v1" ||
    value.challenge !== expectedChallenge(value, binding)
  )
    fail("P-36 marker is forged, stale, or replayed");
  exactKeys(
    value.installed,
    ["daemon", "desktop", "packageManager", "packageName", "packageOwned"],
    "P-36 installed identity",
  );
  const manager = { deb: "dpkg", rpm: "rpm", arch: "pacman" }[expected.format];
  const name = expected.format === "arch" ? "openburnbar" : "open-burn-bar";
  if (
    value.installed.desktop !== "/usr/bin/openburnbar-linux-desktop" ||
    value.installed.daemon !== "/usr/bin/openburnbar-daemon" ||
    value.installed.packageManager !== manager ||
    value.installed.packageName !== name ||
    value.installed.packageOwned !== true
  )
    fail("P-36 did not use canonical package-owned executables");
  exactKeys(
    value.package,
    ["architecture", "format", "manifestSha256", "version"],
    "P-36 package identity",
  );
  if (
    value.package.architecture !== expected.architecture ||
    value.package.format !== expected.format ||
    value.package.version !== binding.packageVersion ||
    value.package.manifestSha256 !== binding.manifestSha256
  )
    fail("P-36 package identity is not closure-bound");
}
function validateLayout(value, label, width, height, density) {
  exactKeys(
    value,
    [
      "clippedCount",
      "density",
      "documentScrollWidth",
      "horizontalOverflow",
      "interactiveCount",
      "minControlHeight",
      "overlappingControls",
      "viewportHeight",
      "viewportWidth",
    ],
    label,
  );
  if (
    ![
      value.viewportWidth,
      value.viewportHeight,
      value.horizontalOverflow,
      value.documentScrollWidth,
      value.clippedCount,
      value.overlappingControls,
      value.interactiveCount,
      value.minControlHeight,
    ].every(Number.isSafeInteger) ||
    value.viewportWidth !== width ||
    value.viewportHeight !== height ||
    value.density !== density ||
    value.horizontalOverflow !== 0 ||
    value.clippedCount !== 0 ||
    value.overlappingControls !== 0 ||
    value.documentScrollWidth > width ||
    value.interactiveCount < 8 ||
    value.minControlHeight < 28
  )
    fail(`${label} clips, overlaps, overflows, or lacks usable native density`);
}
function validateA11y(snapshot, label, expected, startedAt, endedAt) {
  const value = parseJson(snapshot.bytes, label);
  exactKeys(
    value,
    [
      "actionableNodeCount",
      "actionableSamples",
      "application",
      "capturedAt",
      "expectedName",
      "expectedNamePresent",
      "failures",
      "focusableNodeCount",
      "focusedNodes",
      "minimums",
      "menuOpen",
      "namedNodeCount",
      "namedSamples",
      "nodeCount",
      "pass",
      "producer",
      "proofState",
      "readinessAttempts",
      "reducedMotion",
      "roleCounts",
      "route",
      "schemaVersion",
      "truncated",
      "theme",
      "viewport",
    ],
    label,
  );
  if (
    value.schemaVersion !== 1 ||
    value.producer !== "openburnbar-p36-atspi-live-v1" ||
    value.application !== "OpenBurnBar" ||
    value.route !== "overview" ||
    value.pass !== true ||
    value.expectedNamePresent !== true ||
    value.expectedName !== expected.name ||
    value.proofState !== expected.state ||
    value.theme !== expected.theme ||
    value.reducedMotion !== expected.reducedMotion ||
    value.menuOpen !== expected.menuOpen ||
    !Number.isSafeInteger(value.nodeCount) ||
    !Number.isSafeInteger(value.namedNodeCount) ||
    !Number.isSafeInteger(value.actionableNodeCount) ||
    value.nodeCount < 12 ||
    value.namedNodeCount < 6 ||
    value.actionableNodeCount < 3
  )
    fail(`${label} is not live Overview AT-SPI evidence`);
  exactKeys(value.viewport, ["height", "width"], `${label} viewport`);
  if (
    value.viewport.width !== expected.width ||
    value.viewport.height !== expected.height
  )
    fail(`${label} is not bound to its measured viewport`);
  const captured = instant(value.capturedAt, `${label} capture`);
  if (captured < startedAt || captured > endedAt)
    fail(`${label} is outside the live session`);
}
function validateTranscript(value, marker, expected, envelope, binding) {
  exactKeys(
    value,
    [
      "challenge",
      "endedAt",
      "interaction",
      "layouts",
      "marker",
      "motion",
      "packageFacts",
      "producer",
      "restart",
      "restoration",
      "startedAt",
      "themes",
    ],
    "P-36 native transcript",
  );
  const startedAt = instant(value.startedAt, "P-36 start");
  const endedAt = instant(value.endedAt, "P-36 end");
  if (
    value.producer !== marker.producer ||
    value.marker !== marker.marker ||
    value.challenge !== marker.challenge ||
    startedAt < envelope.startedAt ||
    endedAt > envelope.endedAt ||
    endedAt <= startedAt ||
    endedAt - startedAt > 300_000
  )
    fail("P-36 transcript is stale or replayed");
  exactKeys(
    value.packageFacts,
    [
      "architecture",
      "channel",
      "compositor",
      "desktop",
      "displayServer",
      "manager",
      "os",
      "packageVersion",
      "sessionType",
      "shellVersion",
    ],
    "P-36 package/runtime facts",
  );
  if (
    value.packageFacts.architecture !== expected.architecture ||
    value.packageFacts.channel !== expected.format ||
    value.packageFacts.manager !==
      { deb: "dpkg", rpm: "rpm", arch: "pacman" }[expected.format] ||
    value.packageFacts.packageVersion !== binding.packageVersion ||
    value.packageFacts.shellVersion !== binding.packageVersion ||
    value.packageFacts.os !== "linux" ||
    value.packageFacts.sessionType !== expected.session.toLowerCase() ||
    value.packageFacts.displayServer !== expected.session ||
    value.packageFacts.desktop !== expected.desktop ||
    value.packageFacts.compositor !==
      (expected.desktop === "GNOME"
        ? "Mutter"
        : expected.desktop === "KDE Plasma"
          ? "KWin"
          : "Sway/wlroots")
  )
    fail("P-36 package/runtime facts are inaccurate");
  exactKeys(value.layouts, ["compact", "standard", "wide"], "P-36 layouts");
  validateLayout(
    value.layouts.compact,
    "P-36 compact layout",
    720,
    900,
    "compact",
  );
  validateLayout(
    value.layouts.standard,
    "P-36 standard layout",
    1180,
    820,
    "standard",
  );
  validateLayout(value.layouts.wide, "P-36 wide layout", 1600, 900, "wide");
  exactKeys(value.themes, ["dark", "light"], "P-36 themes");
  for (const mode of ["light", "dark"]) {
    const theme = value.themes[mode];
    exactKeys(
      theme,
      [
        "appearance",
        "contrastRatio",
        "nativeControlCount",
        "nativeControlScheme",
        "persisted",
      ],
      `P-36 ${mode} theme`,
    );
    if (
      theme.appearance !== mode ||
      !Number.isFinite(theme.contrastRatio) ||
      theme.contrastRatio < 4.5 ||
      !Number.isSafeInteger(theme.nativeControlCount) ||
      theme.nativeControlCount < 1 ||
      theme.nativeControlScheme !== mode ||
      theme.persisted !== true
    )
      fail(`P-36 ${mode} theme lacks native-control contrast or persistence`);
  }
  exactKeys(
    value.motion,
    [
      "animatedElements",
      "mediaQuery",
      "preferenceRestored",
      "reduced",
      "transitioningElements",
    ],
    "P-36 motion",
  );
  if (
    value.motion.mediaQuery !== "(prefers-reduced-motion: reduce)" ||
    value.motion.reduced !== true ||
    !Number.isSafeInteger(value.motion.animatedElements) ||
    value.motion.animatedElements !== 0 ||
    !Number.isSafeInteger(value.motion.transitioningElements) ||
    value.motion.transitioningElements !== 0 ||
    value.motion.preferenceRestored !== true
  )
    fail("P-36 reduced-motion behavior is absent or unrestored");
  exactKeys(
    value.interaction,
    [
      "arrowNavigation",
      "distinctFocusTargets",
      "escapeRestoredFocus",
      "focusVisible",
      "keyboardOnly",
      "overflowOpened",
    ],
    "P-36 interaction",
  );
  if (
    value.interaction.keyboardOnly !== true ||
    !Number.isSafeInteger(value.interaction.distinctFocusTargets) ||
    value.interaction.distinctFocusTargets < 3 ||
    value.interaction.focusVisible !== true ||
    value.interaction.overflowOpened !== true ||
    value.interaction.arrowNavigation !== true ||
    value.interaction.escapeRestoredFocus !== true
  )
    fail("P-36 keyboard/focus/overflow interaction is incomplete");
  exactKeys(
    value.restart,
    ["appearancePersisted", "layoutStable", "relaunchCount"],
    "P-36 restart",
  );
  if (
    value.restart.appearancePersisted !== true ||
    value.restart.layoutStable !== true ||
    !Number.isSafeInteger(value.restart.relaunchCount) ||
    value.restart.relaunchCount !== 1
  )
    fail("P-36 visual state did not survive one installed restart");
  exactKeys(
    value.restoration,
    [
      "daemonActiveAfter",
      "daemonActiveBefore",
      "desktopPidsAfter",
      "desktopPidsBefore",
      "isolatedStateRestored",
      "motionPreferenceAfter",
      "motionPreferenceBefore",
    ],
    "P-36 restoration",
  );
  if (
    typeof value.restoration.daemonActiveBefore !== "boolean" ||
    typeof value.restoration.daemonActiveAfter !== "boolean" ||
    !Array.isArray(value.restoration.desktopPidsBefore) ||
    !value.restoration.desktopPidsBefore.every(Number.isSafeInteger) ||
    !Array.isArray(value.restoration.desktopPidsAfter) ||
    !value.restoration.desktopPidsAfter.every(Number.isSafeInteger) ||
    typeof value.restoration.motionPreferenceBefore !== "boolean" ||
    typeof value.restoration.motionPreferenceAfter !== "boolean" ||
    value.restoration.daemonActiveAfter !==
      value.restoration.daemonActiveBefore ||
    JSON.stringify(value.restoration.desktopPidsAfter) !==
      JSON.stringify(value.restoration.desktopPidsBefore) ||
    value.restoration.isolatedStateRestored !== true ||
    value.restoration.motionPreferenceAfter !==
      value.restoration.motionPreferenceBefore
  )
    fail(
      "P-36 service, process, home, or preference restoration is incomplete",
    );
  return { startedAt, endedAt };
}
export function validateP36InstalledSession(
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
    "P-36 installed session",
  );
  if (
    document.schemaVersion !== 1 ||
    document.id !== "openburnbar-linux-p36-installed-visual-polish-session-v1"
  )
    fail("P-36 session identity is invalid");
  const envelope = validateInstalledSessionEnvelope(
    document,
    { ...binding, repoRoot },
    P36_REQUIREMENT_ID,
    "P-36 installed session",
  );
  const compositorPattern = document.environmentId.startsWith("ubuntu-")
    ? /^mutter$/iu
    : document.environmentId.startsWith("fedora-kde-")
      ? /^kwin(?:_wayland)?$/iu
      : /^sway(?:\/wlroots)?$/iu;
  if (!compositorPattern.test(document.desktop.compositor))
    fail("P-36 compositor does not match its support environment");
  validateMarker(document.marker, envelope.expected, binding);
  exactKeys(
    document.evidence,
    ["nativeTranscript", ...SCREENSHOTS, ...ACCESSIBILITY],
    "P-36 evidence",
  );
  const native = artifact(
    repoRoot,
    document.environmentId,
    document.evidence.nativeTranscript,
    "P-36 native transcript",
    { mediaType: "json", minimumBytes: 1400 },
  );
  const timing = validateTranscript(
    parseJson(native.bytes, "P-36 native transcript"),
    document.marker,
    envelope.expected,
    envelope,
    binding,
  );
  const hashes = new Set();
  const screenshotDimensions = [
    [720, 900],
    [1180, 820],
    [1600, 900],
    [1600, 900],
    [1600, 900],
  ];
  for (const [index, field] of SCREENSHOTS.entries()) {
    const row = artifact(
      repoRoot,
      document.environmentId,
      document.evidence[field],
      `P-36 ${field}`,
      { mediaType: "png", minimumBytes: 1024 },
    );
    const png = validatePng(row.bytes, `P-36 ${field}`);
    if (
      png.width !== screenshotDimensions[index][0] ||
      png.height !== screenshotDimensions[index][1] ||
      png.nonBlankPixelRatio < 0.05
    )
      fail(`P-36 ${field} has the wrong viewport dimensions or is blank`);
    hashes.add(crypto.createHash("sha256").update(png.pixels).digest("hex"));
  }
  if (hashes.size !== SCREENSHOTS.length)
    fail("P-36 screenshots are blank or reused");
  const accessibilityExpectations = [
    { state: "compact", name: "More actions", width: 720, height: 900, theme: "light", reducedMotion: false, menuOpen: false },
    { state: "standard", name: "More actions", width: 1180, height: 820, theme: "dark", reducedMotion: false, menuOpen: false },
    { state: "wide", name: "More actions", width: 1600, height: 900, theme: "dark", reducedMotion: false, menuOpen: false },
    { state: "reduced", name: "Open command palette", width: 1600, height: 900, theme: "dark", reducedMotion: true, menuOpen: false },
    { state: "overflow", name: "Appearance", width: 1600, height: 900, theme: "dark", reducedMotion: true, menuOpen: true },
  ];
  accessibilityExpectations.forEach((expected, index) => {
    const row = artifact(
      repoRoot,
      document.environmentId,
      document.evidence[ACCESSIBILITY[index]],
      `P-36 ${ACCESSIBILITY[index]}`,
      { mediaType: "json", minimumBytes: 300 },
    );
    validateA11y(
      row,
      `P-36 ${ACCESSIBILITY[index]}`,
      expected,
      timing.startedAt,
      timing.endedAt,
    );
  });
  const evidence = [
    ...envelope.attestation,
    ...Object.values(document.evidence),
  ];
  if (new Set(evidence.map((item) => item.path)).size !== evidence.length)
    fail("P-36 reuses evidence");
  return { document, evidence, endedAt: timing.endedAt };
}
export function buildP36Proof({ session, source, collectedAt }) {
  return {
    schemaVersion: 1,
    id: "openburnbar-linux-p36-visual-polish-proof-v1",
    requirementId: P36_REQUIREMENT_ID,
    environmentId: session.environmentId,
    targetHead: session.targetHead,
    candidate: session.candidate,
    package: {
      version: session.package.version,
      architecture: session.package.architecture,
      format: session.package.format,
    },
    collectedAt,
    source: { method: "live-installed-visual-polish-session", ...source },
    claim: {
      responsiveLayouts: true,
      noOverflowOrOverlap: true,
      nativeControlContrast: true,
      themeAndMotion: true,
      keyboardOverflowFocus: true,
      restartPersistence: true,
      exactRestoration: true,
      replayResistant: true,
    },
  };
}
export function validateP36Proof({
  snapshot,
  repoRoot,
  targetHead,
  environmentId,
  candidateRunId,
  candidateArtifactDigest,
  packageVersion,
  manifestSha256,
  manifestSignatureSha256,
}) {
  const value = parseJson(snapshot.bytes, "P-36 proof");
  exactKeys(
    value,
    [
      "candidate",
      "claim",
      "collectedAt",
      "environmentId",
      "id",
      "package",
      "requirementId",
      "schemaVersion",
      "source",
      "targetHead",
    ],
    "P-36 proof",
  );
  if (
    value.schemaVersion !== 1 ||
    value.id !== "openburnbar-linux-p36-visual-polish-proof-v1" ||
    value.requirementId !== P36_REQUIREMENT_ID ||
    value.targetHead !== targetHead ||
    value.environmentId !== environmentId ||
    String(value.candidate?.runId) !== String(candidateRunId) ||
    value.candidate?.artifactDigest !== candidateArtifactDigest
  )
    fail("P-36 proof binding is invalid");
  exactKeys(
    value.package,
    ["architecture", "format", "version"],
    "P-36 proof package",
  );
  exactKeys(
    value.claim,
    [
      "exactRestoration",
      "keyboardOverflowFocus",
      "nativeControlContrast",
      "noOverflowOrOverlap",
      "replayResistant",
      "responsiveLayouts",
      "restartPersistence",
      "themeAndMotion",
    ],
    "P-36 claim",
  );
  if (!Object.values(value.claim).every((item) => item === true))
    fail("P-36 claim is incomplete");
  exactKeys(
    value.source,
    ["method", "path", "sha256", "size"],
    "P-36 proof source",
  );
  if (value.source.method !== "live-installed-visual-polish-session")
    fail("P-36 proof source is not live");
  const source = artifact(
    repoRoot,
    environmentId,
    {
      path: value.source.path,
      sha256: value.source.sha256,
      size: value.source.size,
    },
    "P-36 session source",
    { mediaType: "json", minimumBytes: 1400 },
  );
  const validated = validateP36InstalledSession(
    parseJson(source.bytes, "P-36 source session"),
    {
      repoRoot,
      targetHead,
      environmentId,
      candidateRunId,
      candidateArtifactDigest,
      packageVersion,
      manifestSha256,
      manifestSignatureSha256,
    },
  );
  if (
    value.package.version !== packageVersion ||
    value.package.version !== validated.document.package.version ||
    value.package.architecture !== validated.document.package.architecture ||
    value.package.format !== validated.document.package.format
  )
    fail("P-36 proof package is not closure-bound");
  validateCollectedAt(value.collectedAt, validated.endedAt);
  return { ...value, evidence: validated.evidence };
}
