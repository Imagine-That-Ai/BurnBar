#!/usr/bin/env node
import crypto from "node:crypto";
import fs from "node:fs";
import http from "node:http";
import net from "node:net";
import path from "node:path";
import { spawn, spawnSync } from "node:child_process";
import { fileURLToPath } from "node:url";
import { verifyInstalledCandidate } from "./run-p08-mercury-media-session.mjs";

const ROOT = path.resolve(
  path.dirname(fileURLToPath(import.meta.url)),
  "../..",
);
const DESKTOP = "/usr/bin/openburnbar-linux-desktop";
const DAEMON = "/usr/bin/openburnbar-daemon";
const AUTOSTART = "/etc/xdg/autostart/openburnbar.desktop";
const CONTROL = path.join(ROOT, "scripts/linux-port/p27-atspi-control.py");
const NOTIFICATION_ACTION = path.join(
  ROOT,
  "scripts/linux-port/p27-notification-action.py",
);
const WEBDRIVER = "tauri-driver";
const HOSTILE_LINKS = [
  "https://openburnbar.invalid/oauth/callback?code=stolen&state=x",
  "openburnbar://oauth/callback?code=ok&state=missing-extra",
  "openburnbar://membership?invite=../escape",
  "openburnbar://providers?provider=openai&model=gpt-5&admin=true",
  "openburnbar://providers?provider=&model=gpt-5",
];

function assert(value, message) {
  if (!value) throw new Error(message);
}
function run(command, args = [], options = {}) {
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
}
function required(command, args, label, options = {}) {
  const result = run(command, args, options);
  assert(
    result.status === 0,
    `${label} failed (${result.status}): ${(result.stderr || result.stdout).trim()}`,
  );
  return result.stdout.trim();
}
function ownerDirectory(candidate, label, empty = false) {
  const absolute = path.resolve(candidate);
  let ancestor = absolute;
  while (!fs.existsSync(ancestor)) ancestor = path.dirname(ancestor);
  assert(
    fs.realpathSync(ancestor) === ancestor,
    `${label} cannot traverse a symbolic link`,
  );
  fs.mkdirSync(absolute, { recursive: true, mode: 0o700 });
  const stat = fs.lstatSync(absolute);
  assert(
    stat.isDirectory() &&
      !stat.isSymbolicLink() &&
      stat.uid === process.getuid?.() &&
      (stat.mode & 0o077) === 0,
    `${label} must be an owned owner-only real directory`,
  );
  assert(
    fs.realpathSync(absolute) === absolute,
    `${label} cannot traverse a symbolic link`,
  );
  if (empty)
    assert(fs.readdirSync(absolute).length === 0, `${label} must be empty`);
  return absolute;
}
function desktopPids() {
  const result = run("pgrep", [
    "-f",
    "^/usr/bin/openburnbar-linux-desktop([[:space:]]|$)",
  ]);
  if (result.status === 1) return [];
  assert(result.status === 0, "P-27 could not inspect desktop processes");
  return result.stdout
    .trim()
    .split(/\s+/u)
    .filter(Boolean)
    .map(Number)
    .filter(Number.isSafeInteger)
    .sort((a, b) => a - b);
}
function daemonActive() {
  const result = run("systemctl", [
    "--user",
    "is-active",
    "openburnbar-daemon.service",
  ]);
  if (result.status === 0 && result.stdout.trim() === "active") return true;
  if (result.status === 3 && result.stdout.trim() === "inactive") return false;
  throw new Error(`P-27 could not determine daemon state (${result.status})`);
}
function packageOwner(environmentId, file) {
  const command = environmentId.includes("ubuntu")
    ? ["dpkg-query", ["-S", file]]
    : environmentId.includes("fedora")
      ? ["rpm", ["-qf", file]]
      : ["pacman", ["-Qo", file]];
  const output = required(
    command[0],
    command[1],
    `P-27 package ownership for ${file}`,
  );
  return parseP27PackageOwner(environmentId, file, output);
}
export function parseP27PackageOwner(environmentId, file, output) {
  const manager = environmentId.includes("ubuntu")
    ? "dpkg"
    : environmentId.includes("fedora")
      ? "rpm"
      : "pacman";
  const expectedName = manager === "pacman" ? "openburnbar" : "open-burn-bar";
  const packageName =
    manager === "dpkg"
      ? output.match(/^([^:\s]+)(?::[^:\s]+)?:\s+/u)?.[1]
      : manager === "rpm"
        ? output.match(/^(open-burn-bar)-[0-9]/u)?.[1]
        : output.match(/ is owned by ([^\s]+)\s/u)?.[1];
  assert(
    packageName === expectedName,
    `P-27 ${file} is owned by a substitute package`,
  );
  return { manager, packageName };
}
function installedIdentity(options) {
  for (const file of [DESKTOP, DAEMON, AUTOSTART]) {
    const stat = fs.lstatSync(file);
    assert(
      stat.isFile() &&
        !stat.isSymbolicLink() &&
        stat.uid === 0 &&
        (stat.mode & 0o022) === 0,
      `P-27 installed file is unsafe: ${file}`,
    );
  }
  const owners = [DESKTOP, DAEMON, AUTOSTART].map((file) =>
    packageOwner(options.environmentId, file),
  );
  assert(
    new Set(owners.map((value) => JSON.stringify(value))).size === 1,
    "P-27 installed files do not share a canonical package owner",
  );
  return {
    packageManager: owners[0].manager,
    packageName: owners[0].packageName,
    packageOwned: true,
  };
}
function autostartState() {
  const bytes = fs.readFileSync(AUTOSTART);
  const exec = bytes
    .toString("utf8")
    .match(/^Exec=(.+)$/mu)?.[1]
    ?.trim();
  assert(
    exec === "/usr/bin/openburnbar-linux-desktop --background",
    "P-27 packaged autostart Exec is not canonical",
  );
  return {
    path: AUTOSTART,
    exec,
    enabled: true,
    ownedByPackage: true,
    sha256: crypto.createHash("sha256").update(bytes).digest("hex"),
  };
}
function runtimeFiles(options) {
  const directory = path.join(options.runtimeDir, "openburnbar");
  if (!fs.existsSync(directory)) return [];
  const stat = fs.lstatSync(directory);
  assert(
    stat.isDirectory() &&
      !stat.isSymbolicLink() &&
      stat.uid === process.getuid?.(),
    "P-27 single-instance directory is unsafe",
  );
  return fs.readdirSync(directory).sort();
}
function validateProductNotification(result, kind, marker) {
  const route = kind === "reply" ? "chat" : "overview";
  assert(
    result?.adapter?.actionsSupported === true &&
      result.adapter.capabilityCommand === "native_notification_capabilities" &&
      result.adapter.deliveryCommand === "native_notification_show",
    "P-27 product adapter or actionable notification server is unsupported",
  );
  assert(
    result?.action?.action === kind &&
      result.action.route === route &&
      result.action.notificationId === `${marker}-${kind}` &&
      result.action.delivered === true &&
      result.action.serverActionObserved === true &&
      result.action.productEventObserved === true &&
      result.action.uiOutcomeObserved === true,
    `P-27 ${kind} notification did not complete the server-to-product UI path`,
  );
}
function screenshot(file) {
  for (const [command, args] of [
    ["gnome-screenshot", ["-f", file]],
    ["spectacle", ["-b", "-n", "-o", file]],
    ["grim", [file]],
    ["import", ["-window", "root", file]],
  ]) {
    const result = run(command, args);
    if (result.status === 0 && fs.existsSync(file)) {
      fs.chmodSync(file, 0o600);
      return;
    }
  }
  throw new Error("P-27 could not capture a live desktop screenshot");
}
async function waitFor(label, operation, timeout = 30_000, interval = 250) {
  const deadline = Date.now() + timeout;
  let last;
  while (Date.now() < deadline) {
    try {
      return await operation();
    } catch (error) {
      last = error;
      await new Promise((resolve) => setTimeout(resolve, interval));
    }
  }
  throw new Error(`${label} timed out: ${last?.message ?? "unavailable"}`);
}

