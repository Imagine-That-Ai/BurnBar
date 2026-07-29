import assert from "node:assert/strict";
import fs from "node:fs";
import path from "node:path";
import test from "node:test";
import {
  parseP26MenuLayout,
  parseP26MenuRevision,
  parseP26PackageOwner,
  parseP26RegisteredItems,
  readP26ServiceActive,
  runP26NativeTrayProbes,
  validateP26ProbePaths,
} from "./run-p26-native-tray-probes.mjs";

const IDENTITY = {
  environmentId: "ubuntu-24.04-gnome-x11-aarch64",
  targetHead: "a".repeat(40),
  candidateRunId: "262626",
  candidateArtifactDigest: `sha256:${"b".repeat(64)}`,
  packageVersion: "1.2.3",
  manifestSha256: "c".repeat(64),
  manifestSignatureSha256: "d".repeat(64),
  compositor: "Mutter",
};
const ROUTES = [
  ["dashboard", "Overview"],
  ["chat", "Chat / Hermes"],
  ["usage", "Insights"],
  ["updates", "Updates"],
  ["settings", "Settings"],
];
function fixture() {
  const base = path.join(process.cwd(), ".tmp/p26-native-probe-tests");
  fs.mkdirSync(base, { recursive: true });
  const root = fs.mkdtempSync(path.join(base, "case-"));
  fs.chmodSync(root, 0o700);
  const options = {
    rawOutputDir: path.join(root, "raw"),
    supportDir: path.join(root, "support"),
    homeDir: path.join(root, "home"),
    socketPath: path.join(root, "support/daemon.sock"),
    tokenFile: path.join(root, "support/token"),
    indexDatabase: path.join(root, "support/index.sqlite"),
    ...IDENTITY,
  };
  for (const directory of [
    options.rawOutputDir,
    options.supportDir,
    options.homeDir,
  ])
    fs.mkdirSync(directory, { mode: 0o700 });
  return { root, options };
}
function menu(usage = 42, daemon = "connected") {
  return [
    ["Open dashboard", true],
    ["Open chat", true],
    ["Open usage", true],
    ["Open updates", true],
    ["Open settings", true],
    [
      daemon === "connected"
        ? `Daemon: connected - p26-installed-${IDENTITY.packageVersion}`
        : "Daemon: offline",
      false,
    ],
    [`Recent usage: ${usage} tokens - $0.01`, false],
    ["Updates: up to date", false],
    ["Refresh status", true],
    ["Reconnect daemon", true],
    ["Quit OpenBurnBar", true],
  ].map(([label, enabled], index) => ({ id: index + 1, label, enabled }));
}
function dependencies(options, failRoute = null) {
  let pid = 2600;
  let registration = ":1.26/org/ayatana/NotificationItem/openburnbar";
  let alive = false;
  let menuReads = 0;
  let health = "connected";
  let restored = 0;
  let time = Date.parse("2026-07-20T18:00:00.000Z");
  const actions = [];
  const driver = {
    async launchBackground() {
      alive = true;
      return { pid, registration };
    },
    registrationIdentity() {
      return registration;
    },
    screenshotBackground() {
      fs.writeFileSync(
        path.join(options.rawOutputDir, "tray-background.png"),
        Buffer.alloc(2048, 1),
        { mode: 0o600 },
      );
    },
    async tray() {
      menuReads += 1;
      return {
        protocol: "AppIndicator",
        service: registration.split("/")[0],
        path: `/${registration.split("/").slice(1).join("/")}`,
        menuPath: "/Menu",
        tooltip: "OpenBurnBar — Linux desktop assistant",
        revision: 9 + menuReads,
        items: menu(menuReads === 1 ? 42 : 43, health),
      };
    },
    health() {
      return health;
    },
    async action(label) {
      actions.push(label);
      if (label === "Quit OpenBurnBar") alive = false;
      return {
        menuId: menu().find((item) => item.label === label).id,
        dbusReply: "method return time=1",
      };
    },
    async route(route, accessibleName) {
      if (route === failRoute) throw new Error(`forced ${route}`);
      fs.writeFileSync(
        path.join(options.rawOutputDir, `tray-${route}.png`),
        Buffer.alloc(2048, ROUTES.findIndex(([name]) => name === route) + 2),
        { mode: 0o600 },
      );
      fs.writeFileSync(
        path.join(options.rawOutputDir, `tray-${route}-atspi.json`),
        `${JSON.stringify({ application: "OpenBurnBar", name: accessibleName, nodes: [{ name: accessibleName }] })}\n`,
        { mode: 0o600 },
      );
      return { visible: true, appPid: pid };
    },
    async keyboardFocus() {
      return true;
    },
    async hide() {
      return alive;
    },
    async reopenedSameProcess(expected) {
      return alive && expected === pid;
    },
    async waitTerminated() {
      alive = false;
    },
    async relaunch(previous) {
      assert.equal(previous, registration);
      pid += 1;
      registration = ":1.27/org/ayatana/NotificationItem/openburnbar";
      alive = true;
      return { pid, registration };
    },
    async terminate() {
      alive = false;
    },
    alive() {
      return alive;
    },
  };
  return {
    platform: "linux",
    desktopSession: true,
    installedVerifier: () => ({}),
    executableVerifier: () => {},
    desktopProcessIDs: () => [],
    marker: "p26-fedcba0987654321",
    autostart: {
      path: "/etc/xdg/autostart/openburnbar.desktop",
      exec: "/usr/bin/openburnbar-linux-desktop --background",
      packageOwned: true,
      manager: "dpkg",
      packageName: "open-burn-bar",
      sha256: "e".repeat(64),
    },
    clock: () => new Date((time += 10)),
    driver,
    daemon: {
      async prepare() {
        return true;
      },
      async restore() {
        restored += 1;
      },
      async disconnect() {
        health = "disconnected";
      },
      async reconnect() {
        health = "connected";
      },
      active() {
        return true;
      },
    },
    actions,
    restored: () => restored,
  };
}

