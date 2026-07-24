import assert from "node:assert/strict";
import fs from "node:fs";
import path from "node:path";
import test from "node:test";
import {
  parseNotificationServerInformation,
  parseP27PackageOwner,
  runP27NativeNotificationProbes,
  validateOAuthAuthorizationURL,
} from "./run-p27-native-notification-probes.mjs";

function fixture() {
  const base = path.join(process.cwd(), ".tmp/p27-native-tests");
  fs.mkdirSync(base, { recursive: true });
  const root = fs.mkdtempSync(path.join(base, "probe-"));
  for (const name of ["home", "runtime"])
    fs.mkdirSync(path.join(root, name), { mode: 0o700 });
  return {
    root,
    options: {
      rawOutputDir: path.join(root, "raw"),
      homeDir: path.join(root, "home"),
      runtimeDir: path.join(root, "runtime"),
      environmentId: "ubuntu-24.04-gnome-x11-aarch64",
      desktop: "GNOME",
      displayServer: "X11",
      marker: "p27-fedcba0987654321",
      targetHead: "1".repeat(40),
      candidateRunId: "27",
      candidateArtifactDigest: `sha256:${"3".repeat(64)}`,
      packageVersion: "1.2.3",
      manifestSha256: "4".repeat(64),
      manifestSignatureSha256: "5".repeat(64),
    },
  };
}
function dependencies(
  value,
  { hostileAccepted = false, cleanupFailure = false } = {},
) {
  let alive = false;
  const pid = 2727;
  let adapterCalls = 0;
  const a11y = (mode) => ({
    producer: "openburnbar-p27-atspi-live-v1",
    application: "OpenBurnBar",
    capturedAt: new Date().toISOString(),
    focusedName:
      mode === "reply"
        ? "Message composer"
        : mode === "warm"
          ? "Provider model"
          : mode === "cold"
            ? "Membership account"
            : "OpenBurnBar Overview",
    route:
      mode === "reply"
        ? "chat"
        : mode === "warm"
          ? "providers"
          : mode === "cold"
            ? "account"
            : "overview",
    composerFocused: mode === "reply",
    statusText:
      mode === "reply"
        ? "Message composer"
        : mode === "warm"
          ? "Provider model selected"
          : mode === "cold"
            ? "Membership link accepted"
            : "Overview dashboard",
    namedNodes: Array.from({ length: 7 }, (_, index) => ({
      name: `${mode}-${index}`,
      role: "section",
      actions: [],
    })),
  });
  return {
    platform: "linux",
    installedVerifier() {},
    executableVerifier() {},
    installedIdentity: () => ({
      packageManager: "dpkg",
      packageName: "open-burn-bar",
      packageOwned: true,
    }),
    autostartState: () => ({
      path: "/etc/xdg/autostart/openburnbar.desktop",
      exec: "openburnbar-linux-desktop --background",
      enabled: true,
      ownedByPackage: true,
      sha256: "a".repeat(64),
    }),
    desktopPids: () => (alive ? [pid] : []),
    daemonActive: () => true,
    runtimeFiles: () => [],
    runtimeManifest: () => ({
      sessionType: "x11",
      capabilities: [{ id: "native.notifications", state: "available" }],
    }),
    async loginStart() {
      return { loginStartObserved: true, startedInBackground: true };
    },
    async launch() {
      alive = true;
      return pid;
    },
    async terminate() {
      alive = false;
      if (cleanupFailure) throw new Error("cleanup failed");
    },
    async productNotification(kind, marker) {
      adapterCalls += 1;
      return {
        adapter: {
          actionsSupported: true,
          capabilityCommand: "native_notification_capabilities",
          deliveryCommand: "native_notification_show",
          serverName: "GNOME Shell",
          serverVendor: "GNOME",
          serverVersion: "46",
        },
        action: {
          action: kind,
          route: kind === "reply" ? "chat" : "overview",
          notificationId: `${marker}-${kind}`,
          delivered: true,
          serverActionObserved: true,
          productEventObserved: true,
          uiOutcomeObserved: true,
        },
        lifecycle: {
          coldQueuedBeforeRenderer: true,
          coldActionDrainedOnce: true,
          coldNotificationId: `${marker}-cold-reply`,
          coldForwardCount: 1,
          coldPendingAfterDrain: 0,
          coldForwardedBeforeWebDriverSession: true,
        },
      };
    },
    async deepLink(uri, phase) {
      return {
        ownerPid: pid,
        singleInstance: true,
        ...(phase === "warm"
          ? { forwardedToOwner: true, forwardCount: 1 }
          : {}),
      };
    },
    async oauthCallback() {
      return {
        ownerPid: pid,
        singleInstance: false,
        uri: `http://127.0.0.1:49152/callback?code=p27-code&state=${"s".repeat(43)}`,
        authorizationEndpoint: "https://accounts.google.com/o/oauth2/v2/auth",
        operationIdPresent: true,
        stateBound: true,
        wrongStateStatus: 400,
        callbackStatus: 200,
        replayRejected: true,
      };
    },
    async hostileLink(uri) {
      return {
        accepted: hostileAccepted,
        reason: "single_instance_deep_link_rejected",
      };
    },
    atspi(mode, file) {
      const value = a11y(mode);
      fs.writeFileSync(file, `${JSON.stringify(value)}\n`, { mode: 0o600 });
      return value;
    },
    screenshot(file) {
      fs.writeFileSync(file, Buffer.alloc(1024, path.basename(file).length), {
        mode: 0o600,
      });
    },
    metrics: () => ({ alive, adapterCalls }),
  };
}

