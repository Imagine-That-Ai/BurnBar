#!/usr/bin/env node
import crypto from "node:crypto";
import fs from "node:fs";
import path from "node:path";
import { spawn, spawnSync } from "node:child_process";
import { fileURLToPath } from "node:url";
import { verifyInstalledCandidate } from "./run-p08-mercury-media-session.mjs";

const ROOT = path.resolve(
  path.dirname(fileURLToPath(import.meta.url)),
  "../..",
);
const DESKTOP = "/usr/bin/openburnbar-linux-desktop";
const DAEMON_LAUNCHER = "/usr/libexec/openburnbar-daemon-launch";
const AUTOSTART = "/etc/xdg/autostart/openburnbar.desktop";
const ROUTES = Object.freeze([
  ["dashboard", "Open dashboard", "Overview"],
  ["chat", "Open chat", "Chat / Hermes"],
  ["usage", "Open usage", "Insights"],
  ["updates", "Open updates", "Updates"],
  ["settings", "Open settings", "Settings"],
]);

function assert(value, message) {
  if (!value) throw new Error(message);
}
function sleep(ms) {
  return new Promise((resolve) => setTimeout(resolve, ms));
}
function writeExclusive(file, bytes) {
  const descriptor = fs.openSync(
    file,
    fs.constants.O_WRONLY | fs.constants.O_CREAT | fs.constants.O_EXCL,
    0o600,
  );
  try {
    fs.writeFileSync(descriptor, bytes);
    fs.fsyncSync(descriptor);
  } finally {
    fs.closeSync(descriptor);
  }
}
function writeJson(file, value) {
  writeExclusive(file, Buffer.from(`${JSON.stringify(value, null, 2)}\n`));
}
function assertCanonicalExistingAncestor(supplied, label) {
  let current = supplied;
  while (true) {
    try {
      fs.lstatSync(current);
      break;
    } catch (error) {
      if (error?.code !== "ENOENT") throw error;
      const parent = path.dirname(current);
      assert(parent !== current, `${label} has no existing parent`);
      current = parent;
    }
  }
  assert(
    fs.realpathSync(current) === current,
    `${label} cannot traverse a symbolic link`,
  );
}
function ownerOnlyDirectory(directory, label, { empty = false } = {}) {
  const supplied = path.resolve(directory);
  assertCanonicalExistingAncestor(supplied, label);
  fs.mkdirSync(supplied, { recursive: true, mode: 0o700 });
  const stat = fs.lstatSync(supplied);
  assert(
    stat.isDirectory() &&
      !stat.isSymbolicLink() &&
      stat.uid === process.getuid?.() &&
      (stat.mode & 0o077) === 0,
    `${label} must be an owner-only real directory`,
  );
  const real = fs.realpathSync(supplied);
  assert(real === supplied, `${label} cannot traverse a symbolic link`);
  if (empty)
    assert(fs.readdirSync(real).length === 0, `${label} must be empty`);
  return real;
}
function inside(root, candidate) {
  const relative = path.relative(root, candidate);
  return (
    relative !== "" &&
    relative !== ".." &&
    !relative.startsWith(`..${path.sep}`)
  );
}
function assertOwnerOnlyFile(file, label, { exactMode = null } = {}) {
  const stat = fs.lstatSync(file);
  assert(
    stat.isFile() &&
      !stat.isSymbolicLink() &&
      stat.uid === process.getuid?.() &&
      (stat.mode & 0o077) === 0 &&
      (exactMode === null || (stat.mode & 0o777) === exactMode),
    `${label} must be an owner-only regular non-symlink file${exactMode === null ? "" : ` with mode ${exactMode.toString(8)}`}`,
  );
}
function confinedSupportPath(supportDir, supplied, label) {
  const absolute = path.resolve(supplied);
  assert(
    inside(supportDir, absolute) && path.dirname(absolute) === supportDir,
    `${label} must be a direct child of the P-26 support directory`,
  );
  assert(
    fs.realpathSync(path.dirname(absolute)) === supportDir,
    `${label} parent cannot traverse a symbolic link`,
  );
  return absolute;
}
export function validateP26ProbePaths(options) {
  const normalized = { ...options };
  normalized.rawOutputDir = ownerOnlyDirectory(
    options.rawOutputDir,
    "P-26 raw output",
    { empty: true },
  );
  normalized.supportDir = ownerOnlyDirectory(
    options.supportDir,
    "P-26 support directory",
  );
  normalized.homeDir = ownerOnlyDirectory(
    options.homeDir,
    "P-26 home directory",
  );
  const roots = [
    ["raw output", normalized.rawOutputDir],
    ["support directory", normalized.supportDir],
    ["home directory", normalized.homeDir],
  ];
  for (let left = 0; left < roots.length; left += 1)
    for (let right = left + 1; right < roots.length; right += 1)
      assert(
        !inside(roots[left][1], roots[right][1]) &&
          !inside(roots[right][1], roots[left][1]) &&
          roots[left][1] !== roots[right][1],
        `P-26 ${roots[left][0]} and ${roots[right][0]} must be disjoint`,
      );
  normalized.socketPath = confinedSupportPath(
    normalized.supportDir,
    options.socketPath,
    "P-26 daemon socket",
  );
  normalized.tokenFile = confinedSupportPath(
    normalized.supportDir,
    options.tokenFile,
    "P-26 daemon token",
  );
  normalized.indexDatabase = confinedSupportPath(
    normalized.supportDir,
    options.indexDatabase,
    "P-26 index database",
  );
  assert(
    new Set([
      normalized.socketPath,
      normalized.tokenFile,
      normalized.indexDatabase,
    ]).size === 3,
    "P-26 support paths must be distinct",
  );
  if (fs.existsSync(normalized.socketPath)) {
    const stat = fs.lstatSync(normalized.socketPath);
    assert(
      stat.isSocket() &&
        !stat.isSymbolicLink() &&
        stat.uid === process.getuid?.(),
      "P-26 daemon socket must be an owned Unix socket",
    );
  }
  if (fs.existsSync(normalized.indexDatabase))
    assertOwnerOnlyFile(normalized.indexDatabase, "P-26 index database");
  if (!fs.existsSync(normalized.tokenFile))
    writeExclusive(
      normalized.tokenFile,
      `${crypto.randomBytes(32).toString("hex")}\n`,
    );
  assertOwnerOnlyFile(normalized.tokenFile, "P-26 daemon token", {
    exactMode: 0o600,
  });
  const token = fs.readFileSync(normalized.tokenFile, "utf8").trim();
  assert(
    /^[a-f0-9]{64}$/u.test(token),
    "P-26 daemon token must contain exactly 32 bytes of lowercase hex",
  );
  return normalized;
}
function commandRunner() {
  return {
    run(command, args = [], options = {}) {
      const result = spawnSync(command, args, {
        encoding: "utf8",
        timeout: 30_000,
        maxBuffer: 8 * 1024 * 1024,
        ...options,
      });
      if (result.error) throw result.error;
      return {
        status: result.status,
        stdout: result.stdout ?? "",
        stderr: result.stderr ?? "",
      };
    },
  };
}
function required(runner, command, args, label, options = {}) {
  const result = runner.run(command, args, options);
  assert(
    result.status === 0,
    `${label} failed (${result.status}): ${(result.stderr || result.stdout).trim()}`,
  );
  return result.stdout.trim();
}
function desktopPids(runner) {
  const result = runner.run("pgrep", [
    "-f",
    "^/usr/bin/openburnbar-linux-desktop([[:space:]]|$)",
  ]);
  if (result.status === 1) return [];
  assert(
    result.status === 0,
    `P-26 desktop process query failed: ${(result.stderr || result.stdout).trim()}`,
  );
  return result.stdout
    .trim()
    .split(/\s+/u)
    .filter(Boolean)
    .map(Number)
    .filter(Number.isSafeInteger);
}
async function waitFor(label, operation, timeoutMs = 30_000) {
  const deadline = Date.now() + timeoutMs;
  let lastError;
  while (Date.now() < deadline) {
    try {
      return await operation();
    } catch (error) {
      lastError = error;
      await sleep(250);
    }
  }
  throw new Error(`${label} timed out: ${lastError?.message ?? "unavailable"}`);
}
function probeEnvironment(options) {
  return {
    ...process.env,
    HOME: options.homeDir,
    XDG_CONFIG_HOME: path.join(options.homeDir, ".config"),
    XDG_DATA_HOME: path.join(options.homeDir, ".local/share"),
    OPENBURNBAR_DAEMON_SUPPORT_DIR: options.supportDir,
    OPENBURNBAR_DAEMON_SOCKET_PATH: options.socketPath,
    OPENBURNBAR_DAEMON_SOCKET_AUTH_TOKEN_FILE: options.tokenFile,
    OPENBURNBAR_INDEX_DATABASE_PATH: options.indexDatabase,
  };
}
export function parseP26PackageOwner(environmentId, output) {
  const receipt = String(output).trim();
  if (environmentId.includes("ubuntu")) {
    const owner = receipt.match(
      /^([^:\s]+)(?::[^:\s]+)?:\s+\/etc\/xdg\/autostart\/openburnbar\.desktop$/u,
    )?.[1];
    assert(
      owner === "openburnbar",
      "P-26 Debian package owner is not canonical",
    );
    return { manager: "dpkg", packageName: owner };
  }
  if (environmentId.includes("fedora")) {
    const canonical = /^openburnbar-[^\s]+\.(?:aarch64|noarch|x86_64)$/u.test(
      receipt,
    );
    assert(canonical, "P-26 RPM package owner is not canonical");
    return { manager: "rpm", packageName: "openburnbar" };
  }
  const packageName = receipt.match(
    /^\/etc\/xdg\/autostart\/openburnbar\.desktop is owned by ([^\s]+)\s+[^\s]+$/u,
  )?.[1];
  assert(
    packageName === "openburnbar",
    "P-26 Arch package owner is not canonical",
  );
  return { manager: "pacman", packageName };
}
function packagedAutostart(runner, environmentId) {
  const autostartFd = fs.openSync(AUTOSTART, fs.constants.O_RDONLY | fs.constants.O_NOFOLLOW);
  let bytes;
  try {
    const stat = fs.fstatSync(autostartFd);
    assert(
      stat.isFile() &&
        stat.uid === 0 &&
        (stat.mode & 0o022) === 0,
      "P-26 packaged autostart entry is absent or unsafe",
    );
    bytes = fs.readFileSync(autostartFd);
  } finally {
    fs.closeSync(autostartFd);
  }
  const exec = bytes
    .toString("utf8")
    .match(/^Exec=(.+)$/mu)?.[1]
    ?.trim();
  assert(
    exec === "openburnbar-linux-desktop --background",
    "P-26 packaged autostart does not use tray-first startup",
  );
  const command = environmentId.includes("ubuntu")
    ? ["dpkg-query", ["-S", AUTOSTART]]
    : environmentId.includes("fedora")
      ? ["rpm", ["-qf", AUTOSTART]]
      : ["pacman", ["-Qo", AUTOSTART]];
  const ownership = parseP26PackageOwner(
    environmentId,
    required(runner, command[0], command[1], "P-26 package ownership readback"),
  );
  return {
    path: AUTOSTART,
    exec,
    packageOwned: true,
    ...ownership,
    sha256: crypto.createHash("sha256").update(bytes).digest("hex"),
  };
}
export function readP26ServiceActive(runner) {
  const result = runner.run("systemctl", [
    "--user",
    "is-active",
    "openburnbar-daemon.service",
  ]);
  const state = result.stdout.trim();
  if (result.status === 0 && state === "active") return true;
  if (result.status === 3 && state === "inactive") return false;
  throw new Error(
    `P-26 could not determine user daemon state (${result.status}): ${(result.stderr || result.stdout).trim()}`,
  );
}
function serviceController(runner, options) {
  let child = null;
  let wasActive = false;
  let launchCount = 0;
  const env = probeEnvironment(options);
  const active = () => readP26ServiceActive(runner);
  const stopChild = async () => {
    if (!child) return;
    child.kill("SIGTERM");
    await waitFor("P-26 isolated daemon exit", () => {
      const status = runner.run("kill", ["-0", String(child.pid)]).status;
      assert(status === 1, `isolated daemon exit query failed (${status})`);
      return true;
    });
    child = null;
    if (fs.existsSync(options.socketPath)) {
      const stat = fs.lstatSync(options.socketPath);
      assert(
        stat.isSocket() &&
          !stat.isSymbolicLink() &&
          stat.uid === process.getuid?.(),
        "P-26 refused to remove an unsafe daemon socket",
      );
      fs.rmSync(options.socketPath);
    }
  };
  const launch = async () => {
    assert(
      !fs.existsSync(options.socketPath),
      "P-26 daemon socket is not clean",
    );
    launchCount += 1;
    const log = fs.openSync(
      path.join(options.rawOutputDir, `tray-daemon-${launchCount}.log`),
      "wx",
      0o600,
    );
    try {
      child = spawn(
        DAEMON_LAUNCHER,
        ["--version", `p26-installed-${options.packageVersion}`],
        { env, stdio: ["ignore", log, log] },
      );
      child.unref();
    } finally {
      fs.closeSync(log);
    }
    await waitFor("P-26 isolated daemon socket", () => {
      const stat = fs.existsSync(options.socketPath)
        ? fs.lstatSync(options.socketPath)
        : null;
      assert(
        stat?.isSocket() &&
          !stat.isSymbolicLink() &&
          stat.uid === process.getuid?.() &&
          (stat.mode & 0o077) === 0,
        "daemon socket is absent",
      );
      return true;
    });
  };
  return {
    active,
    async prepare() {
      wasActive = active();
      if (wasActive)
        required(
          runner,
          "systemctl",
          ["--user", "stop", "openburnbar-daemon.service"],
          "P-26 stop normal daemon",
        );
      await launch();
      return wasActive;
    },
    async disconnect() {
      await stopChild();
    },
    async reconnect() {
      await launch();
    },
    async restore() {
      await stopChild();
      if (wasActive)
        required(
          runner,
          "systemctl",
          ["--user", "start", "openburnbar-daemon.service"],
          "P-26 restore normal daemon",
        );
      await waitFor("P-26 daemon service restoration", () => {
        assert(active() === wasActive, "daemon active state is not restored");
        return true;
      });
    },
  };
}
export function parseP26RegisteredItems(text) {
  return [
    ...text.matchAll(
      /'(:[^']+\/(?:org\/kde\/StatusNotifierItem|org\/ayatana\/NotificationItem)[^']*)'/gu,
    ),
  ].map((match) => {
    const slash = match[1].indexOf("/");
    return { service: match[1].slice(0, slash), path: match[1].slice(slash) };
  });
}
export function parseP26MenuLayout(layout) {
  const matches = [
    ...layout.matchAll(/<\((\d+), \{[^)]*?'label': <'([^']+)'>/gu),
  ];
  return matches.map((match, index) => {
    const end = matches[index + 1]?.index ?? layout.length;
    const segment = layout.slice(match.index, end);
    return {
      id: Number(match[1]),
      label: match[2],
      enabled: !/'enabled': <false>/u.test(segment),
    };
  });
}
export function parseP26MenuRevision(layout) {
  const revision = Number(layout.match(/^\(uint32\s+(\d+),/u)?.[1]);
  assert(
    Number.isSafeInteger(revision) && revision >= 0,
    "P-26 DBusMenu revision is invalid",
  );
  return revision;
}
function nativeDriver(runner, options) {
  const env = probeEnvironment(options);
  let app = null;
  let registration = null;
  let windowId = null;
  const run = (command, args, label, extra = {}) =>
    required(runner, command, args, label, { env, ...extra });
  const appAlive = () =>
    app && runner.run("kill", ["-0", String(app.pid)]).status === 0;
  const visibleWindow = () => {
    if (!app) return null;
    const result = runner.run(
      "xdotool",
      [
        "search",
        "--onlyvisible",
        "--pid",
        String(app.pid),
        "--name",
        "OpenBurnBar",
      ],
      { env },
    );
    return result.status === 0 ? result.stdout.trim().split(/\s+/u)[0] : null;
  };
  const queryMenu = () => {
    assert(registration, "tray registration is unavailable");
    const property = run(
      "gdbus",
      [
        "call",
        "--session",
        "--dest",
        registration.service,
        "--object-path",
        registration.path,
        "--method",
        "org.freedesktop.DBus.Properties.Get",
        "org.kde.StatusNotifierItem",
        "Menu",
      ],
      "P-26 tray menu property",
    );
    const menuPath = property.match(/'([^']+)'/u)?.[1];
    assert(menuPath?.startsWith("/"), "P-26 tray menu path is invalid");
    const layout = run(
      "gdbus",
      [
        "call",
        "--session",
        "--dest",
        registration.service,
        "--object-path",
        menuPath,
        "--method",
        "com.canonical.dbusmenu.GetLayout",
        "0",
        "100",
        "[]",
      ],
      "P-26 tray menu layout",
    );
    const items = parseP26MenuLayout(layout);
    assert(items.length >= 11, "P-26 native menu is incomplete");
    return { menuPath, items, revision: parseP26MenuRevision(layout) };
  };
  const findRegistration = async (previous = null) =>
    waitFor("P-26 StatusNotifier registration", () => {
      const registered = run(
        "gdbus",
        [
          "call",
          "--session",
          "--dest",
          "org.kde.StatusNotifierWatcher",
          "--object-path",
          "/StatusNotifierWatcher",
          "--method",
          "org.freedesktop.DBus.Properties.Get",
          "org.kde.StatusNotifierWatcher",
          "RegisteredStatusNotifierItems",
        ],
        "P-26 StatusNotifier watcher",
      );
      for (const candidate of parseP26RegisteredItems(registered)) {
        const tooltip = runner.run(
          "gdbus",
          [
            "call",
            "--session",
            "--dest",
            candidate.service,
            "--object-path",
            candidate.path,
            "--method",
            "org.freedesktop.DBus.Properties.Get",
            "org.kde.StatusNotifierItem",
            "ToolTip",
          ],
          { env },
        );
        if (tooltip.status === 0 && tooltip.stdout.includes("OpenBurnBar")) {
          assert(
            !previous || `${candidate.service}${candidate.path}` !== previous,
            "tray registration did not rotate after relaunch",
          );
          registration = candidate;
          return candidate;
        }
      }
      throw new Error("OpenBurnBar tray item is not registered");
    });
  return {
    async launchBackground() {
      const stdout = fs.openSync(
        path.join(options.rawOutputDir, `tray-app-${Date.now()}.stdout.log`),
        "wx",
        0o600,
      );
      const stderr = fs.openSync(
        path.join(options.rawOutputDir, `tray-app-${Date.now()}.stderr.log`),
        "wx",
        0o600,
      );
      app = spawn(DESKTOP, ["--background"], {
        env,
        stdio: ["ignore", stdout, stderr],
      });
      app.unref();
      fs.closeSync(stdout);
      fs.closeSync(stderr);
      await waitFor("P-26 background process", () => {
        assert(appAlive(), "desktop process exited");
        return true;
      });
      const found = await findRegistration();
      await sleep(750);
      assert(!visibleWindow(), "background launch exposed a visible window");
      return { pid: app.pid, registration: found };
    },
    async tray({ expectedDaemon = "connected", afterRevision = null } = {}) {
      const tooltip = run(
        "gdbus",
        [
          "call",
          "--session",
          "--dest",
          registration.service,
          "--object-path",
          registration.path,
          "--method",
          "org.freedesktop.DBus.Properties.Get",
          "org.kde.StatusNotifierItem",
          "ToolTip",
        ],
        "P-26 tray tooltip",
      );
      assert(
        tooltip.includes("OpenBurnBar") &&
          tooltip.includes("Linux desktop assistant"),
        "P-26 tray tooltip is not canonical",
      );
      const menu = await waitFor(
        "P-26 live tray state",
        () => {
          const snapshot = queryMenu();
          const values = snapshot.items.map((item) => item.label);
          if (afterRevision !== null)
            assert(
              snapshot.revision > afterRevision,
              `DBusMenu revision ${snapshot.revision} did not advance beyond ${afterRevision}`,
            );
          assert(
            values.some((label) =>
              expectedDaemon === "connected"
                ? /^Daemon: connected - \S.+/u.test(label)
                : label === "Daemon: offline",
            ),
            `daemon status is not ${expectedDaemon}`,
          );
          assert(
            values.some((label) =>
              /^Recent usage: (?!checking|unavailable)/u.test(label),
            ),
            "usage status is not live",
          );
          assert(
            values.some((label) => /^Updates: (?!checking)/u.test(label)),
            "update status is not resolved",
          );
          return snapshot;
        },
        45_000,
      );
      return {
        protocol: registration.path.includes("ayatana")
          ? "AppIndicator"
          : "StatusNotifierItem",
        service: registration.service,
        path: registration.path,
        menuPath: menu.menuPath,
        revision: menu.revision,
        tooltip: "OpenBurnBar — Linux desktop assistant",
        items: menu.items,
      };
    },
    async action(label) {
      const menu = queryMenu();
      const item = menu.items.find((row) => row.label === label);
      assert(
        item?.enabled === true,
        `P-26 tray action ${label} is missing or disabled`,
      );
      const result = runner.run(
        "dbus-send",
        [
          "--session",
          `--dest=${registration.service}`,
          "--type=method_call",
          "--print-reply",
          menu.menuPath,
          "com.canonical.dbusmenu.Event",
          `int32:${item.id}`,
          "string:clicked",
          "variant:string:",
          "uint32:0",
        ],
        { env },
      );
      assert(
        result.status === 0 && result.stdout.includes("method return"),
        `P-26 tray action ${label} failed`,
      );
      return { menuId: item.id, dbusReply: result.stdout.trim() };
    },
    async route(route, accessibleName) {
      windowId = await waitFor(`P-26 ${route} window`, () => {
        const found = visibleWindow();
        assert(found, "route window is not visible");
        return found;
      });
      run(
        "xdotool",
        ["windowactivate", "--sync", windowId],
        `P-26 activate ${route}`,
      );
      const output = path.join(
        options.rawOutputDir,
        `tray-${route}-atspi.json`,
      );
      await waitFor(`P-26 active ${route} heading`, () => {
        fs.rmSync(output, { force: true });
        run(
          "python3",
          [
            path.join(ROOT, "scripts/linux-port/capture-atspi-tree.py"),
            "--application",
            "OpenBurnBar",
            "--route",
            route,
            "--expected-name",
            accessibleName,
            "--output",
            output,
          ],
          `P-26 ${route} AT-SPI`,
        );
        const tree = JSON.parse(fs.readFileSync(output, "utf8"));
        assert(
          tree.namedSamples?.some(
            (node) => node?.role === "heading" && node?.name === accessibleName,
          ),
          `${accessibleName} is not the active route heading`,
        );
        return true;
      });
      fs.chmodSync(output, 0o600);
      run(
        "scrot",
        [path.join(options.rawOutputDir, `tray-${route}.png`)],
        `P-26 ${route} screenshot`,
      );
      fs.chmodSync(path.join(options.rawOutputDir, `tray-${route}.png`), 0o600);
      return { visible: true, appPid: app.pid };
    },
    screenshotBackground() {
      run(
        "scrot",
        [path.join(options.rawOutputDir, "tray-background.png")],
        "P-26 background screenshot",
      );
      fs.chmodSync(
        path.join(options.rawOutputDir, "tray-background.png"),
        0o600,
      );
    },
    async hide() {
      assert(windowId, "P-26 cannot hide an unknown window");
      run("xdotool", ["windowunmap", windowId], "P-26 hide dashboard");
      await waitFor("P-26 hidden window", () => {
        assert(!visibleWindow(), "window remains visible");
        return true;
      });
      return appAlive();
    },
    async reopenedSameProcess(pid) {
      await waitFor("P-26 tray reopen", () => {
        assert(visibleWindow(), "window is not reopened");
        return true;
      });
      return appAlive() && app.pid === pid;
    },
    async keyboardFocus() {
      const current = visibleWindow();
      assert(current, "P-26 keyboard focus requires a visible window");
      run(
        "xdotool",
        ["windowactivate", "--sync", current],
        "P-26 keyboard window focus",
      );
      run("xdotool", ["key", "--clearmodifiers", "Tab"], "P-26 keyboard tab");
      const output = path.join(
        options.rawOutputDir,
        "tray-keyboard-focus-atspi.json",
      );
      run(
        "python3",
        [
          path.join(ROOT, "scripts/linux-port/capture-atspi-tree.py"),
          "--application",
          "OpenBurnBar",
          "--mode",
          "focus",
          "--output",
          output,
        ],
        "P-26 focused AT-SPI node",
      );
      const document = JSON.parse(fs.readFileSync(output, "utf8"));
      fs.rmSync(output);
      return JSON.stringify(document).length > 20;
    },
    health() {
      const result = runner.run(DESKTOP, ["--daemon-health"], { env });
      assert(
        [0, 1].includes(result.status),
        `P-26 daemon health failed (${result.status}): ${(result.stderr || result.stdout).trim()}`,
      );
      let health;
      try {
        health = JSON.parse(result.stdout);
      } catch {
        throw new Error("P-26 daemon health did not return JSON");
      }
      if (result.status === 0 && health?.ok === true) return "connected";
      if (result.status === 1 && health?.ok === false) return "disconnected";
      throw new Error("P-26 daemon health status and payload disagree");
    },
    alive() {
      return appAlive();
    },
    async waitTerminated() {
      await waitFor("P-26 tray quit", () => {
        assert(!appAlive(), "desktop process is still active");
        return true;
      });
      app = null;
      registration = null;
      windowId = null;
    },
    registrationIdentity() {
      return `${registration.service}${registration.path}`;
    },
    async relaunch(previous) {
      const launched = await this.launchBackground();
      assert(
        this.registrationIdentity() !== previous,
        "P-26 tray registration was replayed",
      );
      return launched;
    },
    async terminate() {
      if (!app) return;
      app.kill("SIGTERM");
      await this.waitTerminated();
    },
  };
}
function stampFactory(clock) {
  let last = -Infinity;
  return () => {
    let value = clock().getTime();
    if (value <= last) value = last + 1;
    last = value;
    return new Date(value).toISOString();
  };
}

