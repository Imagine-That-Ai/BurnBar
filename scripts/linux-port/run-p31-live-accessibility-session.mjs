#!/usr/bin/env node
import fs from 'node:fs';
import net from 'node:net';
import os from 'node:os';
import path from 'node:path';
import { spawn, spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { P09_REQUIRED_ROUTES } from './lib/p09-navigation-shell-proof.mjs';
import {
  P31_REQUIRED_ROUTES,
  validateP31LiveSession
} from './lib/p31-accessibility-proof.mjs';
import { P36_LAYOUT_SCRIPT, P36_THEME_SCRIPT } from './run-p36-native-visual-polish-probes.mjs';
import { verifyInstalledCandidate } from './run-p08-mercury-media-session.mjs';

const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../..');
const DESKTOP = '/usr/bin/openburnbar-linux-desktop';
const ATSPI = path.join(ROOT, 'scripts/linux-port/capture-atspi-tree.py');
const P09 = path.join(ROOT, 'scripts/linux-port/run-p09-native-navigation-probes.mjs');
const ENVIRONMENT = 'ubuntu-24.04-gnome-x11-aarch64';
const HEAD = /^[a-f0-9]{40,64}$/u;
const RUN_ID = /^[1-9][0-9]*$/u;
const DIGEST = /^sha256:[a-f0-9]{64}$/u;
const SHA256 = /^[a-f0-9]{64}$/u;
const VERSION = /^(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)(?:[-+][0-9A-Za-z.-]+)?$/u;
const FORBIDDEN_SESSION = /(?:xvfb|xfce|synthetic|fixture|mock)/iu;
const ROUTE_LABELS = Object.freeze({
  overview: 'Overview',
  insights: 'Insights',
  database: 'Database',
  providers: 'Providers & models',
  projects: 'Projects',
  missions: 'Missions',
  activity: 'Activity & logs',
  chat: 'Chat / Hermes',
  memory: 'Memory',
  settings: 'Settings',
  account: 'Account & sync',
  updates: 'Updates',
  support: 'Support & diagnostics',
  onboarding: 'First-run setup',
  pet: 'Pet companion',
  'text-expansion': 'Text expansion',
  'computer-use': 'Computer Use',
  mercury: 'Mercury',
  smarthub: 'SmartHub / IoT'
});

function fail(message) {
  throw new Error(message);
}

function assert(value, message) {
  if (!value) fail(message);
}

function wait(milliseconds) {
  return new Promise((resolve) => setTimeout(resolve, milliseconds));
}

function run(command, args = [], options = {}) {
  const result = spawnSync(command, args, {
    encoding: 'utf8',
    timeout: 60_000,
    maxBuffer: 16 * 1024 * 1024,
    ...options
  });
  if (result.error) throw result.error;
  return {
    status: result.status,
    stdout: result.stdout ?? '',
    stderr: result.stderr ?? ''
  };
}

function required(command, args, label, options = {}) {
  const result = run(command, args, options);
  assert(result.status === 0, `${label} failed (${result.status}): ${(result.stderr || result.stdout).trim()}`);
  return result.stdout.trim();
}

function readOsRelease(file = '/etc/os-release') {
  return Object.fromEntries(
    fs.readFileSync(file, 'utf8')
      .split('\n')
      .map((line) => line.match(/^([A-Z_]+)=(.*)$/u))
      .filter(Boolean)
      .map((match) => [match[1], match[2].replace(/^"|"$/gu, '')])
  );
}

function exactHostArchitecture(platformArchitecture = os.arch()) {
  if (platformArchitecture === 'arm64') return 'aarch64';
  if (platformArchitecture === 'x64') return 'x86_64';
  return platformArchitecture;
}

function parseLoginctl(text) {
  return Object.fromEntries(
    text.split('\n')
      .map((line) => line.match(/^([^=]+)=(.*)$/u))
      .filter(Boolean)
      .map((match) => [match[1], match[2]])
  );
}

export function validateP31HostIdentity({
  platform = process.platform,
  architecture = exactHostArchitecture(),
  release = readOsRelease(),
  environment = process.env,
  loginctl = null,
  windowManager = ''
} = {}) {
  assert(platform === 'linux', 'P-31 live producer must run on Linux');
  assert(architecture === 'aarch64', 'P-31 UTM producer requires native aarch64');
  assert(release.ID === 'ubuntu' && release.VERSION_ID === '24.04',
    'P-31 UTM producer requires Ubuntu 24.04');
  assert((environment.XDG_SESSION_TYPE ?? '').toLowerCase() === 'x11',
    'P-31 UTM producer requires a real X11 session');
  const desktop = environment.XDG_CURRENT_DESKTOP ?? environment.DESKTOP_SESSION ?? '';
  assert(/gnome/iu.test(desktop) && !FORBIDDEN_SESSION.test(desktop),
    'P-31 UTM producer requires GNOME and rejects substitute desktops');
  assert(environment.DISPLAY && environment.DBUS_SESSION_BUS_ADDRESS && environment.XDG_RUNTIME_DIR,
    'P-31 UTM producer requires DISPLAY, the session bus, and XDG_RUNTIME_DIR');
  assert(!environment.WAYLAND_DISPLAY,
    'P-31 GNOME X11 evidence cannot be captured through a Wayland display');
  assert(!FORBIDDEN_SESSION.test(`${environment.DISPLAY} ${windowManager}`),
    'P-31 GNOME evidence rejects Xvfb, XFCE, fixture, and synthetic sessions');
  if (loginctl) {
    assert(loginctl.Type === 'x11' && loginctl.Active === 'yes' && loginctl.Remote === 'no'
      && loginctl.Class === 'user' && ['active', 'online'].includes(loginctl.State),
    'P-31 logind identity is not an active local GNOME X11 user session');
  }
  if (windowManager) {
    assert(/(?:gnome shell|mutter)/iu.test(windowManager),
      'P-31 window manager is not GNOME Shell/Mutter');
  }
  return {
    environmentId: ENVIRONMENT,
    architecture,
    desktop: 'GNOME',
    session: 'X11',
    compositor: 'Mutter'
  };
}

function assertOwnerOnlyDirectory(directory, label) {
  fs.mkdirSync(directory, { recursive: true, mode: 0o700 });
  const link = fs.lstatSync(directory);
  const stat = fs.statSync(directory);
  assert(link.isDirectory() && !link.isSymbolicLink() && stat.uid === process.getuid()
    && (stat.mode & 0o077) === 0, `${label} must be an owner-only real directory`);
}

function assertRealOwnedDirectory(directory, label) {
  const link = fs.lstatSync(directory);
  const stat = fs.statSync(directory);
  assert(link.isDirectory() && !link.isSymbolicLink() && stat.uid === process.getuid()
    && (stat.mode & 0o022) === 0, `${label} must be a real non-writable-by-others directory`);
}

function assertInside(root, candidate, label) {
  const relative = path.relative(root, candidate);
  assert(relative !== '..' && !relative.startsWith(`..${path.sep}`) && !path.isAbsolute(relative),
    `${label} must remain inside ${root}`);
}

function atomicJson(file, value) {
  const temporary = `${file}.tmp-${process.pid}-${Date.now()}`;
  fs.writeFileSync(temporary, `${JSON.stringify(value, null, 2)}\n`, { mode: 0o600, flag: 'wx' });
  fs.renameSync(temporary, file);
}

export function applyGnomeAccessibilityPreferences(rawDir, {
  invoke = (args, label) => required('gsettings', args, label)
} = {}) {
  const preferences = [
    { key: 'scaling-factor', value: '2', expected: /^uint32 2$/u },
    { key: 'gtk-theme', value: 'HighContrast', expected: /^'HighContrast'$/u },
    { key: 'enable-animations', value: 'false', expected: /^false$/u }
  ];
  const changed = [];
  const restore = () => {
    const errors = [];
    for (const preference of [...changed].reverse()) {
      try {
        invoke([
          'set', 'org.gnome.desktop.interface', preference.key, preference.original
        ], `P-31 restore GNOME ${preference.key}`);
        const observed = invoke([
          'get', 'org.gnome.desktop.interface', preference.key
        ], `P-31 verify restored GNOME ${preference.key}`);
        assert(observed === preference.original,
          `P-31 GNOME ${preference.key} was not restored exactly`);
      } catch (error) {
        errors.push(error);
      }
    }
    if (errors.length) throw new AggregateError(errors, 'P-31 GNOME preference restoration failed');
  };
  try {
    for (const preference of preferences) {
      const original = invoke([
        'get', 'org.gnome.desktop.interface', preference.key
      ], `P-31 read GNOME ${preference.key}`);
      changed.push({ ...preference, original });
      invoke([
        'set', 'org.gnome.desktop.interface', preference.key, preference.value
      ], `P-31 set GNOME ${preference.key}`);
      const observed = invoke([
        'get', 'org.gnome.desktop.interface', preference.key
      ], `P-31 verify GNOME ${preference.key}`);
      assert(preference.expected.test(observed),
        `P-31 GNOME ${preference.key} did not reach its required live value`);
      preference.observed = observed;
    }
    const evidence = {
      producer: 'openburnbar-p31-gnome-accessibility-preferences-v1',
      desktop: 'GNOME',
      session: 'X11',
      scalingFactor: preferences[0].observed,
      gtkTheme: preferences[1].observed,
      enableAnimations: preferences[2].observed,
      pass: true
    };
    const evidenceFile = path.join(rawDir, 'p31-gnome-accessibility-settings.json');
    atomicJson(evidenceFile, evidence);
    return { evidence, evidenceFile, restore };
  } catch (error) {
    try {
      restore();
    } catch (restoreError) {
      throw new AggregateError([error, restoreError],
        'P-31 GNOME preference application and restoration failed');
    }
    throw error;
  }
}

function exactDesktopPids() {
  return fs.readdirSync('/proc')
    .filter((entry) => /^[1-9][0-9]*$/u.test(entry))
    .filter((entry) => {
      try {
        return fs.realpathSync(`/proc/${entry}/exe`) === DESKTOP;
      } catch {
        return false;
      }
    })
    .map(Number)
    .sort((left, right) => left - right);
}

async function terminateNewDesktopProcesses(baseline) {
  const baselineSet = new Set(baseline);
  let extras = exactDesktopPids().filter((pid) => !baselineSet.has(pid));
  for (const pid of extras) {
    try {
      process.kill(pid, 'SIGTERM');
    } catch (error) {
      if (error.code !== 'ESRCH') throw error;
    }
  }
  try {
    await waitFor('P-31 installed desktop exit', () => {
      extras = exactDesktopPids().filter((pid) => !baselineSet.has(pid));
      assert(extras.length === 0, `desktop PIDs still running: ${extras.join(',')}`);
      return true;
    }, 5_000);
  } catch {
    for (const pid of extras) {
      try {
        process.kill(pid, 'SIGKILL');
      } catch (error) {
        if (error.code !== 'ESRCH') throw error;
      }
    }
    await waitFor('P-31 installed desktop forced exit', () => {
      const remaining = exactDesktopPids().filter((pid) => !baselineSet.has(pid));
      assert(remaining.length === 0, `desktop PIDs still running: ${remaining.join(',')}`);
      return true;
    }, 5_000);
  }
  assert(JSON.stringify(exactDesktopPids()) === JSON.stringify(baseline),
    'P-31 installed desktop process baseline was not restored');
}

async function stopSpawnedProcess(child, label) {
  if (!child || child.pid === undefined || child.exitCode !== null || child.signalCode !== null) return;
  child.kill('SIGTERM');
  try {
    await waitFor(`${label} exit`, () => {
      assert(child.exitCode !== null || child.signalCode !== null, `${label} still running`);
      return true;
    }, 5_000);
  } catch {
    child.kill('SIGKILL');
    await waitFor(`${label} forced exit`, () => {
      assert(child.exitCode !== null || child.signalCode !== null, `${label} still running`);
      return true;
    }, 5_000);
  }
}

function daemonActive() {
  const result = run('systemctl', ['--user', 'is-active', '--quiet', 'openburnbar-daemon.service']);
  assert(result.status === 0 || result.status === 3,
    `P-31 could not read package daemon state (${result.status})`);
  return result.status === 0;
}

function restoreDaemonState(wasActive) {
  if (daemonActive() !== wasActive) {
    required('systemctl', [
      '--user', wasActive ? 'start' : 'stop', 'openburnbar-daemon.service'
    ], 'P-31 restore package daemon state');
  }
  assert(daemonActive() === wasActive, 'P-31 package daemon state was not restored');
}

async function reservePort() {
  return new Promise((resolve, reject) => {
    const server = net.createServer();
    server.once('error', reject);
    server.listen(0, '127.0.0.1', () => {
      const address = server.address();
      server.close((error) => error ? reject(error) : resolve(address.port));
    });
  });
}

async function request(base, method, endpoint, body) {
  const response = await fetch(new URL(endpoint, base), {
    method,
    headers: body === undefined ? undefined : { 'content-type': 'application/json' },
    body: body === undefined ? undefined : JSON.stringify(body),
    signal: AbortSignal.timeout(30_000)
  });
  const text = await response.text();
  const value = text ? JSON.parse(text) : null;
  assert(response.ok, `P-31 WebDriver ${method} ${endpoint} failed (${response.status}): ${text}`);
  return value?.value ?? value;
}

async function waitFor(label, operation, timeoutMs = 30_000) {
  const deadline = Date.now() + timeoutMs;
  let last;
  while (Date.now() < deadline) {
    try {
      return await operation();
    } catch (error) {
      last = error;
      await wait(250);
    }
  }
  throw new Error(`${label} timed out: ${last?.message ?? 'unavailable'}`);
}

function pngDimensions(bytes) {
  const signature = Buffer.from([137, 80, 78, 71, 13, 10, 26, 10]);
  assert(bytes.length >= 24 && bytes.subarray(0, 8).equals(signature),
    'P-31 WebDriver screenshot is not a PNG');
  return { width: bytes.readUInt32BE(16), height: bytes.readUInt32BE(20) };
}

function webdriver(environment) {
  let child = null;
  let base = null;
  let sessionId = null;
  return {
    async start() {
      required('which', ['tauri-driver'], 'P-31 tauri-driver prerequisite', { env: environment });
      required('which', ['WebKitWebDriver'], 'P-31 WebKitWebDriver prerequisite', { env: environment });
      const selected = await reservePort();
      base = `http://127.0.0.1:${selected}/`;
      child = spawn('tauri-driver', ['--port', String(selected)], { env: environment, stdio: 'ignore' });
      child.unref();
      await waitFor('P-31 tauri-driver readiness', () => request(base, 'GET', '/status'));
      const value = await request(base, 'POST', '/session', {
        capabilities: {
          alwaysMatch: {
            browserName: 'wry',
            'tauri:options': { application: DESKTOP }
          }
        }
      });
      sessionId = value?.sessionId;
      assert(typeof sessionId === 'string' && sessionId.length > 0, 'P-31 WebDriver session is absent');
      await request(base, 'POST', `/session/${sessionId}/timeouts`, { script: 30_000 });
      await wait(1_200);
    },
    execute(script, args = []) {
      assert(sessionId, 'P-31 WebDriver session is inactive');
      return request(base, 'POST', `/session/${sessionId}/execute/sync`, { script, args });
    },
    async screenshot(file) {
      const encoded = await request(base, 'GET', `/session/${sessionId}/screenshot`);
      assert(typeof encoded === 'string' && /^[A-Za-z0-9+/]+=*$/u.test(encoded),
        'P-31 WebDriver screenshot response is not canonical base64');
      const bytes = Buffer.from(encoded, 'base64');
      assert(bytes.length >= 1024, 'P-31 WebDriver screenshot is empty');
      fs.writeFileSync(file, bytes, { mode: 0o600, flag: 'wx' });
      return pngDimensions(bytes);
    },
    async stop() {
      if (sessionId) {
        try {
          await request(base, 'DELETE', `/session/${sessionId}`);
        } catch {
          // The producer still terminates and verifies the driver process below.
        }
      }
      sessionId = null;
      if (child) {
        const current = child;
        current.kill('SIGTERM');
        try {
          await waitFor('P-31 tauri-driver exit', () => {
            assert(current.exitCode !== null || current.signalCode !== null, 'driver still running');
            return true;
          }, 5_000);
        } catch {
          current.kill('SIGKILL');
          await waitFor('P-31 tauri-driver forced exit', () => {
            assert(current.exitCode !== null || current.signalCode !== null, 'driver still running');
            return true;
          }, 5_000);
        }
      }
      child = null;
    }
  };
}

const RUNTIME_STATE_SCRIPT = `
const visible = (element) => {
  const style = getComputedStyle(element);
  const rect = element.getBoundingClientRect();
  return style.display !== 'none' && style.visibility !== 'hidden' && Number(style.opacity) > 0
    && rect.width > 0 && rect.height > 0;
};
const parseSeconds = (value) => value.split(',').map((part) => {
  const token = part.trim();
  return token.endsWith('ms') ? Number.parseFloat(token) / 1000 : Number.parseFloat(token);
}).filter(Number.isFinite);
const visibleElements = [...document.querySelectorAll('*')].filter(visible);
const animated = visibleElements.filter((element) => {
  const style = getComputedStyle(element);
  return [...parseSeconds(style.animationDuration), ...parseSeconds(style.transitionDuration)]
    .some((duration) => duration > 0);
});
const liveRegions = visibleElements.filter((element) => element.matches('[aria-live], [role=status], [role=alert], [role=log]'));
const namedControls = visibleElements.filter((element) => element.matches('button,input,select,textarea,a[href],[role=button],[role=tab]'))
  .filter((element) => (element.getAttribute('aria-label') || element.textContent || '').trim().length > 0);
const horizontalScrollbars = visibleElements.filter((element) => {
  const style = getComputedStyle(element);
  return element.scrollWidth > element.clientWidth + 1 && /(auto|scroll)/u.test(style.overflowX);
}).length;
return {
  dpr: window.devicePixelRatio,
  viewport: { width: window.innerWidth, height: window.innerHeight },
  forcedColors: matchMedia('(forced-colors: active)').matches,
  reducedMotion: matchMedia('(prefers-reduced-motion: reduce)').matches,
  animationsObserved: document.getAnimations().filter((animation) => animation.playState === 'running').length,
  transitionsObserved: animated.length,
  liveRegionCount: liveRegions.length,
  namedControlCount: namedControls.length,
  horizontalScrollbars,
  activeName: (document.activeElement?.getAttribute('aria-label') || document.activeElement?.textContent || '').trim()
};`;

async function captureDriverEvidence(driver, rawDir, gnomePreferences) {
  const routeAudits = [];
  for (const route of P31_REQUIRED_ROUTES) {
    const expectedHash = `#/${route}`;
    const expectedLabel = ROUTE_LABELS[route];
    assert(expectedLabel, `P-31 has no route identity contract for ${route}`);
    await driver.execute("location.hash=arguments[0];return location.hash;", [expectedHash]);
    const routeIdentity = await waitFor(`P-31 WebDriver route ${route}`, async () => {
      const observed = await driver.execute(`
        const expectedHash=arguments[0],expectedLabel=arguments[1];
        const main=document.getElementById('main');
        const title=document.getElementById('route-title');
        const label=(title?.textContent||'').trim();
        return {hash:location.hash,label,inMain:!!main&&!!title&&main.contains(title),
          pass:location.hash===expectedHash&&label===expectedLabel&&!!main&&!!title&&main.contains(title)};
      `, [expectedHash, expectedLabel]);
      assert(observed?.pass === true,
        `P-31 WebDriver route identity mismatch for ${route}: ${JSON.stringify(observed)}`);
      return observed;
    }, 10_000);
    const layout = await driver.execute(P36_LAYOUT_SCRIPT, ['p31-exact-200-percent']);
    const focused = await driver.execute(
      "const e=document.querySelector('a[href=\"#main\"],button:not([disabled]),a[href],input:not([disabled])');e?.focus();return !!e&&document.activeElement===e&&e.matches(':focus-visible');"
    );
    routeAudits.push({ route, expectedLabel, routeIdentity, layout, focusPreserved: focused === true });
  }
  const layoutPath = path.join(rawDir, 'p31-scale-route-audit.json');
  atomicJson(layoutPath, { producer: 'openburnbar-p31-webkit-scale-audit-v1', routes: routeAudits });

  const scaleAtspi = path.join(rawDir, 'p31-scale-atspi.json');
  required('python3', [
    ATSPI, '--application', 'OpenBurnBar', '--mode', 'summary',
    '--expected-name', 'SmartHub / IoT', '--route', 'smarthub',
    '--output', scaleAtspi, '--min-nodes', '12', '--min-named', '6',
    '--min-actionable', '3', '--wait-for-meaningful-seconds', '5'
  ], 'P-31 exact-scale AT-SPI capture');
  const scaleAtspiDocument = JSON.parse(fs.readFileSync(scaleAtspi, 'utf8'));
  assert(scaleAtspiDocument.pass === true, 'P-31 exact-scale AT-SPI capture failed');

  const runtime = await driver.execute(RUNTIME_STATE_SCRIPT);
  assert(runtime?.dpr === 2, 'P-31 WebKit devicePixelRatio is not exactly 2');
  assert(runtime.forcedColors === true, 'P-31 WebKit did not observe forced-colors from the real HighContrast session');
  assert(runtime.reducedMotion === true, 'P-31 WebKit did not observe the real reduced-motion preference');
  assert(runtime.animationsObserved === 0 && runtime.transitionsObserved === 0,
    'P-31 reduced-motion session retained running animation or transition');
  assert(runtime.liveRegionCount > 0 && runtime.namedControlCount > 0,
    'P-31 WebKit exposed no live regions or named controls');
  assert(routeAudits.every((row) => row.routeIdentity?.pass === true
    && row.layout?.horizontalOverflow === 0
    && row.layout?.clippedCount === 0 && row.focusPreserved === true),
  'P-31 exact 200 percent route audit found route drift, clipping, overflow, or focus loss');

  const scaleScreenshot = path.join(rawDir, 'p31-scale-200.png');
  const scalePng = await driver.screenshot(scaleScreenshot);
  assert(scalePng.width === runtime.viewport.width * 2 && scalePng.height === runtime.viewport.height * 2,
    'P-31 200 percent screenshot pixels do not match the exact WebKit scale');

  const contrast = await driver.execute(P36_THEME_SCRIPT, ['light']);
  assert(Number.isFinite(contrast?.contrastRatio) && contrast.contrastRatio >= 4.5
    && contrast.nativeControlCount > 0, 'P-31 HighContrast controls do not meet semantic contrast');
  const highContrastScreenshot = path.join(rawDir, 'p31-high-contrast.png');
  await driver.screenshot(highContrastScreenshot);

  const noColor = await driver.execute(`
    document.documentElement.style.filter='grayscale(1)';
    const controls=[...document.querySelectorAll('button,input,select,textarea,a[href],[role=button],[role=tab]')]
      .filter((element)=>{const s=getComputedStyle(element),r=element.getBoundingClientRect();return s.display!=='none'&&s.visibility!=='hidden'&&r.width>0&&r.height>0;});
    return {filter:getComputedStyle(document.documentElement).filter,controlCount:controls.length,
      namedCount:controls.filter((element)=>(element.getAttribute('aria-label')||element.textContent||'').trim()).length};
  `);
  assert(noColor?.filter === 'grayscale(1)' && noColor.controlCount > 0
    && noColor.namedCount === noColor.controlCount,
  'P-31 no-color rendering left unnamed or color-only controls');
  const noColorScreenshot = path.join(rawDir, 'p31-no-color.png');
  await driver.screenshot(noColorScreenshot);
  const forcedColorsScreenshot = path.join(rawDir, 'p31-forced-colors.png');
  await driver.execute("document.documentElement.style.filter='none';return matchMedia('(forced-colors: active)').matches;");
  await driver.screenshot(forcedColorsScreenshot);

  const runtimePath = path.join(rawDir, 'p31-runtime-state.json');
  atomicJson(runtimePath, {
    producer: 'openburnbar-p31-webkit-runtime-v1',
    ...runtime,
    contrast,
    noColor,
    scalePng,
    gnomePreferences
  });
  return {
    runtime,
    routeAudits,
    evidence: {
      layout: path.basename(layoutPath),
      scaleAtspi: path.basename(scaleAtspi),
      scaleScreenshot: path.basename(scaleScreenshot),
      highContrastScreenshot: path.basename(highContrastScreenshot),
      noColorScreenshot: path.basename(noColorScreenshot),
      forcedColorsScreenshot: path.basename(forcedColorsScreenshot),
      runtime: path.basename(runtimePath),
      gnomeSettings: 'p31-gnome-accessibility-settings.json'
    }
  };
}

async function captureKeyboardAndOrca(rawDir, orcaDebug, physicalTabPresses = 28, physicalShiftTabPresses = 12) {
  const windowIds = required('xdotool', [
    'search', '--onlyvisible', '--name', '^OpenBurnBar$'
  ], 'P-31 installed window lookup').split(/\s+/u).filter(Boolean);
  assert(windowIds.length === 1 && /^[0-9]+$/u.test(windowIds[0]),
    'P-31 requires exactly one installed WebDriver window');
  const windowId = windowIds[0];
  const windowPid = required('xdotool', ['getwindowpid', windowId], 'P-31 installed window PID');
  assert(/^[1-9][0-9]*$/u.test(windowPid), 'P-31 installed window PID is invalid');
  const executable = fs.realpathSync(`/proc/${windowPid}/exe`);
  assert(executable === DESKTOP,
    `P-31 keyboard window is not owned by ${DESKTOP}: ${executable}`);
  const forwardAnchor = path.join(rawDir, 'p31-focus-forward-anchor.json');
  required('python3', [
    ATSPI, '--application', 'OpenBurnBar', '--mode', 'grab-focus',
    '--expected-name', 'Skip to content', '--output', forwardAnchor
  ], 'P-31 keyboard focus anchor');
  await wait(500);
  const focusLogOffset = fs.statSync(orcaDebug).size;
  const observations = [];
  for (let index = 0; index < physicalTabPresses; index += 1) {
    required('xdotool', ['windowfocus', '--sync', windowId], 'P-31 window focus');
    required('xdotool', ['key', '--window', windowId, '--clearmodifiers', 'Tab'], 'P-31 physical Tab');
    await wait(1_250);
    const focused = path.join(rawDir, `p31-focus-${String(index + 1).padStart(2, '0')}.json`);
    required('python3', [
      ATSPI, '--application', 'OpenBurnBar', '--mode', 'focus',
      '--output', focused, '--timeout-seconds', '10'
    ], `P-31 focused AT-SPI step ${index + 1}`);
    observations.push(JSON.parse(fs.readFileSync(focused, 'utf8')));
  }
  const reverseAnchor = path.join(rawDir, 'p31-focus-reverse-anchor.json');
  required('python3', [
    ATSPI, '--application', 'OpenBurnBar', '--mode', 'grab-focus',
    '--expected-name', 'Skip to content', '--output', reverseAnchor
  ], 'P-31 reverse keyboard focus anchor');
  await wait(1_000);
  for (let index = 0; index < physicalShiftTabPresses; index += 1) {
    required('xdotool', ['windowfocus', '--sync', windowId], 'P-31 reverse window focus');
    required('xdotool', ['key', '--window', windowId, '--clearmodifiers', 'shift+Tab'], 'P-31 physical Shift+Tab');
    await wait(1_250);
  }
  await wait(8_000);
  const debugBytes = fs.readFileSync(orcaDebug);
  const focusDebug = debugBytes.subarray(focusLogOffset).toString('utf8');
  const fullDebug = debugBytes.toString('utf8');
  const focusEvents = [...focusDebug.matchAll(
    /OBJECT EVENT: object:state-changed:focused for \[([^:\]]+): '([^']*)'\] in \[application: '([^']+)'\] \(1,\s*0,\s*0\)/gu
  )].filter((match) => /openburnbar/iu.test(match[3]));
  const focusedNodes = observations.flatMap((row) => row?.focusedNodes ?? []);
  const named = focusedNodes.map((row) => row?.name ?? '')
    .filter((name) => typeof name === 'string' && name.trim());
  const identities = new Set(focusedNodes.map((row) => `${row?.role ?? ''}:${row?.name ?? ''}`));
  const announcementEvents = fullDebug.match(
    /OBJECT EVENT: object:(?:text-changed|property-change:accessible-name)[^\n]*\[application: 'OpenBurnBar'\]/giu
  ) ?? [];
  const focusTrap = identities.size < 3;
  const result = {
    producer: 'openburnbar-p31-orca-focus-v1',
    physicalTabPressCount: physicalTabPresses,
    physicalShiftTabPressCount: physicalShiftTabPresses,
    physicalKeyPressCount: physicalTabPresses + physicalShiftTabPresses,
    stepCount: focusedNodes.length,
    distinctFocusedTargets: identities.size,
    namedFocusedTargets: named.length,
    trueFocusEventCount: focusEvents.length,
    announcementEventCount: announcementEvents.length,
    focusTrap,
    pass: focusedNodes.length >= 10 && identities.size >= 3 && named.length >= 3
      && !focusTrap && focusEvents.length >= 10 && announcementEvents.length > 0
  };
  assert(result.pass, 'P-31 Orca/AT-SPI keyboard traversal did not meet the live evidence threshold');
  atomicJson(path.join(rawDir, 'p31-keyboard-orca.json'), result);
  return result;
}