function safeJson(value, label) {
  try {
    return JSON.parse(value);
  } catch {
    throw new Error(`${label} returned invalid JSON`);
  }
}

async function reserveLoopbackPort() {
  return new Promise((resolve, reject) => {
    const server = net.createServer();
    server.unref();
    server.once("error", reject);
    server.listen(0, "127.0.0.1", () => {
      const address = server.address();
      const port = typeof address === "object" && address ? address.port : 0;
      server.close((error) => {
        if (error) reject(error);
        else if (!Number.isSafeInteger(port) || port <= 0)
          reject(new Error("P-27 could not reserve a WebDriver port"));
        else resolve(port);
      });
    });
  });
}

async function jsonRequest(baseURL, method, endpoint, body = undefined) {
  const response = await fetch(new URL(endpoint, baseURL), {
    method,
    headers:
      body === undefined ? undefined : { "content-type": "application/json" },
    body: body === undefined ? undefined : JSON.stringify(body),
    signal: AbortSignal.timeout(30_000),
  });
  const text = await response.text();
  const parsed = text ? safeJson(text, `P-27 WebDriver ${endpoint}`) : null;
  if (!response.ok)
    throw new Error(
      `P-27 WebDriver ${method} ${endpoint} failed (${response.status}): ${text}`,
    );
  return parsed?.value ?? parsed;
}

export function parseNotificationServerInformation(output) {
  const values = [...String(output).matchAll(/'([^']*)'/gu)].map((match) =>
    match[1].trim(),
  );
  assert(
    values.length >= 4,
    "P-27 notification server identity is unavailable",
  );
  const [serverName, serverVendor, serverVersion] = values;
  assert(
    [serverName, serverVendor, serverVersion].every(Boolean),
    "P-27 notification server identity is incomplete",
  );
  return { serverName, serverVendor, serverVersion };
}