test("P-27 native probe covers product notification actions, strict links, login start, and restoration", async () => {
  const value = fixture();
  const deps = dependencies(value);
  try {
    const result = await runP27NativeNotificationProbes(value.options, deps);
    assert.equal(result.transcript.notifications.reply.route, "chat");
    assert.equal(result.transcript.lifecycle.warmForwardCount, 1);
    assert.deepEqual(deps.metrics(), { alive: false, adapterCalls: 2 });
    assert.equal(
      fs.existsSync(
        path.join(value.options.rawOutputDir, "notification-marker.json"),
      ),
      true,
    );
  } finally {
    fs.rmSync(value.root, { recursive: true, force: true });
  }
});

test("P-27 native probe rejects a hostile link and aggregates cleanup failure", async () => {
  const value = fixture();
  const deps = dependencies(value, {
    hostileAccepted: true,
    cleanupFailure: true,
  });
  try {
    await assert.rejects(
      runP27NativeNotificationProbes(value.options, deps),
      (error) =>
        error instanceof AggregateError &&
        error.errors.some((item) => /hostile link/u.test(item.message)) &&
        error.errors.some((item) => /cleanup/u.test(item.message)),
    );
  } finally {
    fs.rmSync(value.root, { recursive: true, force: true });
  }
});

test("P-27 native probe rejects an unsupported notification action server", async () => {
  const value = fixture();
  const deps = dependencies(value);
  const original = deps.productNotification;
  deps.productNotification = async (...args) => {
    const result = await original(...args);
    result.adapter.actionsSupported = false;
    return result;
  };
  try {
    await assert.rejects(
      runP27NativeNotificationProbes(value.options, deps),
      (error) =>
        error instanceof AggregateError &&
        error.errors.some((item) => /unsupported/u.test(item.message)),
    );
  } finally {
    fs.rmSync(value.root, { recursive: true, force: true });
  }
});

test("P-27 native probe refuses replayable or unsafe evidence roots", async () => {
  const value = fixture();
  fs.mkdirSync(value.options.rawOutputDir, { mode: 0o700 });
  fs.writeFileSync(path.join(value.options.rawOutputDir, "stale"), "x");
  try {
    await assert.rejects(
      runP27NativeNotificationProbes(value.options, dependencies(value)),
      /must be empty/u,
    );
  } finally {
    fs.rmSync(value.root, { recursive: true, force: true });
  }
});

test("P-27 parses the live freedesktop notification server identity", () => {
  assert.deepEqual(
    parseNotificationServerInformation(
      "('GNOME Shell', 'GNOME', '46.2', '1.2')",
    ),
    {
      serverName: "GNOME Shell",
      serverVendor: "GNOME",
      serverVersion: "46.2",
    },
  );
  assert.throws(
    () => parseNotificationServerInformation("('GNOME Shell', '', '', '1.2')"),
    /incomplete/u,
  );
});

test("P-27 accepts only a high-entropy PKCE state and loopback callback", () => {
  const state = "s".repeat(43);
  const redirect = "http://127.0.0.1:49152/callback";
  const valid = new URL("https://accounts.google.com/o/oauth2/v2/auth");
  valid.searchParams.set("state", state);
  valid.searchParams.set("redirect_uri", redirect);
  const parsed = validateOAuthAuthorizationURL(valid);
  assert.equal(parsed.state, state);
  assert.equal(parsed.redirect.toString(), redirect);

  for (const invalid of [
    valid.toString().replace("accounts.google.com", "attacker.invalid"),
    valid.toString().replace("127.0.0.1", "localhost"),
    valid.toString().replace(state, "short"),
    `${valid}&state=${state}`,
  ]) {
    assert.throws(() => validateOAuthAuthorizationURL(invalid), /P-27 OAuth/u);
  }
});

test("P-27 accepts only the canonical package name for each Linux family", () => {
  assert.deepEqual(
    parseP27PackageOwner(
      "ubuntu-24.04-gnome-x11-aarch64",
      "/usr/bin/openburnbar-linux-desktop",
      "open-burn-bar: /usr/bin/openburnbar-linux-desktop",
    ),
    { manager: "dpkg", packageName: "open-burn-bar" },
  );
  assert.deepEqual(
    parseP27PackageOwner(
      "fedora-42-kde-wayland-x86_64",
      "/usr/bin/openburnbar-linux-desktop",
      "open-burn-bar-0.1.1-1.x86_64",
    ),
    { manager: "rpm", packageName: "open-burn-bar" },
  );
  assert.deepEqual(
    parseP27PackageOwner(
      "arch-gnome-wayland-x86_64",
      "/usr/bin/openburnbar-linux-desktop",
      "/usr/bin/openburnbar-linux-desktop is owned by openburnbar 0.1.1-1",
    ),
    { manager: "pacman", packageName: "openburnbar" },
  );
  assert.throws(
    () =>
      parseP27PackageOwner(
        "ubuntu-24.04-gnome-x11-aarch64",
        "/usr/bin/openburnbar-linux-desktop",
        "substitute: /usr/bin/openburnbar-linux-desktop",
      ),
    /substitute/u,
  );
});