test("P-26 native runner proves tray routes, persistence, actions, and restoration", async () => {
  const value = fixture();
  const deps = dependencies(value.options);
  try {
    const result = await runP26NativeTrayProbes(value.options, deps);
    assert.equal(result.primaryPid, 2600);
    assert.equal(result.relaunchPid, 2601);
    assert.equal(deps.restored(), 1);
    assert.deepEqual(deps.actions, [
      "Open dashboard",
      "Open chat",
      "Open usage",
      "Open updates",
      "Open settings",
      "Open dashboard",
      "Refresh status",
      "Reconnect daemon",
      "Quit OpenBurnBar",
    ]);
    const transcript = JSON.parse(
      fs.readFileSync(path.join(result.output, "tray-native-transcript.json")),
    );
    assert.equal(transcript.actions.length, 9);
    assert.equal(transcript.routes.length, 5);
    assert.equal(transcript.persistence.trayReregistered, true);
    assert.equal(transcript.restoration.daemonActiveAfter, true);
    assert.equal(transcript.daemon.beforeReconnectHealth, "disconnected");
    assert.equal(transcript.daemon.afterReconnectHealth, "connected");
    assert.deepEqual(
      [
        transcript.tray.initialMenuRevision,
        transcript.tray.refreshedMenuRevision,
        transcript.tray.disconnectedMenuRevision,
        transcript.tray.reconnectedMenuRevision,
      ],
      [10, 11, 12, 13],
    );
  } finally {
    fs.rmSync(value.root, { recursive: true, force: true });
  }
});

test("P-26 native runner restores the daemon and desktop process on UI failure", async () => {
  const value = fixture();
  const deps = dependencies(value.options, "updates");
  try {
    await assert.rejects(
      () => runP26NativeTrayProbes(value.options, deps),
      /forced updates/u,
    );
    assert.equal(deps.restored(), 1);
    assert.equal(deps.driver.alive(), false);
    assert.equal(
      fs.existsSync(
        path.join(value.options.rawOutputDir, "tray-native-transcript.json"),
      ),
      false,
    );
  } finally {
    fs.rmSync(value.root, { recursive: true, force: true });
  }
});

test("P-26 native runner refuses to disturb a preexisting desktop process", async () => {
  const value = fixture();
  const deps = dependencies(value.options);
  deps.desktopProcessIDs = () => [999];
  try {
    await assert.rejects(
      () => runP26NativeTrayProbes(value.options, deps),
      /refuses to disturb/u,
    );
    assert.equal(deps.restored(), 0);
  } finally {
    fs.rmSync(value.root, { recursive: true, force: true });
  }
});

