import {
  exactKeys,
  parseJson,
  validateArtifact,
  validateCollectedAt,
  validateInstalledSessionEnvelope,
  validatePng,
} from "./installed-ui-proof.mjs";

export const P27_REQUIREMENT_ID = "P-27";
export const P27_PROOF_ROLE = "feature.notifications-deep-links-installed";
export const P27_PROOF_FILENAME = "p27-installed-notifications-proof.json";
export const P27_SESSION_FILENAME = "p27-installed-notifications-session.json";

const MARKER = /^p27-[a-f0-9]{16}$/u;
const SHA256 = /^[a-f0-9]{64}$/u;
const SCREENSHOTS = [
  "openScreenshot",
  "replyScreenshot",
  "coldScreenshot",
  "warmScreenshot",
];
const ACCESSIBILITY = [
  "openAccessibility",
  "replyAccessibility",
  "coldAccessibility",
  "warmAccessibility",
];
const LINK_KINDS = ["oauth", "membership", "provider-model"];

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
    P27_REQUIREMENT_ID,
    environmentId,
    label,
    options,
  );
}

function validateMarker(value, expected) {
  exactKeys(
    value,
    ["installed", "marker", "runtimeManifest", "safety"],
    "P-27 marker",
  );
  if (!MARKER.test(value.marker ?? "")) fail("P-27 marker identity is invalid");
  exactKeys(
    value.installed,
    [
      "autostart",
      "daemon",
      "desktop",
      "packageManager",
      "packageName",
      "packageOwned",
    ],
    "P-27 installed identity",
  );
  const manager = { deb: "dpkg", rpm: "rpm", arch: "pacman" }[expected.format];
  const packageName =
    expected.format === "arch" ? "openburnbar" : "open-burn-bar";
  if (
    value.installed.daemon !== "/usr/bin/openburnbar-daemon" ||
    value.installed.desktop !== "/usr/bin/openburnbar-linux-desktop" ||
    value.installed.autostart !== "/etc/xdg/autostart/openburnbar.desktop" ||
    value.installed.packageManager !== manager ||
    value.installed.packageName !== packageName ||
    value.installed.packageOwned !== true
  )
    fail("P-27 did not use canonical package-owned installed files");
  exactKeys(
    value.runtimeManifest,
    ["capturedFrom", "notificationState", "sha256"],
    "P-27 runtime manifest marker",
  );
  if (
    value.runtimeManifest.capturedFrom !==
      "/usr/bin/openburnbar-linux-desktop --runtime-capabilities" ||
    !["available", "degraded", "unavailable"].includes(
      value.runtimeManifest.notificationState,
    ) ||
    !SHA256.test(value.runtimeManifest.sha256 ?? "")
  )
    fail("P-27 runtime manifest marker is invalid");
  exactKeys(
    value.safety,
    [
      "autostartRestored",
      "daemonRestored",
      "desktopProcessesRestored",
      "fixtureMode",
      "isolatedHome",
      "preexistingDesktopProcesses",
      "singleInstanceStateRestored",
    ],
    "P-27 safety",
  );
  if (
    value.safety.fixtureMode !== false ||
    value.safety.isolatedHome !== true ||
    value.safety.autostartRestored !== true ||
    value.safety.daemonRestored !== true ||
    value.safety.desktopProcessesRestored !== true ||
    value.safety.singleInstanceStateRestored !== true ||
    !Array.isArray(value.safety.preexistingDesktopProcesses) ||
    value.safety.preexistingDesktopProcesses.length !== 0
  )
    fail("P-27 process, login-start, or state restoration is incomplete");
}