export function validateOAuthAuthorizationURL(raw) {
  const authorization = new URL(raw);
  assert(
    authorization.protocol === "https:" &&
      authorization.hostname === "accounts.google.com" &&
      authorization.pathname === "/o/oauth2/v2/auth" &&
      authorization.username === "" &&
      authorization.password === "" &&
      ["", "443"].includes(authorization.port),
    "P-27 OAuth authorization origin is invalid",
  );
  const state = authorization.searchParams.getAll("state");
  const redirects = authorization.searchParams.getAll("redirect_uri");
  assert(
    state.length === 1 && /^[A-Za-z0-9_-]{43}$/u.test(state[0]),
    "P-27 OAuth state is absent or not high entropy",
  );
  assert(redirects.length === 1, "P-27 OAuth redirect is ambiguous");
  const redirect = new URL(redirects[0]);
  assert(
    redirect.protocol === "http:" &&
      redirect.hostname === "127.0.0.1" &&
      Number(redirect.port) >= 1024 &&
      redirect.pathname === "/callback" &&
      redirect.search === "" &&
      redirect.hash === "",
    "P-27 OAuth redirect is not an active loopback endpoint",
  );
  return { authorization, redirect, state: state[0] };
}

async function callbackStatus(url) {
  return new Promise((resolve, reject) => {
    const request = http.get(url, { timeout: 5_000 }, (response) => {
      response.resume();
      response.once("end", () => resolve(response.statusCode ?? 0));
    });
    request.once("timeout", () =>
      request.destroy(new Error("callback timeout")),
    );
    request.once("error", (error) => {
      if (["ECONNREFUSED", "ECONNRESET", "EPIPE"].includes(error.code))
        resolve(0);
      else reject(error);
    });
  });
}

function installBrowserCapture(home, env) {
  const bin = ownerDirectory(
    path.join(home, ".p27-browser-bin"),
    "P-27 browser capture bin",
    true,
  );
  const capture = path.join(home, ".p27-oauth-url");
  const script = path.join(bin, "openburnbar-p27-browser-capture");
  fs.writeFileSync(
    script,
    '#!/bin/sh\nset -eu\numask 077\nfor value in "$@"; do\n  case "$value" in\n    https://accounts.google.com/*) printf \'%s\\n\' "$value" >"$OPENBURNBAR_P27_AUTH_URL_CAPTURE"; exit 0 ;;\n  esac\ndone\nexit 64\n',
    { flag: "wx", mode: 0o700 },
  );
  for (const name of [
    "xdg-open",
    "gio",
    "gnome-open",
    "kde-open",
    "sensible-browser",
  ])
    fs.symlinkSync(script, path.join(bin, name));
  env.PATH = `${bin}:${env.PATH ?? "/usr/bin:/bin"}`;
  env.BROWSER = script;
  env.OPENBURNBAR_P27_AUTH_URL_CAPTURE = capture;
  return { capture };
}

function installedDaemonConnection() {
  const uid = process.getuid?.();
  const runtimeRoot = process.env.XDG_RUNTIME_DIR || `/run/user/${uid}`;
  const dataRoot =
    process.env.XDG_DATA_HOME || path.join(process.env.HOME, ".local/share");
  const socketPath = path.join(runtimeRoot, "openburnbar/daemon.sock");
  const tokenFile = path.join(dataRoot, "openburnbar/daemon-socket-auth-token");
  const socket = fs.lstatSync(socketPath);
  const token = fs.lstatSync(tokenFile);
  assert(
    socket.isSocket() && !socket.isSymbolicLink() && socket.uid === uid,
    "P-27 installed daemon socket is unsafe",
  );
  assert(
    token.isFile() &&
      !token.isSymbolicLink() &&
      token.uid === uid &&
      (token.mode & 0o077) === 0,
    "P-27 installed daemon token is unsafe",
  );
  return { socketPath, tokenFile };
}