function relativeEvidence(outputRoot, file) {
  return path.relative(outputRoot, file).split(path.sep).join('/');
}

export function buildP31LiveSession({
  options,
  identity,
  navigation,
  driverEvidence,
  keyboard,
  rawDir
}) {
  const evidence = (name) => relativeEvidence(options.outputRoot, path.join(rawDir, name));
  const routes = navigation.routes.map((row) => row.route);
  assert(routes.length === P31_REQUIRED_ROUTES.length
    && new Set(routes).size === P31_REQUIRED_ROUTES.length
    && P31_REQUIRED_ROUTES.every((route) => routes.includes(route)),
  'P-31 native navigation did not cover every required route');
  const auditedRoutes = driverEvidence.routeAudits.map((row) => row.route);
  assert(auditedRoutes.length === P31_REQUIRED_ROUTES.length
    && new Set(auditedRoutes).size === P31_REQUIRED_ROUTES.length
    && P31_REQUIRED_ROUTES.every((route) => auditedRoutes.includes(route)),
  'P-31 WebDriver did not audit every required route exactly once');
  const routeAuditPassed = driverEvidence.routeAudits.every((row) =>
    row.routeIdentity?.pass === true && row.routeIdentity.hash === `#/${row.route}`
    && row.routeIdentity.label === ROUTE_LABELS[row.route]
    && row.layout.horizontalOverflow === 0 && row.layout.clippedCount === 0
    && row.focusPreserved === true);
  const runtime = driverEvidence.runtime;
  const document = {
    schemaVersion: 1,
    id: 'openburnbar-linux-p31-live-session-v1',
    requirementId: 'P-31',
    environmentId: options.environmentId,
    targetHead: options.targetHead,
    candidate: {
      runId: options.candidateRunId,
      artifactDigest: options.candidateArtifactDigest
    },
    package: {
      architecture: identity.architecture,
      format: 'deb',
      installed: true,
      manifestSha256: options.manifestSha256,
      source: 'signed-installed-candidate',
      version: options.packageVersion
    },
    desktop: {
      compositor: identity.compositor,
      desktop: identity.desktop,
      liveSession: true,
      session: identity.session
    },
    observations: {
      scale: {
        accessibilityTreeObserved: true,
        clippedCount: Math.max(...driverEvidence.routeAudits.map((row) => row.layout.clippedCount)),
        exactScaleObservable: runtime.dpr === 2,
        evidencePaths: [
          evidence(driverEvidence.evidence.layout),
          evidence(driverEvidence.evidence.scaleAtspi),
          evidence(driverEvidence.evidence.scaleScreenshot),
          evidence(driverEvidence.evidence.runtime),
          evidence(driverEvidence.evidence.gnomeSettings)
        ],
        focusPreserved: driverEvidence.routeAudits.every((row) => row.focusPreserved),
        horizontalScrollbars: runtime.horizontalScrollbars,
        method: 'installed-WebKitGTK live desktop exact GDK scale with raster readback',
        observedPercent: runtime.dpr * 100,
        overflowCount: Math.max(...driverEvidence.routeAudits.map((row) => row.layout.horizontalOverflow)),
        reflowPass: routeAuditPassed,
        requestedPercent: 200
      },
      contrast: {
        evidencePaths: [
          evidence(driverEvidence.evidence.forcedColorsScreenshot),
          evidence(driverEvidence.evidence.highContrastScreenshot),
          evidence(driverEvidence.evidence.noColorScreenshot),
          evidence(driverEvidence.evidence.runtime),
          evidence(driverEvidence.evidence.gnomeSettings)
        ],
        forcedColors: {
          evidencePath: evidence(driverEvidence.evidence.forcedColorsScreenshot),
          mode: 'forced-colors',
          observed: runtime.forcedColors,
          pass: runtime.forcedColors,
          test: 'WebKit forced-colors media query under the real GTK HighContrast theme'
        },
        highContrast: {
          evidencePath: evidence(driverEvidence.evidence.highContrastScreenshot),
          mode: 'high-contrast',
          observed: driverEvidence.runtime.forcedColors,
          pass: driverEvidence.runtime.forcedColors,
          test: 'GTK HighContrast plus computed native-control contrast ratio'
        },
        method: 'installed-live contrast and no-color rendering',
        noColor: {
          evidencePath: evidence(driverEvidence.evidence.noColorScreenshot),
          mode: 'no-color',
          observed: true,
          pass: true,
          test: 'live grayscale rendering retains an accessible name for every visible control'
        },
        semanticContrastPass: true
      },
      motion: {
        animationsObserved: runtime.animationsObserved,
        evidencePaths: [
          evidence(driverEvidence.evidence.runtime),
          evidence(driverEvidence.evidence.scaleScreenshot),
          evidence(driverEvidence.evidence.gnomeSettings)
        ],
        mediaQuery: '(prefers-reduced-motion: reduce)',
        method: 'installed-live motion preference with computed runtime styles',
        reducedMotion: {
          enabled: true,
          observed: runtime.reducedMotion,
          pass: runtime.reducedMotion
        },
        runtimeStylesPass: runtime.animationsObserved === 0 && runtime.transitionsObserved === 0,
        transitionsObserved: runtime.transitionsObserved
      },
      assistiveTech: {
        evidencePaths: [
          evidence('p31-keyboard-orca.json'),
          evidence('orca-debug.log'),
          evidence('packaged-route-session-transcript.json'),
          ...navigation.routes.map((row) => evidence(row.atspi))
        ],
        keyboard: {
          distinctFocusedTargets: keyboard.distinctFocusedTargets,
          focusTrap: keyboard.focusTrap,
          namedFocusedTargets: keyboard.namedFocusedTargets,
          pass: keyboard.pass,
          physicalKeyPressCount: keyboard.physicalKeyPressCount,
          stepCount: keyboard.stepCount
        },
        liveRegionsAnnounced: keyboard.announcementEventCount > 0,
        method: 'installed-live Orca AT-SPI keyboard traversal',
        routesCovered: [...P31_REQUIRED_ROUTES],
        screenReader: {
          announcementsObserved: keyboard.announcementEventCount > 0,
          name: 'Orca',
          processObserved: true,
          treeObserved: navigation.routes.every((row) => row.atspi)
        }
      }
    }
  };
  return validateP31LiveSession(document, {
    environmentId: options.environmentId,
    targetHead: options.targetHead,
    candidateRunId: options.candidateRunId,
    candidateArtifactDigest: options.candidateArtifactDigest
  });
}