function validateAccessibility(snapshot, label, expected, startedAt, endedAt) {
  const value = parseJson(snapshot.bytes, label);
  exactKeys(
    value,
    [
      "application",
      "capturedAt",
      "composerFocused",
      "focusedName",
      "namedNodes",
      "producer",
      "route",
      "statusText",
    ],
    label,
  );
  if (
    value.application !== "OpenBurnBar" ||
    value.producer !== "openburnbar-p27-atspi-live-v1" ||
    value.route !== expected.route ||
    value.composerFocused !== expected.composer ||
    typeof value.focusedName !== "string" ||
    !expected.focus.test(value.focusedName) ||
    typeof value.statusText !== "string" ||
    !expected.status.test(value.statusText) ||
    !Array.isArray(value.namedNodes) ||
    value.namedNodes.length < 6
  )
    fail(`${label} does not prove the required focus and status outcome`);
  const capturedAt = instant(value.capturedAt, `${label} capture`);
  if (capturedAt < startedAt || capturedAt > endedAt)
    fail(`${label} is outside the live session`);
}

function validateTranscript(
  value,
  marker,
  expected,
  runtimeSha256,
  startedAt,
  endedAt,
) {
  exactKeys(
    value,
    [
      "adapter",
      "autostart",
      "compositor",
      "deepLinks",
      "endedAt",
      "hostileLinks",
      "lifecycle",
      "marker",
      "notifications",
      "producer",
      "restoration",
      "runtime",
      "startedAt",
    ],
    "P-27 native transcript",
  );
  const start = instant(value.startedAt, "P-27 transcript start");
  const end = instant(value.endedAt, "P-27 transcript end");
  if (
    start < startedAt ||
    end > endedAt ||
    end <= start ||
    value.marker !== marker.marker ||
    value.producer !== "openburnbar-p27-installed-notifications-probe-v1"
  )
    fail("P-27 transcript is stale or not bound to the live session");
  exactKeys(
    value.runtime,
    ["manifestSha256", "notificationState", "source"],
    "P-27 runtime transcript",
  );
  if (
    value.runtime.manifestSha256 !== runtimeSha256 ||
    value.runtime.manifestSha256 !== marker.runtimeManifest.sha256 ||
    value.runtime.notificationState !==
      marker.runtimeManifest.notificationState ||
    value.runtime.source !== "installed-runtime-command"
  )
    fail("P-27 runtime evidence is substituted or stale");
  exactKeys(
    value.compositor,
    ["desktop", "displayServer", "sessionType"],
    "P-27 compositor transcript",
  );
  if (
    value.compositor.desktop !== expected.desktop ||
    value.compositor.displayServer !== expected.session ||
    value.compositor.sessionType !== expected.session.toLowerCase()
  )
    fail("P-27 compositor/session truth does not match the environment");
  exactKeys(
    value.adapter,
    [
      "actionsSupported",
      "capabilityCommand",
      "deliveryCommand",
      "serverName",
      "serverVendor",
      "serverVersion",
    ],
    "P-27 product adapter",
  );
  if (
    value.adapter.capabilityCommand !== "native_notification_capabilities" ||
    value.adapter.deliveryCommand !== "native_notification_show" ||
    value.adapter.actionsSupported !== true ||
    ![
      value.adapter.serverName,
      value.adapter.serverVendor,
      value.adapter.serverVersion,
    ].every(
      (item) =>
        typeof item === "string" && item.trim() === item && item.length > 0,
    )
  )
    fail(
      "P-27 did not use a live actionable freedesktop notification server through the product adapter",
    );
  exactKeys(
    value.notifications,
    ["open", "reply"],
    "P-27 notification actions",
  );
  for (const [kind, route, composer] of [
    ["open", "overview", false],
    ["reply", "chat", true],
  ]) {
    const action = value.notifications[kind];
    exactKeys(
      action,
      [
        "action",
        "delivered",
        "notificationId",
        "productEventObserved",
        "route",
        "serverActionObserved",
        "uiOutcomeObserved",
      ],
      `P-27 ${kind} notification`,
    );
    if (
      action.action !== kind ||
      action.route !== route ||
      action.delivered !== true ||
      action.serverActionObserved !== true ||
      action.productEventObserved !== true ||
      action.uiOutcomeObserved !== true ||
      !/^p27-[a-f0-9]{16}-(?:open|reply)$/u.test(action.notificationId) ||
      (kind === "reply" && composer !== true)
    )
      fail(`P-27 ${kind} notification action is incomplete`);
  }
  if (!Array.isArray(value.deepLinks) || value.deepLinks.length !== 3)
    fail("P-27 requires OAuth, membership, and provider-model deep links");
  const ownerPids = new Set();
  const linkContract = {
    oauth: {
      phase: "cold",
      route: "account",
      singleInstance: false,
      transport: "loopback",
      uri: /^http:\/\/127\.0\.0\.1:[1-9][0-9]{3,4}\/callback\?code=p27-[a-f0-9]{16}-authorization-code&state=[A-Za-z0-9_-]{43}$/u,
    },
    membership: {
      phase: "cold",
      route: "account",
      singleInstance: true,
      transport: "single-instance",
      uri: /^openburnbar:\/\/membership\/(?:success|cancel)$/u,
    },
    "provider-model": {
      phase: "warm",
      route: "providers",
      singleInstance: true,
      transport: "single-instance",
      uri: /^openburnbar:\/\/providers\?provider=[A-Za-z0-9._~%+-]+&model=[A-Za-z0-9._~%+-]+$/u,
    },
  };
  for (const [index, kind] of LINK_KINDS.entries()) {
    const link = value.deepLinks[index];
    exactKeys(
      link,
      kind === "oauth"
        ? [
            "accepted",
            "authorizationEndpoint",
            "callbackStatus",
            "kind",
            "operationIdPresent",
            "ownerPid",
            "phase",
            "replayRejected",
            "route",
            "singleInstance",
            "stateBound",
            "transport",
            "uri",
            "wrongStateStatus",
          ]
        : [
            "accepted",
            "kind",
            "ownerPid",
            "phase",
            "route",
            "singleInstance",
            "transport",
            "uri",
          ],
      `P-27 ${kind} deep link`,
    );
    const contract = linkContract[kind];
    if (
      link.kind !== kind ||
      link.accepted !== true ||
      link.phase !== contract.phase ||
      link.route !== contract.route ||
      link.singleInstance !== contract.singleInstance ||
      link.transport !== contract.transport ||
      !Number.isSafeInteger(link.ownerPid) ||
      link.ownerPid <= 1 ||
      typeof link.uri !== "string" ||
      !contract.uri.test(link.uri)
    )
      fail(
        `P-27 ${kind} deep link was not strictly accepted by the installed owner`,
      );
    if (
      kind === "oauth" &&
      (link.authorizationEndpoint !==
        "https://accounts.google.com/o/oauth2/v2/auth" ||
        link.operationIdPresent !== true ||
        link.stateBound !== true ||
        link.wrongStateStatus !== 400 ||
        link.callbackStatus !== 200 ||
        link.replayRejected !== true)
    )
      fail(
        "P-27 OAuth callback was not bound to an active one-shot PKCE operation",
      );
    ownerPids.add(link.ownerPid);
  }
  if (ownerPids.size !== 1)
    fail("P-27 deep links did not retain one installed owner process");
  if (!Array.isArray(value.hostileLinks) || value.hostileLinks.length < 5)
    fail("P-27 hostile-link rejection coverage is incomplete");
  for (const row of value.hostileLinks) {
    exactKeys(row, ["accepted", "reason", "uri"], "P-27 hostile link");
    if (
      row.accepted !== false ||
      typeof row.reason !== "string" ||
      !row.reason.startsWith("single_instance_") ||
      typeof row.uri !== "string"
    )
      fail("P-27 accepted or obscured a hostile deep link");
  }
  exactKeys(
    value.lifecycle,
    [
      "coldActionDrainedOnce",
      "coldForwardCount",
      "coldForwardedBeforeWebDriverSession",
      "coldNotificationId",
      "coldPendingAfterDrain",
      "coldQueuedBeforeRenderer",
      "ownerPid",
      "warmForwardCount",
      "warmForwardedToOwner",
    ],
    "P-27 lifecycle",
  );
  if (
    value.lifecycle.coldQueuedBeforeRenderer !== true ||
    value.lifecycle.coldActionDrainedOnce !== true ||
    value.lifecycle.coldNotificationId !== `${marker.marker}-cold-reply` ||
    value.lifecycle.coldForwardCount !== 1 ||
    value.lifecycle.coldForwardedBeforeWebDriverSession !== true ||
    value.lifecycle.coldPendingAfterDrain !== 0 ||
    value.lifecycle.warmForwardedToOwner !== true ||
    value.lifecycle.warmForwardCount !== 1 ||
    value.lifecycle.ownerPid !== value.deepLinks[0].ownerPid
  )
    fail("P-27 cold queue or warm single-instance forwarding is incomplete");
  exactKeys(
    value.autostart,
    [
      "enabled",
      "exec",
      "loginStartObserved",
      "ownedByPackage",
      "path",
      "startedInBackground",
    ],
    "P-27 autostart",
  );
  if (
    value.autostart.path !== "/etc/xdg/autostart/openburnbar.desktop" ||
    value.autostart.exec !== "openburnbar-linux-desktop --background" ||
    value.autostart.enabled !== true ||
    value.autostart.ownedByPackage !== true ||
    value.autostart.loginStartObserved !== true ||
    value.autostart.startedInBackground !== true
  )
    fail("P-27 XDG login start was not proven from the packaged entry");
  exactKeys(
    value.restoration,
    [
      "autostartAfterSha256",
      "autostartBeforeSha256",
      "daemonActiveAfter",
      "daemonWasActive",
      "desktopPidsAfter",
      "desktopPidsBefore",
      "runtimeFilesAfter",
      "runtimeFilesBefore",
    ],
    "P-27 restoration",
  );
  if (
    value.restoration.autostartAfterSha256 !==
      value.restoration.autostartBeforeSha256 ||
    value.restoration.daemonActiveAfter !== value.restoration.daemonWasActive ||
    JSON.stringify(value.restoration.desktopPidsAfter) !==
      JSON.stringify(value.restoration.desktopPidsBefore) ||
    JSON.stringify(value.restoration.runtimeFilesAfter) !==
      JSON.stringify(value.restoration.runtimeFilesBefore)
  )
    fail(
      "P-27 did not restore exact process, service, autostart, and single-instance state",
    );
}