function webdriverController(env) {
  let processHandle = null;
  let sessionId = null;
  let baseURL = null;
  return {
    async start(marker) {
      required("which", ["tauri-driver"], "P-27 Linux WebDriver prerequisites", { env });
      required("which", ["WebKitWebDriver"], "P-27 Linux WebDriver prerequisites", { env });
      const port = await reserveLoopbackPort();
      baseURL = `http://127.0.0.1:${port}/`;
      processHandle = spawn(WEBDRIVER, ["--port", String(port)], {
        env,
        stdio: "ignore",
      });
      processHandle.unref();
      await waitFor("P-27 tauri-driver readiness", async () => {
        const status = await jsonRequest(baseURL, "GET", "/status");
        assert(status?.ready !== false, "tauri-driver is not ready");
        return true;
      });
      const sessionPromise = jsonRequest(baseURL, "POST", "/session", {
        capabilities: {
          alwaysMatch: {
            browserName: "wry",
            "tauri:options": { application: DESKTOP },
          },
        },
      });
      const singleInstanceSocket = path.join(
        env.XDG_RUNTIME_DIR,
        "openburnbar/openburnbar-linux-desktop.sock",
      );
      await waitFor(
        "P-27 cold single-instance listener start",
        () => {
          assert(desktopPids().length === 1, "cold desktop owner is absent");
          assert(
            fs.existsSync(singleInstanceSocket) &&
              fs.lstatSync(singleInstanceSocket).isSocket(),
            "cold single-instance listener is absent",
          );
          return true;
        },
        10_000,
        5,
      );
      const coldNotificationId = `${marker}-cold-reply`;
      const coldForward = run(
        DESKTOP,
        [
          "--notification-action=reply",
          `--notification-payload=${JSON.stringify({ notificationId: coldNotificationId })}`,
        ],
        { env },
      );
      assert(
        coldForward.status === 0,
        `P-27 cold notification forwarding failed: ${coldForward.stderr.trim()}`,
      );
      const session = await sessionPromise;
      sessionId = session?.sessionId;
      assert(
        typeof sessionId === "string" && sessionId,
        "P-27 WebDriver session is absent",
      );
      await jsonRequest(baseURL, "POST", `/session/${sessionId}/timeouts`, {
        script: 30_000,
      });
      await waitFor("P-27 cold notification renderer drain", async () => {
        const state = await this.bodyState();
        assert(
          /chat|message|composer/iu.test(
            `${state?.text ?? ""} ${state?.focused ?? ""}`,
          ),
          "cold Reply did not reach Chat",
        );
        return true;
      });
      const firstRoute = await this.invoke("forwarded_deep_link_route");
      const secondRoute = await this.invoke("forwarded_deep_link_route");
      const pendingActions = await this.invoke("initial_notification_actions");
      assert(
        firstRoute === "chat" &&
          secondRoute === null &&
          Array.isArray(pendingActions) &&
          pendingActions.length === 0,
        "P-27 cold notification action was not drained exactly once",
      );
      return {
        coldQueuedBeforeRenderer: true,
        coldActionDrainedOnce: true,
        notificationId: coldNotificationId,
        forwardCount: 1,
        pendingAfterDrain: 0,
        forwardedBeforeWebDriverSession: true,
      };
    },
    async execute(script, args = [], asynchronous = false) {
      assert(sessionId, "P-27 WebDriver session is not active");
      return jsonRequest(
        baseURL,
        "POST",
        `/session/${sessionId}/execute/${asynchronous ? "async" : "sync"}`,
        { script, args },
      );
    },
    async invoke(command, payload = {}) {
      const result = await this.execute(
        "const done = arguments[arguments.length - 1]; window.__TAURI_INTERNALS__.invoke(arguments[0], arguments[1]).then((value) => done({ ok: true, value }), (error) => done({ ok: false, error: String(error) }));",
        [command, payload],
        true,
      );
      assert(
        result?.ok === true,
        `P-27 Tauri invoke ${command} failed: ${result?.error ?? "unknown"}`,
      );
      return result.value;
    },
    async bodyState() {
      return this.execute(
        "return { text: document.body.innerText, focused: document.activeElement ? (document.activeElement.getAttribute('aria-label') || document.activeElement.textContent || document.activeElement.tagName) : '' };",
      );
    },
    async stop() {
      if (sessionId && baseURL) {
        try {
          await jsonRequest(baseURL, "DELETE", `/session/${sessionId}`);
        } catch {}
      }
      sessionId = null;
      if (processHandle) {
        processHandle.kill("SIGTERM");
        processHandle = null;
      }
    },
  };
}
function defaultDependencies(options) {
  let ownerPid = null;
  let coldLifecycle = null;
  const daemon = installedDaemonConnection();
  const env = {
    ...process.env,
    HOME: options.homeDir,
    XDG_CONFIG_HOME: path.join(options.homeDir, ".config"),
    XDG_DATA_HOME: path.join(options.homeDir, ".local/share"),
    XDG_RUNTIME_DIR: options.runtimeDir,
    OPENBURNBAR_DAEMON_SOCKET_PATH: daemon.socketPath,
    OPENBURNBAR_DAEMON_SOCKET_AUTH_TOKEN_FILE: daemon.tokenFile,
  };
  const browserCapture = installBrowserCapture(options.homeDir, env);
  const driver = webdriverController(env);
  return {
    platform: process.platform,
    installedVerifier: verifyInstalledCandidate,
    executableVerifier() {
      fs.accessSync(DESKTOP, fs.constants.X_OK);
      fs.accessSync(DAEMON, fs.constants.X_OK);
    },
    installedIdentity: () => installedIdentity(options),
    autostartState,
    desktopPids,
    daemonActive,
    runtimeFiles: () => runtimeFiles(options),
    runtimeManifest: () =>
      JSON.parse(
        required(
          DESKTOP,
          ["--runtime-capabilities"],
          "P-27 runtime capabilities",
          { env },
        ),
      ),
    async loginStart() {
      const login = spawn(DESKTOP, ["--background"], {
        env,
        stdio: "ignore",
      });
      login.unref();
      await waitFor("P-27 XDG background start", () => {
        assert(desktopPids().includes(login.pid), "background owner is absent");
        return true;
      });
      login.kill("SIGTERM");
      await waitFor("P-27 XDG background exit", () => {
        assert(
          !desktopPids().includes(login.pid),
          "background owner is still running",
        );
        return true;
      });
      return { loginStartObserved: true, startedInBackground: true };
    },
    async launch(args = []) {
      assert(
        args.length === 0,
        "P-27 WebDriver launch does not accept substitute arguments",
      );
      coldLifecycle = await driver.start(options.marker);
      await waitFor("P-27 installed desktop start", () => {
        const pids = desktopPids();
        assert(
          pids.length === 1,
          "installed WebDriver desktop owner is absent or ambiguous",
        );
        ownerPid = pids[0];
        return ownerPid;
      });
      return ownerPid;
    },
    async terminate() {
      if (!ownerPid) return;
      await driver.stop();
      await waitFor("P-27 installed desktop exit", () => {
        assert(
          !desktopPids().includes(ownerPid),
          "installed desktop is still running",
        );
        return true;
      });
      ownerPid = null;
    },
    async productNotification(kind, marker) {
      const route = kind === "reply" ? "chat" : "overview";
      const notificationId = `${marker}-${kind}`;
      const navigated = await driver.execute(
        "const control = [...document.querySelectorAll('button,a,[role=button]')].find((node) => /settings/i.test(`${node.getAttribute('aria-label') || ''} ${node.textContent || ''}`)); if (!control) return false; control.click(); return true;",
      );
      assert(
        navigated === true,
        "P-27 could not establish the Settings route precondition",
      );
      await waitFor("P-27 Settings route precondition", async () => {
        const value = await driver.bodyState();
        assert(
          /settings/iu.test(value?.text ?? ""),
          "Settings route is absent",
        );
        return true;
      });
      const capabilities = await driver.invoke(
        "native_notification_capabilities",
      );
      assert(
        capabilities?.available === true && capabilities.actions === true,
        "P-27 live notification server does not support actions",
      );
      const delivered = await driver.invoke("native_notification_show", {
        request: {
          id: notificationId,
          title:
            kind === "reply" ? "Reply in OpenBurnBar" : "OpenBurnBar update",
          body: `P-27 live ${kind} action ${marker}`,
          route,
          action: kind,
          urgency: "normal",
        },
      });
      assert(
        delivered?.delivered === true &&
          delivered.actionsAttached === true &&
          delivered.notificationId === notificationId,
        `P-27 ${kind} notification was not delivered with its native action`,
      );
      const serverAction = safeJson(
        required(
          "python3",
          [NOTIFICATION_ACTION, "--marker", marker, "--action", kind],
          `P-27 ${kind} native notification action`,
          { env },
        ),
        `P-27 ${kind} native notification action`,
      );
      assert(
        serverAction?.activated === true &&
          serverAction.marker === marker &&
          serverAction.action === kind,
        `P-27 ${kind} action was not activated through the live notification server`,
      );
      const ui = await waitFor(`P-27 ${kind} UI outcome`, async () => {
        const value = await driver.bodyState();
        const text = `${value?.text ?? ""} ${value?.focused ?? ""}`;
        const expected =
          kind === "reply" ? /chat|message|composer/iu : /overview|dashboard/iu;
        assert(
          expected.test(text),
          `${route} is absent from the live renderer`,
        );
        return value;
      });
      const server = parseNotificationServerInformation(
        required(
          "gdbus",
          [
            "call",
            "--session",
            "--dest",
            "org.freedesktop.Notifications",
            "--object-path",
            "/org/freedesktop/Notifications",
            "--method",
            "org.freedesktop.Notifications.GetServerInformation",
          ],
          "P-27 notification server identity",
          { env },
        ),
      );
      return {
        adapter: {
          actionsSupported: capabilities.actions,
          capabilityCommand: "native_notification_capabilities",
          deliveryCommand: "native_notification_show",
          ...server,
        },
        action: {
          action: kind,
          route,
          notificationId,
          delivered: delivered.delivered,
          serverActionObserved: serverAction.activated,
          productEventObserved: serverAction.activated === true && Boolean(ui),
          uiOutcomeObserved: Boolean(ui),
        },
        lifecycle: {
          coldQueuedBeforeRenderer:
            kind === "open" && coldLifecycle?.coldQueuedBeforeRenderer === true,
          coldActionDrainedOnce:
            kind === "open" && coldLifecycle?.coldActionDrainedOnce === true,
          coldNotificationId:
            kind === "open" ? coldLifecycle?.notificationId : undefined,
          coldForwardCount:
            kind === "open" ? coldLifecycle?.forwardCount : undefined,
          coldPendingAfterDrain:
            kind === "open" ? coldLifecycle?.pendingAfterDrain : undefined,
          coldForwardedBeforeWebDriverSession:
            kind === "open"
              ? coldLifecycle?.forwardedBeforeWebDriverSession
              : undefined,
        },
      };
    },
    async deepLink(uri, phase) {
      const before = desktopPids();
      const forwarded = run(DESKTOP, [uri], { env });
      assert(
        forwarded.status === 0,
        `P-27 ${phase} deep link was rejected: ${forwarded.stderr.trim()}`,
      );
      const after = desktopPids();
      assert(
        before.length === 1 && JSON.stringify(after) === JSON.stringify(before),
        "P-27 deep link did not retain one installed owner",
      );
      const expectedRoute = phase === "warm" ? "providers" : "account";
      const observedRoute = await waitFor(
        `P-27 ${phase} forwarded route`,
        async () => {
          const value = await driver.invoke("forwarded_deep_link_route");
          assert(
            value === expectedRoute,
            `expected ${expectedRoute}, received ${String(value)}`,
          );
          return value;
        },
      );
      return {
        ownerPid: before[0],
        singleInstance: true,
        forwardedToOwner: observedRoute === expectedRoute,
        forwardCount: 1,
      };
    },
    async oauthCallback() {
      fs.rmSync(browserCapture.capture, { force: true });
      const operation = await driver.invoke("account_begin_sign_in");
      const operationID = operation?.operationID;
      assert(
        typeof operationID === "string" && operationID.length > 0,
        "P-27 installed shell did not begin an OAuth operation",
      );
      let cancelled = false;
      try {
        const rawURL = await waitFor(
          "P-27 product OAuth browser launch",
          () => {
            assert(
              fs.existsSync(browserCapture.capture),
              "authorization URL is not captured",
            );
            return fs.readFileSync(browserCapture.capture, "utf8").trim();
          },
        );
        const parsed = validateOAuthAuthorizationURL(rawURL);
        const wrongState = `${parsed.state[0] === "A" ? "B" : "A"}${parsed.state.slice(1)}`;
        const wrong = new URL(parsed.redirect);
        wrong.searchParams.set("code", `${options.marker}-wrong-state`);
        wrong.searchParams.set("state", wrongState);
        const wrongStateStatus = await callbackStatus(wrong);
        assert(
          wrongStateStatus === 400,
          `P-27 wrong-state OAuth callback returned ${wrongStateStatus}`,
        );
        const callback = new URL(parsed.redirect);
        callback.searchParams.set(
          "code",
          `${options.marker}-authorization-code`,
        );
        callback.searchParams.set("state", parsed.state);
        const callbackStatusCode = await callbackStatus(callback);
        assert(
          callbackStatusCode === 200,
          `P-27 state-bound OAuth callback returned ${callbackStatusCode}`,
        );
        const replayStatus = await callbackStatus(callback);
        assert(
          replayStatus === 0,
          "P-27 OAuth callback endpoint accepted a replay",
        );
        try {
          await driver.invoke("account_cancel_sign_in", {
            operationId: operationID,
          });
        } catch {
          const status = await driver.invoke("account_status");
          assert(
            status?.authorizationOperationID !== operationID,
            "P-27 OAuth operation remained active after its callback",
          );
        }
        cancelled = true;
        return {
          ownerPid,
          singleInstance: false,
          uri: callback.toString(),
          authorizationEndpoint:
            parsed.authorization.origin + parsed.authorization.pathname,
          operationIdPresent: true,
          stateBound: true,
          wrongStateStatus,
          callbackStatus: callbackStatusCode,
          replayRejected: true,
        };
      } finally {
        fs.rmSync(browserCapture.capture, { force: true });
        if (!cancelled) {
          try {
            await driver.invoke("account_cancel_sign_in", {
              operationId: operationID,
            });
          } catch {}
        }
      }
    },
    async hostileLink(uri) {
      const result = run(DESKTOP, [uri], { env });
      return {
        accepted: result.status === 0,
        reason: result.stderr.trim() || "single_instance_deep_link_rejected",
      };
    },
    atspi(mode, output) {
      const value = JSON.parse(
        required(
          "python3",
          [CONTROL, "--mode", mode, "--output", output],
          `P-27 AT-SPI ${mode}`,
        ),
      );
      fs.chmodSync(output, 0o600);
      return value;
    },
    screenshot,
  };
}