export async function runP26NativeTrayProbes(options, dependencies = {}) {
  options = { ...options };
  const platform = dependencies.platform ?? process.platform;
  const runner = dependencies.runner ?? commandRunner();
  const installedVerifier =
    dependencies.installedVerifier ?? verifyInstalledCandidate;
  const clock = dependencies.clock ?? (() => new Date());
  const stamp = stampFactory(clock);
  assert(platform === "linux", "P-26 native tray probe requires Linux");
  const desktopSession =
    dependencies.desktopSession ??
    (Boolean(process.env.DISPLAY) &&
      Boolean(process.env.DBUS_SESSION_BUS_ADDRESS) &&
      String(process.env.XDG_SESSION_TYPE ?? "").toLowerCase() === "x11");
  assert(
    desktopSession,
    "P-26 native tray probe requires a live X11 DISPLAY and desktop D-Bus session",
  );
  options = validateP26ProbePaths(options);
  installedVerifier(options);
  (
    dependencies.executableVerifier ??
    (() => {
      const stat = fs.lstatSync(DESKTOP);
      assert(
        stat.isFile() &&
          !stat.isSymbolicLink() &&
          stat.uid === 0 &&
          (stat.mode & 0o022) === 0 &&
          stat.mode & 0o111,
        "P-26 installed desktop executable is invalid",
      );
    })
  )();
  const beforePids = (
    dependencies.desktopProcessIDs ?? (() => desktopPids(runner))
  )();
  assert(
    beforePids.length === 0,
    "P-26 refuses to disturb an existing OpenBurnBar desktop process",
  );
  const marker =
    dependencies.marker ?? `p26-${crypto.randomBytes(8).toString("hex")}`;
  const autostart =
    dependencies.autostart ?? packagedAutostart(runner, options.environmentId);
  const daemon = dependencies.daemon ?? serviceController(runner, options);
  const driver = dependencies.driver ?? nativeDriver(runner, options);
  const startedAt = stamp();
  const actions = [];
  const routes = [];
  let daemonWasActive = false;
  let primaryPid = null;
  let relaunchPid = null;
  let initialRegistration = null;
  let initialMenu;
  let refreshedMenu;
  let disconnectedMenu;
  let reconnectedMenu;
  let initialMenuRevision;
  let refreshedMenuRevision;
  let disconnectedMenuRevision;
  let reconnectedMenuRevision;
  let persistence;
  let daemonState;
  let keyboardFocusObserved = false;
  let completed = false;
  let daemonCleanupRequired = false;
  let primaryError = null;
  try {
    daemonCleanupRequired = true;
    daemonWasActive = await daemon.prepare();
    const launch = await driver.launchBackground();
    primaryPid = launch.pid;
    initialRegistration = driver.registrationIdentity();
    driver.screenshotBackground();
    const tray = await driver.tray();
    initialMenu = tray.items;
    initialMenuRevision = tray.revision;
    daemonState = {
      beforeHealth: driver.health(),
      beforeReconnectHealth: null,
      afterReconnectHealth: null,
      usageState: initialMenu.find((item) =>
        item.label.startsWith("Recent usage: "),
      )?.label,
      updateState: initialMenu.find((item) =>
        item.label.startsWith("Updates: "),
      )?.label,
    };
    for (const [route, label, accessibleName] of ROUTES) {
      const receipt = await driver.action(label);
      actions.push({ phase: route, at: stamp(), label, ...receipt });
      const view = await driver.route(route, accessibleName);
      routes.push({
        route,
        at: stamp(),
        accessibleName,
        manifestSha256: options.manifestSha256,
        ...view,
      });
    }
    keyboardFocusObserved = await driver.keyboardFocus();
    const processAliveAfterHide = await driver.hide();
    const reopen = await driver.action("Open dashboard");
    actions.push({
      phase: "reopen",
      at: stamp(),
      label: "Open dashboard",
      ...reopen,
    });
    const reopenSamePid = await driver.reopenedSameProcess(primaryPid);
    const refresh = await driver.action("Refresh status");
    actions.push({
      phase: "refresh",
      at: stamp(),
      label: "Refresh status",
      ...refresh,
    });
    const refreshedTray = await driver.tray({
      expectedDaemon: "connected",
      afterRevision: initialMenuRevision,
    });
    refreshedMenu = refreshedTray.items;
    refreshedMenuRevision = refreshedTray.revision;
    await daemon.disconnect();
    daemonState.beforeReconnectHealth = driver.health();
    assert(
      daemonState.beforeReconnectHealth === "disconnected",
      "P-26 daemon did not become disconnected before reconnect",
    );
    const disconnectedTray = await driver.tray({
      expectedDaemon: "offline",
      afterRevision: refreshedMenuRevision,
    });
    disconnectedMenu = disconnectedTray.items;
    disconnectedMenuRevision = disconnectedTray.revision;
    const reconnect = await driver.action("Reconnect daemon");
    actions.push({
      phase: "reconnect",
      at: stamp(),
      label: "Reconnect daemon",
      ...reconnect,
    });
    await daemon.reconnect();
    daemonState.afterReconnectHealth = await waitFor(
      "P-26 reconnect health",
      () => {
        assert(driver.health() === "connected", "daemon is not connected");
        return "connected";
      },
    );
    const reconnectedTray = await driver.tray({
      expectedDaemon: "connected",
      afterRevision: disconnectedMenuRevision,
    });
    reconnectedMenu = reconnectedTray.items;
    reconnectedMenuRevision = reconnectedTray.revision;
    const quit = await driver.action("Quit OpenBurnBar");
    actions.push({
      phase: "quit",
      at: stamp(),
      label: "Quit OpenBurnBar",
      ...quit,
    });
    await driver.waitTerminated();
    const relaunched = await driver.relaunch(initialRegistration);
    relaunchPid = relaunched.pid;
    const relaunchNoVisibleWindow = true;
    const trayReregistered = Boolean(driver.registrationIdentity());
    const relaunchRegistration = driver.registrationIdentity();
    const distinctRegistration =
      driver.registrationIdentity() !== initialRegistration;
    await driver.terminate();
    persistence = {
      windowHideLeftProcessAlive: processAliveAfterHide,
      reopenSamePid,
      quitTerminated: true,
      relaunchPid,
      relaunchRegistration,
      relaunchNoVisibleWindow,
      trayReregistered,
      distinctRegistration,
      relaunchTerminated: !driver.alive(),
    };
    const finalTray = tray;
    await daemon.restore();
    daemonCleanupRequired = false;
    const afterPids = (
      dependencies.desktopProcessIDs ?? (() => desktopPids(runner))
    )();
    const daemonActiveAfter = daemon.active();
    const endedAt = stamp();
    writeJson(path.join(options.rawOutputDir, "tray-marker.json"), {
      marker,
      installedExecutable: DESKTOP,
      autostart,
      safety: {
        fixtureMode: false,
        isolatedDaemon: true,
        preexistingDesktopProcesses: beforePids.length,
        daemonServiceRestored: daemonActiveAfter === daemonWasActive,
        desktopProcessesRestored: afterPids.length === beforePids.length,
      },
    });
    writeJson(path.join(options.rawOutputDir, "tray-native-transcript.json"), {
      producer: "openburnbar-p26-installed-tray-probe-v1",
      marker,
      startedAt,
      endedAt,
      background: {
        pid: primaryPid,
        command: `${DESKTOP} --background`,
        noVisibleWindow: true,
        processAlive: true,
        trayRegistered: true,
      },
      tray: {
        protocol: finalTray.protocol,
        service: finalTray.service,
        path: finalTray.path,
        menuPath: finalTray.menuPath,
        tooltip: finalTray.tooltip,
        initialMenu,
        initialMenuRevision,
        refreshedMenu,
        refreshedMenuRevision,
        disconnectedMenu,
        disconnectedMenuRevision,
        reconnectedMenu,
        reconnectedMenuRevision,
      },
      actions,
      routes,
      accessibility: {
        atspiApplication: "OpenBurnBar",
        keyboardFocusObserved,
        semanticMenuItems: new Set(actions.map((item) => item.label)).size,
        menuItemsEnabled: actions.every((action) =>
          initialMenu.some(
            (item) => item.label === action.label && item.enabled,
          ),
        ),
      },
      daemon: daemonState,
      persistence,
      restoration: {
        daemonWasActive,
        daemonActiveAfter,
        desktopPidsBefore: beforePids,
        desktopPidsAfter: afterPids,
      },
    });
    completed = true;
    return { output: options.rawOutputDir, marker, primaryPid, relaunchPid };
  } catch (error) {
    primaryError = error;
  } finally {
    if (!completed) {
      const cleanupErrors = [];
      try {
        await driver.terminate();
      } catch (error) {
        cleanupErrors.push(error);
      }
      if (daemonCleanupRequired) {
        try {
          await daemon.restore();
        } catch (error) {
          cleanupErrors.push(error);
        }
      }
      if (cleanupErrors.length > 0)
        primaryError = new AggregateError(
          [primaryError, ...cleanupErrors].filter(Boolean),
          "P-26 native tray probe failed and cleanup was incomplete",
          { cause: primaryError ?? undefined },
        );
    }
  }
  if (primaryError) throw primaryError;
  throw new Error("P-26 native tray probe ended without a result");
}