export function validateP27InstalledSession(
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
    "P-27 installed session",
  );
  if (
    document.schemaVersion !== 1 ||
    document.id !== "openburnbar-linux-p27-installed-notifications-session-v1"
  )
    fail("P-27 session identity is invalid");
  const envelope = validateInstalledSessionEnvelope(
    document,
    binding,
    P27_REQUIREMENT_ID,
    "P-27 installed session",
  );
  validateMarker(document.marker, envelope.expected);
  exactKeys(
    document.evidence,
    [
      "coldAccessibility",
      "coldScreenshot",
      "nativeTranscript",
      "openAccessibility",
      "openScreenshot",
      "replyAccessibility",
      "replyScreenshot",
      "runtimeManifest",
      "warmAccessibility",
      "warmScreenshot",
    ],
    "P-27 evidence",
  );
  const runtime = artifact(
    repoRoot,
    binding.environmentId,
    document.evidence.runtimeManifest,
    "P-27 runtime manifest",
    { mediaType: "json" },
  );
  if (runtime.sha256 !== document.marker.runtimeManifest.sha256)
    fail("P-27 runtime manifest digest changed");
  const manifest = parseJson(runtime.bytes, "P-27 runtime manifest");
  const notification = manifest.capabilities?.find?.(
    (item) => item.id === "native.notifications",
  );
  if (
    !notification ||
    notification.state !== document.marker.runtimeManifest.notificationState ||
    String(manifest.sessionType ?? "").toLowerCase() !==
      envelope.expected.session.toLowerCase()
  )
    fail(
      "P-27 runtime manifest omits native.notifications or changes session truth",
    );
  const native = artifact(
    repoRoot,
    binding.environmentId,
    document.evidence.nativeTranscript,
    "P-27 native transcript",
    { mediaType: "json" },
  );
  const transcript = parseJson(native.bytes, "P-27 native transcript");
  validateTranscript(
    transcript,
    document.marker,
    envelope.expected,
    runtime.sha256,
    envelope.startedAt,
    envelope.endedAt,
  );
  const expected = [
    {
      route: "overview",
      composer: false,
      focus: /OpenBurnBar|Overview|Dashboard/iu,
      status: /overview|dashboard/iu,
    },
    {
      route: "chat",
      composer: true,
      focus: /message|composer|chat/iu,
      status: /message|composer|chat/iu,
    },
    {
      route: "account",
      composer: false,
      focus: /account|membership/iu,
      status: /membership|account/iu,
    },
    {
      route: "providers",
      composer: false,
      focus: /provider|model/iu,
      status: /provider|model/iu,
    },
  ];
  const seen = new Set();
  for (const [index, key] of SCREENSHOTS.entries()) {
    const shot = artifact(
      repoRoot,
      binding.environmentId,
      document.evidence[key],
      `P-27 ${key}`,
      { mediaType: "png", minimumBytes: 256 },
    );
    const pixels = validatePng(shot.bytes, `P-27 ${key}`);
    if (pixels.nonBlankPixelRatio < 0.05 || seen.has(shot.sha256))
      fail("P-27 screenshots are blank or replayed");
    seen.add(shot.sha256);
    const a11y = artifact(
      repoRoot,
      binding.environmentId,
      document.evidence[ACCESSIBILITY[index]],
      `P-27 ${ACCESSIBILITY[index]}`,
      { mediaType: "json" },
    );
    if (seen.has(a11y.sha256)) fail("P-27 AT-SPI evidence is replayed");
    seen.add(a11y.sha256);
    validateAccessibility(
      a11y,
      `P-27 ${ACCESSIBILITY[index]}`,
      expected[index],
      envelope.startedAt,
      envelope.endedAt,
    );
  }
  const evidence = [
    ...Object.values(document.evidence),
    ...envelope.attestation,
  ];
  if (new Set(evidence.map((item) => item.path)).size !== evidence.length)
    fail("P-27 reuses an evidence artifact");
  return { document, transcript, evidence };
}