export function parseP31LiveArguments(argv) {
  const flags = [
    '--output-root', '--raw-output-dir', '--state-home', '--environment', '--target-head',
    '--candidate-run-id', '--candidate-artifact-digest', '--package-version',
    '--manifest-sha256', '--manifest-signature-sha256', '--compositor'
  ];
  const values = new Map();
  for (let index = 0; index < argv.length; index += 2) {
    const flag = argv[index];
    const value = argv[index + 1];
    if (!flags.includes(flag) || value === undefined || values.has(flag)) {
      fail(`invalid argument: ${flag ?? '<missing>'}`);
    }
    values.set(flag, value);
  }
  for (const flag of flags) if (!values.has(flag)) fail(`${flag} is required`);
  const options = {
    outputRoot: path.resolve(values.get('--output-root')),
    rawOutputDir: path.resolve(values.get('--raw-output-dir')),
    stateHome: path.resolve(values.get('--state-home')),
    environmentId: values.get('--environment'),
    targetHead: values.get('--target-head'),
    candidateRunId: values.get('--candidate-run-id'),
    candidateArtifactDigest: values.get('--candidate-artifact-digest'),
    packageVersion: values.get('--package-version'),
    manifestSha256: values.get('--manifest-sha256'),
    manifestSignatureSha256: values.get('--manifest-signature-sha256'),
    compositor: values.get('--compositor')
  };
  assert(options.environmentId === ENVIRONMENT,
    `P-31 live producer currently requires exactly ${ENVIRONMENT}`);
  assert(HEAD.test(options.targetHead) && RUN_ID.test(options.candidateRunId)
    && DIGEST.test(options.candidateArtifactDigest) && VERSION.test(options.packageVersion)
    && SHA256.test(options.manifestSha256) && SHA256.test(options.manifestSignatureSha256),
  'P-31 candidate binding is invalid');
  assert(options.compositor === 'Mutter' && !FORBIDDEN_SESSION.test(options.compositor),
    'P-31 UTM producer requires the Mutter compositor');
  return options;
}