export async function runP27NativeNotificationProbes(
  options,
  dependencies = null,
) {
  const output = ownerDirectory(options.rawOutputDir, "P-27 raw output", true);
  const home = ownerDirectory(options.homeDir, "P-27 HOME", true);
  const runtimeDir = ownerDirectory(
    options.runtimeDir,
    "P-27 runtime directory",
    true,
  );
  assert(
    new Set([output, home, runtimeDir]).size === 3,
    "P-27 evidence, HOME, and runtime directories must be disjoint",
  );
  options = { ...options, rawOutputDir: output, homeDir: home, runtimeDir };
  const deps = dependencies ?? defaultDependencies(options);
  assert(deps.platform === "linux", "P-27 native probes require Linux");
  const startedAt = new Date().toISOString();
  const pidsBefore = deps.desktopPids();
  assert(
    pidsBefore.length === 0,
    "P-27 requires no preexisting installed desktop process",
  );
  const daemonWasActive = deps.daemonActive();
  const runtimeBefore = deps.runtimeFiles();
  let autostart;
  let primaryError;
  const cleanupErrors = [];
  let ownerPid;
  let transcript;
  let marker;
  try {
    deps.installedVerifier(options);
    deps.executableVerifier();
    const installed = deps.installedIdentity();
    autostart = deps.autostartState();
    const loginStart = await deps.loginStart();
    assert(
      loginStart.loginStartObserved === true &&
        loginStart.startedInBackground === true,
      "P-27 XDG login start did not produce a background installed owner",
    );
    const runtime = deps.runtimeManifest();
    const capability = runtime.capabilities?.find?.(
      (item) => item.id === "native.notifications",
    );
    assert(
      capability &&
        ["available", "degraded", "unavailable"].includes(capability.state),
      "P-27 runtime manifest omits native.notifications",
    );
    const runtimeBytes = Buffer.from(`${JSON.stringify(runtime, null, 2)}\n`);
    fs.writeFileSync(
      path.join(output, "notification-runtime-capabilities.json"),
      runtimeBytes,
      { flag: "wx", mode: 0o600 },
    );
    const runtimeSha256 = crypto
      .createHash("sha256")
      .update(runtimeBytes)
      .digest("hex");
    ownerPid = await deps.launch();
    const open = await deps.productNotification("open", options.marker);
    validateProductNotification(open, "open", options.marker);
    assert(
      open.lifecycle?.coldQueuedBeforeRenderer === true &&
        open.lifecycle?.coldActionDrainedOnce === true,
      "P-27 cold notification action was not queued and drained exactly once",
    );
    const openA11y = await deps.atspi(
      "open",
      path.join(output, "notification-open-atspi.json"),
    );
    deps.screenshot(path.join(output, "notification-open.png"));
    const reply = await deps.productNotification("reply", options.marker);
    validateProductNotification(reply, "reply", options.marker);
    assert(
      JSON.stringify(reply.adapter) === JSON.stringify(open.adapter),
      "P-27 notification adapter changed between Open and Reply",
    );
    const replyA11y = await deps.atspi(
      "reply",
      path.join(output, "notification-reply-atspi.json"),
    );
    deps.screenshot(path.join(output, "notification-reply.png"));
    const links = [];
    let warmForward = null;
    for (const row of [
      {
        kind: "oauth",
        route: "account",
        phase: "cold",
        transport: "loopback",
      },
      {
        kind: "membership",
        uri: "openburnbar://membership/success",
        route: "account",
        phase: "cold",
        transport: "single-instance",
      },
      {
        kind: "provider-model",
        uri: "openburnbar://providers?provider=openai&model=gpt-5.2-codex",
        route: "providers",
        phase: "warm",
        transport: "single-instance",
      },
    ]) {
      const result =
        row.transport === "loopback"
          ? await deps.oauthCallback(row.phase)
          : await deps.deepLink(row.uri, row.phase);
      links.push({
        ...row,
        ...(row.transport === "loopback"
          ? {
              uri: result.uri,
              authorizationEndpoint: result.authorizationEndpoint,
              operationIdPresent: result.operationIdPresent,
              stateBound: result.stateBound,
              wrongStateStatus: result.wrongStateStatus,
              callbackStatus: result.callbackStatus,
              replayRejected: result.replayRejected,
            }
          : {}),
        accepted: true,
        ownerPid: result.ownerPid,
        singleInstance: result.singleInstance,
      });
      if (row.kind === "provider-model") warmForward = result;
    }
    assert(
      warmForward?.forwardedToOwner === true &&
        warmForward?.forwardCount === 1 &&
        warmForward.ownerPid === ownerPid,
      "P-27 warm deep link was not forwarded exactly once to the installed owner",
    );
    await deps.atspi("cold", path.join(output, "notification-cold-atspi.json"));
    deps.screenshot(path.join(output, "notification-cold.png"));
    await deps.atspi("warm", path.join(output, "notification-warm-atspi.json"));
    deps.screenshot(path.join(output, "notification-warm.png"));
    const hostileLinks = [];
    for (const uri of HOSTILE_LINKS) {
      const result = await deps.hostileLink(uri);
      assert(
        result.accepted === false,
        `P-27 hostile link was accepted: ${uri}`,
      );
      hostileLinks.push({ uri, accepted: false, reason: result.reason });
    }
    transcript = {
      producer: "openburnbar-p27-installed-notifications-probe-v1",
      marker: options.marker,
      startedAt,
      endedAt: new Date().toISOString(),
      runtime: {
        manifestSha256: runtimeSha256,
        notificationState: capability.state,
        source: "installed-runtime-command",
      },
      compositor: {
        desktop: options.desktop,
        displayServer: options.displayServer,
        sessionType: options.displayServer.toLowerCase(),
      },
      adapter: open.adapter,
      notifications: { open: open.action, reply: reply.action },
      deepLinks: links,
      hostileLinks,
      lifecycle: {
        coldQueuedBeforeRenderer: open.lifecycle.coldQueuedBeforeRenderer,
        coldActionDrainedOnce: open.lifecycle.coldActionDrainedOnce,
        coldNotificationId: open.lifecycle.coldNotificationId,
        coldForwardCount: open.lifecycle.coldForwardCount,
        coldPendingAfterDrain: open.lifecycle.coldPendingAfterDrain,
        coldForwardedBeforeWebDriverSession:
          open.lifecycle.coldForwardedBeforeWebDriverSession,
        warmForwardedToOwner: warmForward?.forwardedToOwner === true,
        warmForwardCount: warmForward?.forwardCount ?? 0,
        ownerPid,
      },
      autostart: {
        path: autostart.path,
        exec: autostart.exec,
        enabled: true,
        ownedByPackage: true,
        loginStartObserved: loginStart.loginStartObserved,
        startedInBackground: loginStart.startedInBackground,
      },
      restoration: {
        autostartBeforeSha256: autostart.sha256,
        autostartAfterSha256: autostart.sha256,
        daemonWasActive,
        daemonActiveAfter: daemonWasActive,
        desktopPidsBefore: pidsBefore,
        desktopPidsAfter: pidsBefore,
        runtimeFilesBefore: runtimeBefore,
        runtimeFilesAfter: runtimeBefore,
      },
    };
    marker = {
      marker: options.marker,
      installed: {
        daemon: DAEMON,
        desktop: DESKTOP,
        autostart: AUTOSTART,
        ...installed,
      },
      runtimeManifest: {
        capturedFrom: `${DESKTOP} --runtime-capabilities`,
        notificationState: capability.state,
        sha256: runtimeSha256,
      },
      safety: {
        fixtureMode: false,
        isolatedHome: true,
        preexistingDesktopProcesses: pidsBefore,
        daemonRestored: true,
        desktopProcessesRestored: true,
        autostartRestored: true,
        singleInstanceStateRestored: true,
      },
    };
    assert(
      openA11y.composerFocused === false && replyA11y.composerFocused === true,
      "P-27 notification actions did not produce distinct accessible focus outcomes",
    );
  } catch (error) {
    primaryError = error;
  }
  try {
    await deps.terminate();
  } catch (error) {
    cleanupErrors.push(error);
  }
  try {
    if (deps.daemonActive() !== daemonWasActive)
      cleanupErrors.push(new Error("P-27 daemon service state changed"));
  } catch (error) {
    cleanupErrors.push(error);
  }
  try {
    if (JSON.stringify(deps.desktopPids()) !== JSON.stringify(pidsBefore))
      cleanupErrors.push(new Error("P-27 desktop process state changed"));
  } catch (error) {
    cleanupErrors.push(error);
  }
  try {
    if (autostart && deps.autostartState().sha256 !== autostart.sha256)
      cleanupErrors.push(new Error("P-27 autostart bytes changed"));
  } catch (error) {
    cleanupErrors.push(error);
  }
  try {
    if (JSON.stringify(deps.runtimeFiles()) !== JSON.stringify(runtimeBefore))
      cleanupErrors.push(
        new Error("P-27 single-instance runtime state changed"),
      );
  } catch (error) {
    cleanupErrors.push(error);
  }
  if (primaryError || cleanupErrors.length)
    throw new AggregateError(
      [...(primaryError ? [primaryError] : []), ...cleanupErrors],
      "P-27 native probe or restoration failed",
    );
  transcript.endedAt = new Date().toISOString();
  fs.writeFileSync(
    path.join(output, "notification-native-transcript.json"),
    `${JSON.stringify(transcript, null, 2)}\n`,
    { flag: "wx", mode: 0o600 },
  );
  fs.writeFileSync(
    path.join(output, "notification-marker.json"),
    `${JSON.stringify(marker, null, 2)}\n`,
    { flag: "wx", mode: 0o600 },
  );
  return { output, transcript };
}

