#!/usr/bin/env node
import crypto from "node:crypto";
import fs from "node:fs";
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
const ATSPI = path.join(ROOT, "scripts/linux-port/capture-atspi-tree.py");
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
function wait(ms) {
  return new Promise((resolve) => setTimeout(resolve, ms));
}
async function waitFor(label, operation, timeout = 30_000) {
  const deadline = Date.now() + timeout;
  let last;
  while (Date.now() < deadline) {
    try {
      return await operation();
    } catch (error) {
      last = error;
      await wait(250);
    }
  }
  throw new Error(`${label} timed out: ${last?.message ?? "unavailable"}`);
}
function privateDirectory(candidate, label, empty = false) {
  const absolute = path.resolve(candidate);
  let ancestor = absolute;
  while (!fs.existsSync(ancestor)) ancestor = path.dirname(ancestor);
  assert(
    fs.realpathSync(ancestor) === ancestor,
    `${label} traverses a symlink`,
  );
  fs.mkdirSync(absolute, { recursive: true, mode: 0o700 });
  const stat = fs.lstatSync(absolute);
  assert(
    stat.isDirectory() &&
      !stat.isSymbolicLink() &&
      stat.uid === process.getuid?.() &&
      (stat.mode & 0o077) === 0 &&
      fs.realpathSync(absolute) === absolute,
    `${label} must be canonical and owner-only`,
  );
  if (empty)
    assert(fs.readdirSync(absolute).length === 0, `${label} must be empty`);
  return absolute;
}
function disjoint(values) {
  for (let left = 0; left < values.length; left += 1) {
    for (let right = left + 1; right < values.length; right += 1) {
      const forward = path.relative(values[left], values[right]);
      const reverse = path.relative(values[right], values[left]);
      assert(
        forward !== "" &&
          (forward.startsWith("..") || path.isAbsolute(forward)) &&
          reverse !== "" &&
          (reverse.startsWith("..") || path.isAbsolute(reverse)),
        "P-36 raw output and state home must be disjoint",
      );
    }
  }
}
function tree(root) {
  const rows = [];
  const visit = (dir, prefix = "") => {
    for (const name of fs.readdirSync(dir).sort()) {
      const file = path.join(dir, name);
      const rel = prefix ? path.join(prefix, name) : name;
      const stat = fs.lstatSync(file);
      assert(!stat.isSymbolicLink(), `P-36 state contains symlink ${rel}`);
      if (stat.isDirectory()) {
        rows.push({ path: rel, type: "directory", mode: stat.mode & 0o777 });
        visit(file, rel);
      } else {
        assert(stat.isFile(), `P-36 state contains special file ${rel}`);
        rows.push({
          path: rel,
          type: "file",
          mode: stat.mode & 0o777,
          sha256: crypto
            .createHash("sha256")
            .update(fs.readFileSync(file))
            .digest("hex"),
        });
      }
    }
  };
  visit(root);
  return rows;
}
function challenge(options, marker, nonce) {
  return crypto
    .createHash("sha256")
    .update(
      [
        options.targetHead,
        String(options.candidateRunId),
        options.candidateArtifactDigest,
        marker,
        nonce,
      ].join("\n"),
    )
    .digest("hex");
}
function contract(id) {
  const architecture = id.endsWith("-aarch64") ? "aarch64" : "x86_64";
  if (id.startsWith("ubuntu-") && id.includes("-gnome-"))
    return {
      architecture,
      packageFormat: "deb",
      desktop: "GNOME",
      displayServer: id.includes("-x11-") ? "X11" : "Wayland",
      compositor: "Mutter",
    };
  if (id.startsWith("fedora-kde-wayland-"))
    return {
      architecture,
      packageFormat: "rpm",
      desktop: "KDE Plasma",
      displayServer: "Wayland",
      compositor: "KWin",
    };
  if (id === "arch-sway-wayland-x86_64")
    return {
      architecture,
      packageFormat: "arch",
      desktop: "Sway/wlroots",
      displayServer: "Wayland",
      compositor: "Sway/wlroots",
    };
  throw new Error("P-36 environment unsupported");
}
export async function runP36VisualPolishWorkflow(options, deps) {
  assert(
    (deps.platform ?? process.platform) === "linux" &&
      deps.desktopSession === true,
    "P-36 requires a live Linux desktop session",
  );
  const expected = contract(options.environmentId);
  assert(
    options.architecture === expected.architecture &&
      options.packageFormat === expected.packageFormat &&
      options.desktop === expected.desktop &&
      options.displayServer === expected.displayServer &&
      options.compositor === expected.compositor,
    "P-36 invocation does not match environment",
  );
  const raw = privateDirectory(options.rawOutputDir, "P-36 raw output", true);
  const home = privateDirectory(options.stateHome, "P-36 isolated home", true);
  disjoint([raw, home]);
  (deps.installedVerifier ?? verifyInstalledCandidate)(options);
  for (const name of [
    "identity",
    "launch",
    "terminate",
    "resize",
    "layout",
    "theme",
    "motionPreference",
    "setMotionPreference",
    "motion",
    "interaction",
    "capture",
    "restart",
    "themeState",
    "daemonActive",
    "setDaemonActive",
    "desktopPids",
    "restoreState",
  ])
    assert(typeof deps[name] === "function", `P-36 ${name} adapter required`);
  const marker = deps.marker ?? `p36-${crypto.randomBytes(8).toString("hex")}`;
  const nonce = deps.nonce ?? crypto.randomBytes(16).toString("hex");
  assert(
    /^p36-[a-f0-9]{16}$/u.test(marker) && /^[a-f0-9]{32}$/u.test(nonce),
    "P-36 marker/nonce invalid",
  );
  const startedAt = (deps.clock?.() ?? new Date()).toISOString();
  const serviceBefore = deps.daemonActive();
  const pidsBefore = deps.desktopPids();
  const stateBefore = tree(home);
  const motionBefore = deps.motionPreference();
  assert(pidsBefore.length === 0, "P-36 requires no pre-existing desktop");
  const cleanup = [];
  let primary;
  let transcript;
  let markerDocument;
  try {
    if (!serviceBefore) await deps.setDaemonActive(true);
    const identity = deps.identity();
    await deps.launch();
    const light = await deps.theme("light");
    await deps.resize(720, 900);
    const compact = await deps.layout("compact");
    await deps.capture(
      "compact",
      "More actions",
      path.join(raw, "visual-compact-atspi.json"),
      path.join(raw, "visual-compact-light.png"),
    );
    const dark = await deps.theme("dark");
    await deps.resize(1180, 820);
    const standard = await deps.layout("standard");
    await deps.capture(
      "standard",
      "More actions",
      path.join(raw, "visual-standard-atspi.json"),
      path.join(raw, "visual-standard-dark.png"),
    );
    await deps.resize(1600, 900);
    const wide = await deps.layout("wide");
    await deps.capture(
      "wide",
      "More actions",
      path.join(raw, "visual-wide-atspi.json"),
      path.join(raw, "visual-wide-dark.png"),
    );
    await deps.setMotionPreference(true);
    const motion = await deps.motion();
    await deps.capture(
      "reduced",
      "Open command palette",
      path.join(raw, "visual-reduced-atspi.json"),
      path.join(raw, "visual-reduced-motion.png"),
    );
    const interaction = await deps.interaction();
    await deps.capture(
      "overflow",
      "Appearance",
      path.join(raw, "visual-overflow-atspi.json"),
      path.join(raw, "visual-overflow-menu.png"),
    );
    await deps.setMotionPreference(motionBefore);
    await deps.restart();
    await deps.resize(1180, 820);
    const afterRestart = await deps.layout("standard");
    const appearance = await deps.themeState();
    for (const [name, layout, width, height] of [
      ["compact", compact, 720, 900],
      ["standard", standard, 1180, 820],
      ["wide", wide, 1600, 900],
    ]) {
      assert(
        layout?.viewportWidth === width &&
          layout?.viewportHeight === height &&
          layout?.density === name &&
          layout?.horizontalOverflow === 0 &&
          layout?.clippedCount === 0 &&
          layout?.overlappingControls === 0 &&
          layout?.interactiveCount >= 8 &&
          layout?.minControlHeight >= 28,
        `P-36 ${name} live layout failed its measured contract`,
      );
    }
    for (const [mode, theme] of [
      ["light", light],
      ["dark", dark],
    ]) {
      assert(
        theme?.appearance === mode &&
          Number.isFinite(theme?.contrastRatio) &&
          theme.contrastRatio >= 4.5 &&
          theme.nativeControlCount >= 1 &&
          theme.nativeControlScheme === mode &&
          theme.persisted === true,
        `P-36 ${mode} live theme failed its measured contract`,
      );
    }
    assert(
      motion?.mediaQuery === "(prefers-reduced-motion: reduce)" &&
        motion?.reduced === true &&
        motion?.animatedElements === 0 &&
        motion?.transitioningElements === 0,
      "P-36 reduced-motion live measurement failed",
    );
    assert(
      interaction?.keyboardOnly === true &&
        interaction?.distinctFocusTargets >= 3 &&
        interaction?.focusVisible === true &&
        interaction?.overflowOpened === true &&
        interaction?.arrowNavigation === true &&
        interaction?.escapeRestoredFocus === true,
      "P-36 keyboard overflow interaction failed",
    );
    assert(
      appearance?.appearance === "dark" && appearance?.persisted === "dark",
      "P-36 dark appearance did not survive installed restart",
    );
    const endedAt = (deps.clock?.() ?? new Date()).toISOString();
    transcript = {
      producer: "openburnbar-p36-installed-visual-polish-probe-v1",
      marker,
      challenge: challenge(options, marker, nonce),
      startedAt,
      endedAt,
      packageFacts: {
        architecture: options.architecture,
        channel: options.packageFormat,
        desktop: options.desktop,
        displayServer: options.displayServer,
        compositor: options.compositor,
        manager: identity.packageManager,
        os: "linux",
        packageVersion: options.packageVersion,
        sessionType: options.displayServer.toLowerCase(),
        shellVersion: options.packageVersion,
      },
      layouts: { compact, standard, wide },
      themes: { light, dark },
      motion: {
        ...motion,
        preferenceRestored: deps.motionPreference() === motionBefore,
      },
      interaction,
      restart: {
        appearancePersisted:
          appearance.appearance === "dark" && appearance.persisted === "dark",
        layoutStable: JSON.stringify(afterRestart) === JSON.stringify(standard),
        relaunchCount: 1,
      },
      restoration: {
        daemonActiveBefore: serviceBefore,
        daemonActiveAfter: serviceBefore,
        desktopPidsBefore: pidsBefore,
        desktopPidsAfter: pidsBefore,
        isolatedStateRestored: true,
        motionPreferenceBefore: motionBefore,
        motionPreferenceAfter: motionBefore,
      },
    };
    markerDocument = {
      producer: transcript.producer,
      marker,
      nonce,
      challenge: transcript.challenge,
      installed: {
        desktop: DESKTOP,
        daemon: DAEMON,
        packageManager: identity.packageManager,
        packageName: identity.packageName,
        packageOwned: identity.packageOwned,
      },
      package: {
        architecture: options.architecture,
        format: options.packageFormat,
        manifestSha256: options.manifestSha256,
        version: options.packageVersion,
      },
    };
  } catch (error) {
    primary = error;
  }
  try {
    await deps.terminate();
  } catch (error) {
    cleanup.push(error);
  }
  try {
    await deps.setDaemonActive(serviceBefore);
  } catch (error) {
    cleanup.push(error);
  }
  try {
    await deps.setMotionPreference(motionBefore);
  } catch (error) {
    cleanup.push(error);
  }
  try {
    await deps.restoreState(stateBefore);
  } catch (error) {
    cleanup.push(error);
  }
  try {
    if (
      deps.daemonActive() !== serviceBefore ||
      JSON.stringify(deps.desktopPids()) !== JSON.stringify(pidsBefore) ||
      JSON.stringify(tree(home)) !== JSON.stringify(stateBefore) ||
      deps.motionPreference() !== motionBefore
    )
      throw new Error("P-36 exact restoration failed");
  } catch (error) {
    cleanup.push(error);
  }
  if (primary || cleanup.length)
    throw primary && cleanup.length
      ? new AggregateError(
          [primary, ...cleanup],
          "P-36 workflow and restoration failed",
        )
      : (primary ?? new AggregateError(cleanup, "P-36 restoration failed"));
  fs.writeFileSync(
    path.join(raw, "visual-native-transcript.json"),
    `${JSON.stringify(transcript, null, 2)}\n`,
    { flag: "wx", mode: 0o600 },
  );
  fs.writeFileSync(
    path.join(raw, "visual-marker.json"),
    `${JSON.stringify(markerDocument, null, 2)}\n`,
    { flag: "wx", mode: 0o600 },
  );
  return { rawOutputDir: raw, transcript, marker: markerDocument };
}
function pids() {
  const result = run("pgrep", [
    "-f",
    "^/usr/bin/openburnbar-linux-desktop([[:space:]]|$)",
  ]);
  if (result.status === 1) return [];
  assert(result.status === 0, "P-36 desktop process inspection failed");
  return result.stdout
    .trim()
    .split(/\s+/u)
    .filter(Boolean)
    .map(Number)
    .filter(Number.isSafeInteger)
    .sort((a, b) => a - b);
}
function active() {
  const result = run("systemctl", [
    "--user",
    "is-active",
    "--quiet",
    "openburnbar-daemon.service",
  ]);
  assert([0, 3].includes(result.status), "P-36 daemon inspection failed");
  return result.status === 0;
}
async function port() {
  return new Promise((resolve, reject) => {
    const server = net.createServer();
    server.once("error", reject);
    server.listen(0, "127.0.0.1", () => {
      const address = server.address();
      server.close((error) => (error ? reject(error) : resolve(address.port)));
    });
  });
}
async function request(base, method, endpoint, body) {
  const response = await fetch(new URL(endpoint, base), {
    method,
    headers:
      body === undefined ? undefined : { "content-type": "application/json" },
    body: body === undefined ? undefined : JSON.stringify(body),
    signal: AbortSignal.timeout(30_000),
  });
  const text = await response.text();
  const value = text ? JSON.parse(text) : null;
  if (!response.ok)
    throw new Error(
      `P-36 WebDriver ${method} ${endpoint} failed (${response.status})`,
    );
  return value?.value ?? value;
}
function webdriver(env) {
  let processHandle;
  let session;
  let base;
  return {
    running() {
      return Boolean(session);
    },
    async start() {
      required(
        "sh",
        [
          "-c",
          "command -v tauri-driver >/dev/null && command -v WebKitWebDriver >/dev/null",
        ],
        "P-36 WebDriver prerequisites",
        { env },
      );
      const selected = await port();
      base = `http://127.0.0.1:${selected}/`;
      processHandle = spawn("tauri-driver", ["--port", String(selected)], {
        env,
        stdio: "ignore",
      });
      processHandle.unref();
      await waitFor("P-36 driver", () => request(base, "GET", "/status"));
      const value = await request(base, "POST", "/session", {
        capabilities: {
          alwaysMatch: {
            browserName: "wry",
            "tauri:options": { application: DESKTOP },
          },
        },
      });
      session = value.sessionId;
      assert(session, "P-36 session absent");
      await request(base, "POST", `/session/${session}/timeouts`, {
        script: 30_000,
      });
      await this.execute(
        "location.hash='#/overview';window.dispatchEvent(new HashChangeEvent('hashchange'));return true;",
      );
      await wait(1200);
    },
    execute(script, args = []) {
      return request(base, "POST", `/session/${session}/execute/sync`, {
        script,
        args,
      });
    },
    async viewport(width, height) {
      let outerWidth = width;
      let outerHeight = height;
      for (let attempt = 0; attempt < 5; attempt += 1) {
        await request(base, "POST", `/session/${session}/window/rect`, {
          width: outerWidth,
          height: outerHeight,
          x: 20,
          y: 20,
        });
        await wait(250);
        const measured = await this.execute(
          "return {width:window.innerWidth,height:window.innerHeight,dpr:window.devicePixelRatio};",
        );
        assert(
          Number.isSafeInteger(measured?.width) &&
            Number.isSafeInteger(measured?.height) &&
            Number.isFinite(measured?.dpr) &&
            measured.dpr === 1,
          "P-36 WebDriver returned invalid viewport dimensions",
        );
        if (measured.width === width && measured.height === height)
          return measured;
        outerWidth += width - measured.width;
        outerHeight += height - measured.height;
        assert(
          outerWidth >= 320 &&
            outerHeight >= 320 &&
            outerWidth <= 4096 &&
            outerHeight <= 4096,
          "P-36 viewport convergence escaped safe bounds",
        );
      }
      throw new Error(
        `P-36 could not establish ${width}x${height} DOM viewport`,
      );
    },
    key(value) {
      return request(base, "POST", `/session/${session}/actions`, {
        actions: [
          {
            type: "key",
            id: "keyboard",
            actions: [
              { type: "keyDown", value },
              { type: "keyUp", value },
            ],
          },
        ],
      });
    },
    async screenshot(file) {
      const encoded = await request(
        base,
        "GET",
        `/session/${session}/screenshot`,
      );
      assert(
        typeof encoded === "string" && /^[A-Za-z0-9+/]+=*$/u.test(encoded),
        "P-36 WebDriver screenshot response is invalid",
      );
      const bytes = Buffer.from(encoded, "base64");
      assert(
        bytes.length >= 1024 &&
          bytes
            .subarray(0, 8)
            .equals(Buffer.from([137, 80, 78, 71, 13, 10, 26, 10])),
        "P-36 WebDriver screenshot is not a non-empty PNG",
      );
      fs.writeFileSync(file, bytes, { flag: "wx", mode: 0o600 });
    },
    async stop() {
      if (session) {
        try {
          await request(base, "DELETE", `/session/${session}`);
        } catch {}
      }
      session = null;
      if (processHandle) {
        const child = processHandle;
        child.kill("SIGTERM");
        try {
          await waitFor(
            "P-36 tauri-driver exit",
            () => {
              assert(
                child.exitCode !== null || child.signalCode !== null,
                "driver alive",
              );
              return true;
            },
            5_000,
          );
        } catch {
          child.kill("SIGKILL");
          await waitFor(
            "P-36 tauri-driver forced exit",
            () => {
              assert(
                child.exitCode !== null || child.signalCode !== null,
                "driver alive",
              );
              return true;
            },
            5_000,
          );
        }
      }
      processHandle = null;
    },
  };
}
export const P36_LAYOUT_SCRIPT = `
const density = arguments[0];
const viewportWidth = window.innerWidth;
const viewportHeight = window.innerHeight;
const selector = 'button,input,select,textarea,a[href],[role="button"],[role="tab"]';
const controls = [...document.querySelectorAll(selector)].filter((element) => {
  const style = getComputedStyle(element);
  const rect = element.getBoundingClientRect();
  return !element.disabled && element.getAttribute('aria-disabled') !== 'true' && style.display !== 'none' && style.visibility !== 'hidden' && Number(style.opacity) > 0 && rect.width > 0 && rect.height > 0;
});
const rects = controls.map((element) => element.getBoundingClientRect());
const clippedByAncestor = (element, rect) => {
  for (let ancestor = element.parentElement; ancestor; ancestor = ancestor.parentElement) {
    const style = getComputedStyle(ancestor);
    if (!/(hidden|clip)/u.test(style.overflow + style.overflowX + style.overflowY)) continue;
    const boundary = ancestor.getBoundingClientRect();
    if (rect.left < boundary.left - .5 || rect.right > boundary.right + .5 || rect.top < boundary.top - .5 || rect.bottom > boundary.bottom + .5) return true;
  }
  return false;
};
let overlappingControls = 0;
for (let left = 0; left < rects.length; left += 1) {
  for (let right = left + 1; right < rects.length; right += 1) {
    if (controls[left].contains(controls[right]) || controls[right].contains(controls[left])) continue;
    const overlapWidth = Math.min(rects[left].right, rects[right].right) - Math.max(rects[left].left, rects[right].left);
    const overlapHeight = Math.min(rects[left].bottom, rects[right].bottom) - Math.max(rects[left].top, rects[right].top);
    if (overlapWidth > 2 && overlapHeight > 2) overlappingControls += 1;
  }
}
const clippedCount = controls.filter((element, index) => {
  const rect = rects[index];
  return rect.left < -.5 || rect.right > viewportWidth + .5 || clippedByAncestor(element, rect);
}).length;
const documentScrollWidth = Math.max(document.documentElement.scrollWidth, document.body?.scrollWidth ?? 0);
return {
  viewportWidth,
  viewportHeight,
  density,
  horizontalOverflow: Math.max(0, documentScrollWidth - viewportWidth),
  documentScrollWidth,
  clippedCount,
  overlappingControls,
  interactiveCount: controls.length,
  minControlHeight: controls.length ? Math.floor(Math.min(...rects.map((rect) => rect.height))) : 0,
};`;