export function parseP26Arguments(argv) {
  const flags = [
    "--raw-output-dir",
    "--support-dir",
    "--home-dir",
    "--socket-path",
    "--token-file",
    "--index-database",
    "--environment",
    "--target-head",
    "--candidate-run-id",
    "--candidate-artifact-digest",
    "--package-version",
    "--manifest-sha256",
    "--manifest-signature-sha256",
    "--compositor",
  ];
  const values = new Map();
  for (let index = 0; index < argv.length; index += 2) {
    if (
      !flags.includes(argv[index]) ||
      values.has(argv[index]) ||
      argv[index + 1] === undefined
    )
      throw new Error(`invalid argument: ${argv[index] ?? "<missing>"}`);
    values.set(argv[index], argv[index + 1]);
  }
  for (const flag of flags)
    if (!values.has(flag)) throw new Error(`${flag} is required`);
  return {
    rawOutputDir: values.get("--raw-output-dir"),
    supportDir: values.get("--support-dir"),
    homeDir: values.get("--home-dir"),
    socketPath: values.get("--socket-path"),
    tokenFile: values.get("--token-file"),
    indexDatabase: values.get("--index-database"),
    environmentId: values.get("--environment"),
    targetHead: values.get("--target-head"),
    candidateRunId: values.get("--candidate-run-id"),
    candidateArtifactDigest: values.get("--candidate-artifact-digest"),
    packageVersion: values.get("--package-version"),
    manifestSha256: values.get("--manifest-sha256"),
    manifestSignatureSha256: values.get("--manifest-signature-sha256"),
    compositor: values.get("--compositor"),
  };
}

if (
  process.argv[1] &&
  path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)
) {
  try {
    process.stdout.write(
      `${JSON.stringify(await runP26NativeTrayProbes(parseP26Arguments(process.argv.slice(2))), null, 2)}\n`,
    );
  } catch (error) {
    process.stderr.write(`P-26 native tray probe failed: ${error.message}\n`);
    process.exitCode = 1;
  }
}