export async function runP31LiveAccessibilitySession(options) {
  const repository = fs.realpathSync(ROOT);
  assertInside(repository, options.outputRoot, 'P-31 output root');
  assertInside(options.outputRoot, options.rawOutputDir, 'P-31 raw output');
  assertRealOwnedDirectory(options.outputRoot, 'P-31 output root');
  assertOwnerOnlyDirectory(options.rawOutputDir, 'P-31 raw output');
  assertOwnerOnlyDirectory(options.stateHome, 'P-31 state home');
  assert(fs.readdirSync(options.rawOutputDir).length === 0,
    'P-31 raw output must be empty at producer start');
  const stateEnvironment = {
    ...process.env,
    HOME: options.stateHome,
    XDG_CONFIG_HOME: path.join(options.stateHome, '.config'),
    XDG_CACHE_HOME: path.join(options.stateHome, '.cache'),
    XDG_DATA_HOME: path.join(options.stateHome, '.local/share')
  };
  for (const directory of [
    stateEnvironment.XDG_CONFIG_HOME,
    stateEnvironment.XDG_CACHE_HOME,
    stateEnvironment.XDG_DATA_HOME
  ]) assertOwnerOnlyDirectory(directory, 'P-31 isolated application state');
  fs.rmSync(path.join(options.outputRoot, 'p31-live-session.json'), { force: true });

  const sessionId = process.env.XDG_SESSION_ID;
  assert(sessionId && /^[A-Za-z0-9_-]+$/u.test(sessionId), 'P-31 requires XDG_SESSION_ID');
  const loginctl = parseLoginctl(required('loginctl', [
    'show-session', sessionId, '--property=Type', '--property=Desktop', '--property=Class',
    '--property=Active', '--property=Remote', '--property=State'
  ], 'P-31 logind identity'));
  const windowManager = required('wmctrl', ['-m'], 'P-31 window manager identity');
  required('pgrep', ['-x', 'gnome-shell'], 'P-31 GNOME Shell process');
  const identity = validateP31HostIdentity({ loginctl, windowManager });
  assert(options.compositor === identity.compositor, 'P-31 compositor argument does not match the live host');

  verifyInstalledCandidate(options);
  for (const tool of ['python3', 'gsettings', 'orca', 'xdotool', 'wmctrl', 'xrandr', 'xwininfo', 'scrot']) {
    required('sh', ['-c', 'command -v "$1" >/dev/null', 'p31-tool', tool], `P-31 required tool ${tool}`);
  }
  const desktopBaseline = exactDesktopPids();
  assert(desktopBaseline.length === 0,
    'P-31 live producer requires no pre-existing installed desktop process');
  const daemonWasActive = daemonActive();
  let preferences = null;
  let orca = null;
  let driver = null;
  let report = null;
  let primaryError = null;
  try {
    required('systemctl', ['--user', 'restart', 'openburnbar-daemon.service'],
      'P-31 package daemon restart');
    required('systemctl', ['--user', 'is-active', '--quiet', 'openburnbar-daemon.service'],
      'P-31 package daemon active readback');
    const daemonHealth = required('/usr/bin/openburnbar-cli', ['health'], 'P-31 package daemon health');
    fs.writeFileSync(path.join(options.rawOutputDir, 'daemon-health.txt'),
      `${daemonHealth}\n`, { mode: 0o600 });
    preferences = applyGnomeAccessibilityPreferences(options.rawOutputDir);
    const orcaDebug = path.join(options.rawOutputDir, 'orca-debug.log');
    const orcaVersion = required('orca', ['--version'], 'P-31 Orca version');
    fs.writeFileSync(path.join(options.rawOutputDir, 'orca-version.txt'), `${orcaVersion}\n`, { mode: 0o600 });
    let orcaSpawnError = null;
    orca = spawn('orca', [
      '--replace', '--disable', 'speech', '--disable', 'braille', '--disable', 'braille-monitor',
      `--debug-file=${orcaDebug}`
    ], { env: process.env, stdio: 'ignore' });
    orca.once('error', (error) => {
      orcaSpawnError = error;
    });
    orca.unref();
    await waitFor('P-31 Orca process', () => {
      if (orcaSpawnError) throw orcaSpawnError;
      const result = run('kill', ['-0', String(orca.pid)]);
      assert(result.status === 0 && orca.exitCode === null, 'Orca is not running');
      return true;
    });
    fs.writeFileSync(path.join(options.rawOutputDir, 'orca-process.txt'),
      `pid=${orca.pid}\nversion=${orcaVersion}\n`, { mode: 0o600 });

    const navigationArgs = [
      P09, '--output-dir', options.rawOutputDir, '--environment', options.environmentId,
      '--target-head', options.targetHead, '--candidate-run-id', options.candidateRunId,
      '--candidate-artifact-digest', options.candidateArtifactDigest,
      '--package-version', options.packageVersion, '--manifest-sha256', options.manifestSha256,
      '--manifest-signature-sha256', options.manifestSignatureSha256,
      '--compositor', options.compositor
    ];
    required(process.execPath, navigationArgs, 'P-31 native route and AT-SPI capture', {
      env: { ...stateEnvironment, OPENBURNBAR_LINUX_FIXTURE_MODE: '0' },
      timeout: 20 * 60_000
    });
    assert(exactDesktopPids().length === 0,
      'P-31 native navigation probe leaked an installed desktop process');
    const navigation = JSON.parse(fs.readFileSync(
      path.join(options.rawOutputDir, 'packaged-route-session-transcript.json'), 'utf8'
    ));
    assert(navigation.surface === 'installed-tauri-native-session'
      && navigation.routes?.length === P09_REQUIRED_ROUTES.length,
    'P-31 navigation transcript is not a complete installed session');

    const driverEnvironment = {
      ...stateEnvironment,
      OPENBURNBAR_LINUX_FIXTURE_MODE: '0',
      OPENBURNBAR_EVIDENCE_OUT: options.rawOutputDir
    };
    driver = webdriver(driverEnvironment);
    await driver.start();
    const driverEvidence = await captureDriverEvidence(
      driver,
      options.rawOutputDir,
      preferences.evidence
    );
    const keyboard = await captureKeyboardAndOrca(options.rawOutputDir, orcaDebug);
    report = buildP31LiveSession({
      options,
      identity,
      navigation,
      driverEvidence,
      keyboard,
      rawDir: options.rawOutputDir
    });
  } catch (error) {
    primaryError = error;
  }

  const cleanupErrors = [];
  if (driver) {
    try {
      await driver.stop();
    } catch (error) {
      cleanupErrors.push(error);
    }
  }
  try {
    await terminateNewDesktopProcesses(desktopBaseline);
  } catch (error) {
    cleanupErrors.push(error);
  }
  try {
    await stopSpawnedProcess(orca, 'P-31 Orca');
  } catch (error) {
    cleanupErrors.push(error);
  }
  if (preferences) {
    try {
      preferences.restore();
    } catch (error) {
      cleanupErrors.push(error);
    }
  }
  try {
    restoreDaemonState(daemonWasActive);
  } catch (error) {
    cleanupErrors.push(error);
  }

  if (primaryError || cleanupErrors.length) {
    fs.rmSync(path.join(options.outputRoot, 'p31-live-session.json'), { force: true });
    if (primaryError && cleanupErrors.length) {
      throw new AggregateError([primaryError, ...cleanupErrors],
        'P-31 live accessibility session and restoration failed');
    }
    if (primaryError) throw primaryError;
    throw new AggregateError(cleanupErrors, 'P-31 live accessibility restoration failed');
  }
  assert(report, 'P-31 live producer completed without a report');
  atomicJson(path.join(options.outputRoot, 'p31-live-session.json'), report);
  return report;
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  try {
    const options = parseP31LiveArguments(process.argv.slice(2));
    const report = await runP31LiveAccessibilitySession(options);
    process.stdout.write(`${JSON.stringify({
      output: path.relative(ROOT, path.join(options.outputRoot, 'p31-live-session.json')),
      environmentId: report.environmentId,
      passed: true
    }, null, 2)}\n`);
  } catch (error) {
    process.stderr.write(`P-31 live accessibility session failed: ${error.message}\n`);
    process.exitCode = 1;
  }
}