export const P36_THEME_SCRIPT = `
const mode = arguments[0];
const parse = (value) => {
  const match = value.match(/^rgba?\\(\\s*([\\d.]+)[, ]+([\\d.]+)[, ]+([\\d.]+)(?:\\s*[,/]\\s*([\\d.]+))?\\s*\\)$/u);
  return match ? { rgb: match.slice(1, 4).map(Number), alpha: match[4] === undefined ? 1 : Number(match[4]) } : null;
};
const resolvedBackground = (element) => {
  const layers = [];
  for (let node = element; node; node = node.parentElement) {
    const color = parse(getComputedStyle(node).backgroundColor);
    if (color && color.alpha > 0) layers.push(color);
  }
  let result = mode === 'dark' ? [0, 0, 0] : [255, 255, 255];
  for (const layer of layers.reverse()) result = layer.rgb.map((channel, index) => channel * layer.alpha + result[index] * (1 - layer.alpha));
  return result;
};
const luminance = (rgb) => {
  const values = rgb.map((channel) => {
    const value = channel / 255;
    return value <= .03928 ? value / 12.92 : ((value + .055) / 1.055) ** 2.4;
  });
  return .2126 * values[0] + .7152 * values[1] + .0722 * values[2];
};
const controls = [...document.querySelectorAll('button,input,select,textarea')].filter((element) => {
  const style = getComputedStyle(element);
  const rect = element.getBoundingClientRect();
  return !element.disabled && element.getAttribute('aria-disabled') !== 'true' && style.display !== 'none' && style.visibility !== 'hidden' && Number(style.opacity) > 0 && rect.width > 0 && rect.height > 0;
});
const ratios = controls.map((element) => {
  const foreground = parse(getComputedStyle(element).color);
  if (!foreground || foreground.alpha < .98) return Number.NaN;
  const foregroundLuminance = luminance(foreground.rgb);
  const backgroundLuminance = luminance(resolvedBackground(element));
  return (Math.max(foregroundLuminance, backgroundLuminance) + .05) / (Math.min(foregroundLuminance, backgroundLuminance) + .05);
});
const contrastRatio = ratios.length > 0 && ratios.every(Number.isFinite) ? Math.min(...ratios) : null;
const appearance = document.documentElement.dataset.appearance;
const persistedMode = localStorage.getItem('openburnbar.linux.appearanceMode.v1');
const colorScheme = getComputedStyle(document.documentElement).colorScheme.split(/\\s+/u);
return {
  appearance,
  contrastRatio,
  nativeControlCount: controls.length,
  nativeControlScheme: colorScheme.includes(mode) ? mode : 'mismatch',
  persisted: persistedMode === mode,
};`;
function identity(options) {
  const manager =
    options.packageFormat === "deb"
      ? "dpkg"
      : options.packageFormat === "rpm"
        ? "rpm"
        : "pacman";
  const packageName =
    options.packageFormat === "arch" ? "openburnbar" : "open-burn-bar";
  for (const file of [DESKTOP, DAEMON]) {
    const stat = fs.lstatSync(file);
    assert(
      stat.isFile() &&
        !stat.isSymbolicLink() &&
        stat.uid === 0 &&
        (stat.mode & 0o022) === 0,
      `P-36 unsafe installed file ${file}`,
    );
    const output =
      manager === "dpkg"
        ? required("dpkg-query", ["-S", file], "P-36 package owner")
        : manager === "rpm"
          ? required("rpm", ["-qf", file], "P-36 package owner")
          : required("pacman", ["-Qo", file], "P-36 package owner");
    assert(
      output.includes(packageName),
      `P-36 substitute package owns ${file}`,
    );
  }
  return { packageManager: manager, packageName, packageOwned: true };
}
export function createP36ProductionDependencies(options) {
  const env = {
    ...process.env,
    HOME: options.stateHome,
    XDG_CONFIG_HOME: path.join(options.stateHome, ".config"),
    XDG_DATA_HOME: path.join(options.stateHome, ".local/share"),
    GDK_SCALE: "1",
    GDK_DPI_SCALE: "1",
    GSETTINGS_BACKEND: "keyfile",
    OPENBURNBAR_LINUX_FIXTURE_MODE: "0",
  };
  const driver = webdriver(env);
  const atspi = (expected, output) => {
    const document = JSON.parse(
      required(
        "python3",
        [
          ATSPI,
          "--application",
          "OpenBurnBar",
          "--mode",
          "summary",
          "--expected-name",
          expected,
          "--route",
          "overview",
          "--output",
          output,
          "--min-nodes",
          "12",
          "--min-named",
          "6",
          "--min-actionable",
          "3",
          "--wait-for-meaningful-seconds",
          "5",
        ],
        `P-36 AT-SPI ${expected}`,
      ),
    );
    const stat = fs.lstatSync(output);
    assert(
      stat.isFile() &&
        !stat.isSymbolicLink() &&
        stat.uid === process.getuid?.(),
      "P-36 AT-SPI output is unsafe",
    );
    fs.chmodSync(output, 0o600);
    return document;
  };
  const motionSchema = "org.gnome.desktop.interface";
  const motionKey = "enable-animations";
  const reduced = () => {
    assert(
      required(
        "gsettings",
        ["writable", motionSchema, motionKey],
        "P-36 isolated WebKitGTK motion capability",
        { env },
      ) === "true",
      "P-36 WebKitGTK reduced-motion setting is not writable in isolated state",
    );
    return (
      required(
        "gsettings",
        ["get", motionSchema, motionKey],
        "P-36 isolated WebKitGTK motion preference",
        { env },
      ) === "false"
    );
  };
  return {
    platform: process.platform,
    desktopSession: Boolean(process.env.DISPLAY || process.env.WAYLAND_DISPLAY),
    installedVerifier: verifyInstalledCandidate,
    identity: () => identity(options),
    desktopPids: pids,
    daemonActive: active,
    async setDaemonActive(value) {
      if (active() !== value)
        required(
          "systemctl",
          ["--user", value ? "start" : "stop", "openburnbar-daemon.service"],
          "P-36 daemon state",
        );
      await waitFor("P-36 daemon transition", () => {
        assert(active() === value, "daemon transition pending");
        return true;
      });
    },
    motionPreference: reduced,
    async setMotionPreference(value) {
      required(
        "gsettings",
        ["set", motionSchema, motionKey, value ? "false" : "true"],
        "P-36 isolated WebKitGTK motion preference update",
        { env },
      );
      await waitFor("P-36 motion preference", () => {
        assert(reduced() === value, "motion preference pending");
        return true;
      });
    },
    async launch() {
      await driver.start();
    },
    async terminate() {
      await driver.stop();
      await waitFor("P-36 desktop exit", () => {
        assert(pids().length === 0, "desktop alive");
        return true;
      });
    },
    resize: (w, h) => driver.viewport(w, h),
    layout: (density) => driver.execute(P36_LAYOUT_SCRIPT, [density]),
    async theme(mode) {
      const trigger = await driver.execute(
        "const trigger=[...document.querySelectorAll('button')].find(e=>e.getAttribute('aria-label')==='More actions');trigger?.click();return !!trigger;",
      );
      assert(trigger, "P-36 More actions theme trigger is absent");
      await wait(100);
      const clicked = await driver.execute(
        "const mode=arguments[0],item=[...document.querySelectorAll('[role=menuitemradio]')].find(e=>e.textContent?.trim().endsWith(mode[0].toUpperCase()+mode.slice(1)));item?.click();return !!item;",
        [mode],
      );
      assert(clicked, `P-36 ${mode} theme control absent`);
      await waitFor(`P-36 ${mode} theme persistence`, async () => {
        const applied = await driver.execute(
          "const mode=arguments[0];return document.documentElement.dataset.appearance===mode&&localStorage.getItem('openburnbar.linux.appearanceMode.v1')===mode&&getComputedStyle(document.documentElement).colorScheme.split(/\\s+/u).includes(mode);",
          [mode],
        );
        assert(applied, `${mode} theme not applied`);
        return true;
      });
      await driver.key("\uE00C");
      await waitFor(`P-36 ${mode} theme menu close`, async () => {
        const closed = await driver.execute(
          "return !document.querySelector('[role=menu]')&&document.activeElement?.getAttribute('aria-label')==='More actions';",
        );
        assert(closed, "theme menu still open or focus not restored");
        return true;
      });
      await driver.execute(
        "location.hash='#/activity';window.dispatchEvent(new HashChangeEvent('hashchange'));return true;",
      );
      await wait(500);
      const receipt = await driver.execute(P36_THEME_SCRIPT, [mode]);
      await driver.execute(
        "location.hash='#/overview';window.dispatchEvent(new HashChangeEvent('hashchange'));return true;",
      );
      await wait(300);
      return receipt;
    },
    themeState: () =>
      driver.execute(
        "return {appearance:document.documentElement.dataset.appearance||'system',persisted:localStorage.getItem('openburnbar.linux.appearanceMode.v1')||'system'};",
      ),
    async motion() {
      await waitFor("P-36 reduced motion media", async () => {
        assert(
          await driver.execute(
            "return matchMedia('(prefers-reduced-motion: reduce)').matches;",
          ),
          "media query false",
        );
        return true;
      });
      return driver.execute(
        "const animations=document.getAnimations({subtree:true}).filter(a=>a.playState==='running'||a.playState==='pending');return{mediaQuery:'(prefers-reduced-motion: reduce)',reduced:matchMedia('(prefers-reduced-motion: reduce)').matches,animatedElements:animations.filter(a=>a.constructor?.name!=='CSSTransition').length,transitioningElements:animations.filter(a=>a.constructor?.name==='CSSTransition').length};",
      );
    },
    async interaction() {
      let distinct = new Set();
      for (let index = 0; index < 35; index += 1) {
        await driver.key("\uE004");
        const state = await driver.execute(
          "const e=document.activeElement,all=[...document.querySelectorAll('button,input,select,textarea,a[href],[tabindex]')];return{name:e?.getAttribute('aria-label')||e?.textContent?.trim()||e?.tagName,key:e?.id||`${e?.tagName}|${all.indexOf(e)}`,more:e?.getAttribute('aria-label')==='More actions'};",
        );
        if (state.key) distinct.add(state.key);
        if (state.more) break;
      }
      const focused = await driver.execute(
        "return document.activeElement?.getAttribute('aria-label')==='More actions';",
      );
      assert(focused, "P-36 keyboard could not reach overflow");
      const focusVisible = await driver.execute(
        "return document.activeElement?.matches(':focus-visible')===true;",
      );
      await driver.key("\uE007");
      await wait(100);
      const opened = await driver.execute(
        "const menu=document.querySelector('[role=menu]');return !!menu&&getComputedStyle(menu).display!=='none'&&getComputedStyle(menu).visibility!=='hidden';",
      );
      const before = await driver.execute(
        "const e=document.activeElement;return `${e?.getAttribute('role')}|${e?.textContent?.trim()}|${e?.getAttribute('aria-checked')}`;",
      );
      await driver.key("\uE015");
      const after = await driver.execute(
        "const e=document.activeElement;return `${e?.getAttribute('role')}|${e?.textContent?.trim()}|${e?.getAttribute('aria-checked')}`;",
      );
      await driver.key("\uE00C");
      const restored = await driver.execute(
        "return document.activeElement?.getAttribute('aria-label')==='More actions';",
      );
      await driver.key("\uE007");
      await wait(100);
      assert(
        await driver.execute(
          "const menu=document.querySelector('[role=menu]');return !!menu&&getComputedStyle(menu).display!=='none'&&getComputedStyle(menu).visibility!=='hidden';",
        ),
        "P-36 overflow did not reopen for capture",
      );
      return {
        keyboardOnly: true,
        distinctFocusTargets: distinct.size,
        focusVisible,
        overflowOpened: opened,
        arrowNavigation: before !== after,
        escapeRestoredFocus: restored,
      };
    },
    async capture(state, expected, accessibility, image) {
      const summary = atspi(expected, accessibility);
      const visual = await driver.execute(
        "const menu=document.querySelector('[role=menu]');return{viewport:{width:innerWidth,height:innerHeight},theme:document.documentElement.dataset.appearance||'system',reducedMotion:matchMedia('(prefers-reduced-motion: reduce)').matches,menuOpen:!!menu&&getComputedStyle(menu).display!=='none'&&getComputedStyle(menu).visibility!=='hidden'};",
      );
      const expectedVisual = {
        compact: { viewport: { width: 720, height: 900 }, theme: "light", reducedMotion: false, menuOpen: false },
        standard: { viewport: { width: 1180, height: 820 }, theme: "dark", reducedMotion: false, menuOpen: false },
        wide: { viewport: { width: 1600, height: 900 }, theme: "dark", reducedMotion: false, menuOpen: false },
        reduced: { viewport: { width: 1600, height: 900 }, theme: "dark", reducedMotion: true, menuOpen: false },
        overflow: { viewport: { width: 1600, height: 900 }, theme: "dark", reducedMotion: true, menuOpen: true },
      }[state];
      assert(
        expectedVisual && JSON.stringify(visual) === JSON.stringify(expectedVisual),
        `P-36 ${state} accessibility state does not match the live product`,
      );
      fs.writeFileSync(
        accessibility,
        `${JSON.stringify({ ...summary, producer: "openburnbar-p36-atspi-live-v1", proofState: state, ...visual }, null, 2)}\n`,
        { mode: 0o600 },
      );
      await driver.screenshot(image);
    },
    async restart() {
      await driver.stop();
      await waitFor("P-36 restart stop", () => {
        assert(pids().length === 0, "desktop alive");
        return true;
      });
      await driver.start();
    },
    async restoreState(snapshot) {
      assert(snapshot.length === 0, "P-36 home was not initially empty");
      for (const name of fs.readdirSync(options.stateHome))
        fs.rmSync(path.join(options.stateHome, name), {
          recursive: true,
          force: true,
        });
    },
  };
}
export function parseP36Arguments(argv) {
  const names = [
    "--raw-output-dir",
    "--state-home",
    "--environment",
    "--target-head",
    "--candidate-run-id",
    "--candidate-artifact-digest",
    "--package-version",
    "--manifest-sha256",
    "--manifest-signature-sha256",
    "--architecture",
    "--package-format",
    "--desktop",
    "--display-server",
    "--compositor",
  ];
  const values = new Map();
  for (let i = 0; i < argv.length; i += 2) {
    if (
      !names.includes(argv[i]) ||
      values.has(argv[i]) ||
      argv[i + 1] === undefined
    )
      throw new Error(`invalid argument: ${argv[i] ?? "<missing>"}`);
    values.set(argv[i], argv[i + 1]);
  }
  for (const name of names)
    if (!values.has(name)) throw new Error(`${name} required`);
  return Object.fromEntries(
    names.map((name) => [
      name.slice(2).replace(/-([a-z])/gu, (_m, c) => c.toUpperCase()),
      values.get(name),
    ]),
  );
}
export async function runP36Production(argv, injected = {}) {
  const options = parseP36Arguments(argv);
  return (injected.runWorkflow ?? runP36VisualPolishWorkflow)(
    options,
    (injected.createDependencies ?? createP36ProductionDependencies)(options),
  );
}
if (
  process.argv[1] &&
  path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)
)
  runP36Production(process.argv.slice(2))
    .then((result) =>
      process.stdout.write(
        `${JSON.stringify({ output: result.rawOutputDir })}\n`,
      ),
    )
    .catch((error) => {
      process.stderr.write(
        `P-36 installed visual polish probe failed: ${error.message}\n`,
      );
      process.exitCode = 1;
    });