export function buildP27Proof({ session, source, collectedAt, validated }) {
  return {
    schemaVersion: 1,
    id: "openburnbar-linux-p27-notifications-proof-v1",
    requirementId: P27_REQUIREMENT_ID,
    environmentId: session.environmentId,
    targetHead: session.targetHead,
    candidate: session.candidate,
    collectedAt,
    source,
    claim: {
      installedCandidate: true,
      actionableOpenAndReply: true,
      coldAndWarmLifecycle: true,
      strictDeepLinks: true,
      hostileLinksRejected: true,
      xdgLoginStart: true,
      accessibilityOutcomes: true,
      compositorTruth: validated.transcript.compositor.displayServer,
    },
  };
}

export function validateP27Proof({ snapshot, ...binding }) {
  const proof = parseJson(snapshot.bytes, "P-27 proof");
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
    "P-27 proof",
  );
  if (
    proof.schemaVersion !== 1 ||
    proof.id !== "openburnbar-linux-p27-notifications-proof-v1" ||
    proof.requirementId !== P27_REQUIREMENT_ID ||
    proof.environmentId !== binding.environmentId ||
    proof.targetHead !== binding.targetHead ||
    proof.candidate.runId !== String(binding.candidateRunId) ||
    proof.candidate.artifactDigest !== binding.candidateArtifactDigest
  )
    fail("P-27 proof identity or candidate binding is invalid");
  const source = artifact(
    binding.repoRoot,
    binding.environmentId,
    proof.source,
    "P-27 proof source",
    { mediaType: "json" },
  );
  const validated = validateP27InstalledSession(
    parseJson(source.bytes, "P-27 proof source"),
    binding,
  );
  validateCollectedAt(
    proof.collectedAt,
    Date.parse(validated.document.capture.endedAt),
  );
  const expected = buildP27Proof({
    session: validated.document,
    source: proof.source,
    collectedAt: proof.collectedAt,
    validated,
  }).claim;
  if (JSON.stringify(proof.claim) !== JSON.stringify(expected))
    fail("P-27 proof overclaims the validated installed session");
  return { ...validated, source, proof };
}