test("P-26 parses native watcher and DBusMenu receipts without inventing items", () => {
  assert.deepEqual(
    parseP26RegisteredItems(
      "([':1.26/org/ayatana/NotificationItem/openburnbar'],)",
    ),
    [
      {
        service: ":1.26",
        path: "/org/ayatana/NotificationItem/openburnbar",
      },
    ],
  );
  const layout =
    "(uint32 2, (0, {'children-display': <'submenu'>}, [" +
    "<(2, {'label': <'Open dashboard'>}, @av [])>, " +
    "<(3, {'label': <'Daemon: connected - p26-installed-1.2.3'>, 'enabled': <false>}, @av [])>, " +
    "<(4, {'label': <'Quit OpenBurnBar'>}, @av [])>]))";
  assert.deepEqual(parseP26MenuLayout(layout), [
    { id: 2, label: "Open dashboard", enabled: true },
    {
      id: 3,
      label: "Daemon: connected - p26-installed-1.2.3",
      enabled: false,
    },
    { id: 4, label: "Quit OpenBurnBar", enabled: true },
  ]);
  assert.equal(parseP26MenuRevision(layout), 2);
});

test("P-26 accepts only the canonical package owner on every native manager", () => {
  assert.deepEqual(
    parseP26PackageOwner(
      "ubuntu-24.04-gnome-x11-aarch64",
      "open-burn-bar: /etc/xdg/autostart/openburnbar.desktop",
    ),
    { manager: "dpkg", packageName: "open-burn-bar" },
  );
  assert.deepEqual(
    parseP26PackageOwner(
      "fedora-42-gnome-wayland-x86_64",
      "open-burn-bar-1.2.3-1.x86_64",
    ),
    { manager: "rpm", packageName: "open-burn-bar" },
  );
  assert.deepEqual(
    parseP26PackageOwner(
      "arch-current-kde-wayland-x86_64",
      "/etc/xdg/autostart/openburnbar.desktop is owned by openburnbar 1.2.3-1",
    ),
    { manager: "pacman", packageName: "openburnbar" },
  );
  assert.throws(
    () =>
      parseP26PackageOwner(
        "ubuntu-24.04-gnome-x11-aarch64",
        "substitute: /etc/xdg/autostart/openburnbar.desktop",
      ),
    /not canonical/u,
  );
});

test("P-26 systemd state detection fails closed on ambiguous command results", () => {
  const runner = (status, stdout, stderr = "") => ({
    run: () => ({ status, stdout, stderr }),
  });
  assert.equal(readP26ServiceActive(runner(0, "active\n")), true);
  assert.equal(readP26ServiceActive(runner(3, "inactive\n")), false);
  assert.throws(
    () => readP26ServiceActive(runner(1, "", "D-Bus unavailable")),
    /could not determine/u,
  );
  assert.throws(
    () => readP26ServiceActive(runner(3, "failed\n")),
    /could not determine/u,
  );
});

test("P-26 confines support paths and rejects unsafe token and index files", () => {
  const outsideSocket = fixture();
  const tokenLink = fixture();
  const weakToken = fixture();
  const indexLink = fixture();
  try {
    outsideSocket.options.socketPath = path.join(
      outsideSocket.root,
      "daemon.sock",
    );
    assert.throws(
      () => validateP26ProbePaths(outsideSocket.options),
      /direct child/u,
    );
    const outside = path.join(tokenLink.root, "outside-token");
    fs.writeFileSync(outside, "a".repeat(64), { mode: 0o600 });
    fs.symlinkSync(outside, tokenLink.options.tokenFile);
    assert.throws(
      () => validateP26ProbePaths(tokenLink.options),
      /non-symlink/u,
    );
    fs.writeFileSync(weakToken.options.tokenFile, "b".repeat(64), {
      mode: 0o644,
    });
    assert.throws(() => validateP26ProbePaths(weakToken.options), /mode 600/u);
    const outsideIndex = path.join(indexLink.root, "outside-index");
    fs.writeFileSync(outsideIndex, "index", { mode: 0o600 });
    fs.symlinkSync(outsideIndex, indexLink.options.indexDatabase);
    assert.throws(
      () => validateP26ProbePaths(indexLink.options),
      /index database.*non-symlink/u,
    );
  } finally {
    for (const value of [outsideSocket, tokenLink, weakToken, indexLink])
      fs.rmSync(value.root, { recursive: true, force: true });
  }
});

test("P-26 reports primary and cleanup failures as an AggregateError", async () => {
  const value = fixture();
  const deps = dependencies(value.options, "updates");
  deps.driver.terminate = async () => {
    throw new Error("desktop cleanup failed");
  };
  deps.daemon.restore = async () => {
    throw new Error("daemon cleanup failed");
  };
  try {
    await assert.rejects(
      () => runP26NativeTrayProbes(value.options, deps),
      (error) => {
        assert(error instanceof AggregateError);
        assert.deepEqual(
          error.errors.map((item) => item.message),
          ["forced updates", "desktop cleanup failed", "daemon cleanup failed"],
        );
        return true;
      },
    );
  } finally {
    fs.rmSync(value.root, { recursive: true, force: true });
  }
});