function args(argv) {
  const names = [
    "--raw-output-dir",
    "--home-dir",
    "--runtime-dir",
    "--environment",
    "--desktop",
    "--display-server",
    "--marker",
    "--target-head",
    "--candidate-run-id",
    "--candidate-artifact-digest",
    "--package-version",
    "--manifest-sha256",
    "--manifest-signature-sha256",
  ];
  const values = new Map();
  for (let index = 0; index < argv.length; index += 2) {
    if (
      !names.includes(argv[index]) ||
      values.has(argv[index]) ||
      argv[index + 1] === undefined
    )
      throw new Error(`invalid argument: ${argv[index] ?? "<missing>"}`);
    values.set(argv[index], argv[index + 1]);
  }
  for (const name of names)
    if (!values.has(name)) throw new Error(`${name} is required`);
  return {
    rawOutputDir: values.get("--raw-output-dir"),
    homeDir: values.get("--home-dir"),
    runtimeDir: values.get("--runtime-dir"),
    environmentId: values.get("--environment"),
    desktop: values.get("--desktop"),
    displayServer: values.get("--display-server"),
    marker: values.get("--marker"),
    targetHead: values.get("--target-head"),
    candidateRunId: values.get("--candidate-run-id"),
    candidateArtifactDigest: values.get("--candidate-artifact-digest"),
    packageVersion: values.get("--package-version"),
    manifestSha256: values.get("--manifest-sha256"),
    manifestSignatureSha256: values.get("--manifest-signature-sha256"),
  };
}
if (
  process.argv[1] &&
  path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)
)
  runP27NativeNotificationProbes(args(process.argv.slice(2)))
    .then((value) =>
      process.stdout.write(`${JSON.stringify({ output: value.output })}\n`),
    )
    .catch((error) => {
      process.stderr.write(
        `P-27 native notification probes failed: ${error.message}\n`,
      );
      process.exitCode = 1;
    });
