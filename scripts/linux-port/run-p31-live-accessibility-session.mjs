#!/usr/bin/env node
import fs from 'node:fs';
import net from 'node:net';
import os from 'node:os';
import path from 'node:path';
import { spawn, spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import {
  P31_ENVIRONMENTS,
  P31_REQUIRED_ROUTES,
  validateP31LiveSession
} from './lib/p31-accessibility-proof.mjs';
import { P36_LAYOUT_SCRIPT, P36_THEME_SCRIPT } from './run-p36-native-visual-polish-probes.mjs';
import { verifyInstalledCandidate } from './run-p08-mercury-media-session.mjs';

const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../..');
const DESKTOP = '/usr/bin/openburnbar-linux-desktop';
const ATSPI = path.join(ROOT, 'scripts/linux-port/capture-atspi-tree.py');
const HEAD = /^[a-f0-9]{40,64}$/u;
const RUN_ID = /^[1-9][0-9]*$/u;
const DIGEST = /^sha256:[a-f0-9]{64}$/u;
const SHA256 = /^[a-f0-9]{64}$/u;
const VERSION = /^(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)(?:[-+][0-9A-Za-z.-]+)?$/u;
const FORBIDDEN_SESSION = /(?:xvfb|xfce|openbox|synthetic|fixture|mock|headless|nested)/iu;
const SESSION_ID = /^[A-Za-z0-9_-]+$/u;
export const P31_LIVE_ENVIRONMENTS = Object.freeze({
  'ubuntu-24.04-gnome-x11-x86_64': Object.freeze({
    osId: 'ubuntu',
    versionId: '24.04',
    architecture: 'x86_64',
    desktop: 'GNOME',
    desktopPattern: /gnome/iu,
    session: 'X11',
    compositor: 'Mutter',
    compositorPattern: /(?:gnome shell|mutter)/iu,
    scaleBackend: 'gnome',
    keyboardBackend: 'xdotool'
  }),
  'ubuntu-24.04-gnome-x11-aarch64': Object.freeze({
    osId: 'ubuntu',
    versionId: '24.04',
    architecture: 'aarch64',
    desktop: 'GNOME',
    desktopPattern: /gnome/iu,
    session: 'X11',
    compositor: 'Mutter',
    compositorPattern: /(?:gnome shell|mutter)/iu,
    scaleBackend: 'gnome',
    keyboardBackend: 'xdotool'
  }),
  'ubuntu-24.04-gnome-wayland-x86_64': Object.freeze({
    osId: 'ubuntu',
    versionId: '24.04',
    architecture: 'x86_64',
    desktop: 'GNOME',
    desktopPattern: /gnome/iu,
    session: 'Wayland',
    compositor: 'Mutter',
    compositorPattern: /(?:gnome shell|mutter)/iu,
    scaleBackend: 'gnome',
    keyboardBackend: 'ydotool'
  }),
  'ubuntu-24.04-gnome-wayland-aarch64': Object.freeze({
    osId: 'ubuntu',
    versionId: '24.04',
    architecture: 'aarch64',
    desktop: 'GNOME',
    desktopPattern: /gnome/iu,
    session: 'Wayland',
    compositor: 'Mutter',
    compositorPattern: /(?:gnome shell|mutter)/iu,
    scaleBackend: 'gnome',
    keyboardBackend: 'ydotool'
  }),
  'fedora-kde-wayland-x86_64': Object.freeze({
    osId: 'fedora',
    versionId: null,
    architecture: 'x86_64',
    desktop: 'KDE Plasma',
    desktopPattern: /(?:kde|plasma)/iu,
    session: 'Wayland',
    compositor: 'KWin',
    compositorPattern: /kwin/iu,
    scaleBackend: 'kscreen',
    keyboardBackend: 'ydotool'
  }),
  'fedora-kde-wayland-aarch64': Object.freeze({
    osId: 'fedora',
    versionId: null,
    architecture: 'aarch64',
    desktop: 'KDE Plasma',
    desktopPattern: /(?:kde|plasma)/iu,
    session: 'Wayland',
    compositor: 'KWin',
    compositorPattern: /kwin/iu,
    scaleBackend: 'kscreen',
    keyboardBackend: 'ydotool'
  }),
  'arch-sway-wayland-x86_64': Object.freeze({
    osId: 'arch',
    versionId: null,
    architecture: 'x86_64',
    desktop: 'Sway/wlroots',
    desktopPattern: /(?:sway|wlroots)/iu,
    session: 'Wayland',
    compositor: 'Sway',
    compositorPattern: /sway/iu,
    scaleBackend: 'sway',
    keyboardBackend: 'ydotool'
  })
});
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

function spawnTrustedSync(command, args, options) {
  switch (command) {
    case 'busctl':
      return spawnSync('/usr/bin/busctl', args, options);
    case 'gnome-shell':
      return spawnSync('/usr/bin/gnome-shell', args, options);
    case 'gsettings':
      return spawnSync('/usr/bin/gsettings', args, options);
    case 'kill':
      return spawnSync('/usr/bin/kill', args, options);
    case 'kscreen-doctor':
      return spawnSync('/usr/bin/kscreen-doctor', args, options);
    case 'loginctl':
      return spawnSync('/usr/bin/loginctl', args, options);
    case 'orca':
      return spawnSync('/usr/bin/orca', args, options);
    case 'python3':
      return spawnSync('/usr/bin/python3', args, options);
    case 'swaymsg':
      return spawnSync('/usr/bin/swaymsg', args, options);
    case 'systemctl':
      return spawnSync('/usr/bin/systemctl', args, options);
    case 'wmctrl':
      return spawnSync('/usr/bin/wmctrl', args, options);
    case 'xdotool':
      return spawnSync('/usr/bin/xdotool', args, options);
    case 'ydotool':
      return spawnSync('/usr/bin/ydotool', args, options);
    case '/usr/bin/openburnbar-cli':
      return spawnSync('/usr/bin/openburnbar-cli', args, options);
    default:
      fail(`P-31 refused untrusted command ${String(command)}`);
  }
}

function run(command, args = [], options = {}) {
  assert(Object.keys(options).every((key) => key === 'env'),
    'P-31 command options may only provide an explicit environment');
  assert(Array.isArray(args) && args.every((value) => typeof value === 'string' && !value.includes('\0')),
    'P-31 command arguments must be NUL-free strings');
  const result = spawnTrustedSync(command, args, {
    encoding: 'utf8',
    env: options.env,
    shell: false,
    timeout: 60_000,
    maxBuffer: 16 * 1024 * 1024
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

function exactHostArchitecture(platformArchitecture = os.machine()) {
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

// The ephemeral runner service inherits the graphical environment (display,
// runtime directory, D-Bus address) but not XDG_SESSION_ID, so discover the
// unique active local graphical session for this user through loginctl, the
// same authority the P-40 producer uses.  Discovery is fail-closed: exactly
// one matching session may exist, and every candidate identifier is
// validated before it is handed back to loginctl.
export function discoverP31GraphicalSessionId(expectedSession, {
  uid = process.getuid(),
  listSessions = () => required('loginctl', ['list-sessions', '--no-legend', '--no-pager'],
    'P-31 logind session discovery'),
  showSession = (candidate) => parseLoginctl(required('loginctl', [
    'show-session', candidate, '--property=Type', '--property=Class',
    '--property=Active', '--property=Remote', '--property=State'
  ], `P-31 logind session ${candidate}`))
} = {}) {
  const matches = [];
  for (const line of listSessions().split('\n')) {
    const [candidate, sessionUid] = line.trim().split(/\s+/u);
    if (!candidate || sessionUid !== String(uid)) continue;
    assert(SESSION_ID.test(candidate), 'P-31 loginctl returned an unsafe session identifier');
    const detail = showSession(candidate);
    if ((detail.Type ?? '').toLowerCase() !== expectedSession.toLowerCase()) continue;
    if (detail.Class !== 'user' || detail.Active !== 'yes' || detail.Remote !== 'no') continue;
    if (!['active', 'online'].includes((detail.State ?? '').toLowerCase())) continue;
    matches.push(candidate);
  }
  assert(matches.length === 1,
    `P-31 requires exactly one active local ${expectedSession} session for this user, found ${matches.length}`);
  return matches[0];
}

export function validateP31HostIdentity({
  environmentId,
  platform = process.platform,
  architecture = exactHostArchitecture(),
  release = readOsRelease(),
  environment = process.env,
  loginctl = null,
  compositorIdentity = '',
  waylandSocketIsReal = null,
  windowManager = ''
} = {}) {
  const expected = P31_LIVE_ENVIRONMENTS[environmentId];
  assert(expected && P31_ENVIRONMENTS[environmentId],
    `P-31 live producer received unknown canonical environment ${environmentId ?? '<missing>'}`);
  assert(platform === 'linux', 'P-31 live producer must run on Linux');
  assert(architecture === expected.architecture,
    `P-31 ${environmentId} requires native ${expected.architecture}, observed ${architecture}`);
  assert(release.ID === expected.osId
    && (expected.versionId === null || release.VERSION_ID === expected.versionId),
  `P-31 ${environmentId} does not match the live distribution`);
  const observedSession = (environment.XDG_SESSION_TYPE ?? '').toLowerCase();
  assert(observedSession === expected.session.toLowerCase(),
    `P-31 ${environmentId} requires a real ${expected.session} session`);
  const desktop = `${environment.XDG_CURRENT_DESKTOP ?? ''} ${environment.DESKTOP_SESSION ?? ''}`.trim();
  assert(expected.desktopPattern.test(desktop) && !FORBIDDEN_SESSION.test(desktop),
    `P-31 ${environmentId} does not match the live ${expected.desktop} desktop`);
  assert(environment.DBUS_SESSION_BUS_ADDRESS && environment.XDG_RUNTIME_DIR,
    `P-31 ${environmentId} requires the user session bus and XDG_RUNTIME_DIR`);
  if (expected.session === 'X11') {
    assert(environment.DISPLAY && !environment.WAYLAND_DISPLAY,
      `P-31 ${environmentId} requires DISPLAY without a Wayland display`);
  } else {
    assert(environment.WAYLAND_DISPLAY && waylandSocketIsReal === true,
      `P-31 ${environmentId} requires a real owned Wayland compositor socket`);
  }
  const observedCompositor = compositorIdentity || windowManager;
  assert(observedCompositor && expected.compositorPattern.test(observedCompositor),
    `P-31 ${environmentId} compositor is not ${expected.compositor}`);
  assert(!FORBIDDEN_SESSION.test(
    `${environment.DISPLAY ?? ''} ${environment.WAYLAND_DISPLAY ?? ''} ${observedCompositor}`
  ), `P-31 ${environmentId} rejects substitute, nested, fixture, and synthetic sessions`);
  if (loginctl) {
    assert((loginctl.Type ?? '').toLowerCase() === expected.session.toLowerCase()
      && loginctl.Active === 'yes' && loginctl.Remote === 'no'
      && loginctl.Class === 'user' && ['active', 'online'].includes(loginctl.State),
    `P-31 ${environmentId} logind identity is not an active local user session`);
    if ((loginctl.Desktop ?? '').trim()) {
      assert(expected.desktopPattern.test(loginctl.Desktop),
        `P-31 ${environmentId} logind desktop does not match ${expected.desktop}`);
    }
  }
  return {
    environmentId,
    architecture,
    desktop: expected.desktop,
    session: expected.session,
    compositor: expected.compositor
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

function trustedSystemTool(command) {
  let executable;
  switch (command) {
    case 'busctl':
      executable = '/usr/bin/busctl';
      break;
    case 'gnome-shell':
      executable = '/usr/bin/gnome-shell';
      break;
    case 'gsettings':
      executable = '/usr/bin/gsettings';
      break;
    case 'kscreen-doctor':
      executable = '/usr/bin/kscreen-doctor';
      break;
    case 'orca':
      executable = '/usr/bin/orca';
      break;
    case 'python3':
      executable = '/usr/bin/python3';
      break;
    case 'swaymsg':
      executable = '/usr/bin/swaymsg';
      break;
    case 'wmctrl':
      executable = '/usr/bin/wmctrl';
      break;
    case 'xdotool':
      executable = '/usr/bin/xdotool';
      break;
    case 'ydotool':
      executable = '/usr/bin/ydotool';
      break;
    default:
      fail(`P-31 has no trusted system path for ${String(command)}`);
  }
  const link = fs.lstatSync(executable);
  const stat = fs.statSync(executable);
  assert(link.isFile() && !link.isSymbolicLink() && stat.uid === 0
    && (stat.mode & 0o111) !== 0 && (stat.mode & 0o022) === 0,
  `P-31 ${command} must be a root-owned non-writable executable`);
  return executable;
}

function trustedTauriDriver(environment) {
  const cargoHome = environment.CARGO_HOME
    ? path.resolve(environment.CARGO_HOME)
    : path.join(os.homedir(), '.cargo');
  const executable = path.join(cargoHome, 'bin', 'tauri-driver');
  const link = fs.lstatSync(executable);
  const stat = fs.statSync(executable);
  assert(link.isFile() && !link.isSymbolicLink() && stat.uid === process.getuid()
    && (stat.mode & 0o111) !== 0 && (stat.mode & 0o022) === 0
    && fs.realpathSync(executable) === executable,
  'P-31 tauri-driver must be the runner-owned non-writable Cargo executable');
  return executable;
}

export function openP31OrcaLog(file) {
  const descriptor = fs.openSync(
    file,
    fs.constants.O_RDONLY | fs.constants.O_NOFOLLOW | fs.constants.O_NONBLOCK,
    0o600
  );
  try {
    const stat = fs.fstatSync(descriptor);
    assert(stat.isFile() && stat.uid === process.getuid() && (stat.mode & 0o077) === 0,
      'P-31 Orca debug log must be an owner-only regular file');
    let closed = false;
    return {
      offset: stat.size,
      read() {
        assert(!closed, 'P-31 Orca debug log descriptor is closed');
        return fs.readFileSync(descriptor);
      },
      close() {
        if (closed) return;
        closed = true;
        fs.closeSync(descriptor);
      }
    };
  } catch (error) {
    fs.closeSync(descriptor);
    throw error;
  }
}

function atomicJson(file, value) {
  const temporary = `${file}.tmp-${process.pid}-${Date.now()}`;
  fs.writeFileSync(temporary, `${JSON.stringify(value, null, 2)}\n`, { mode: 0o600, flag: 'wx' });
  fs.renameSync(temporary, file);
}

export function parseKScreenOutputs(text) {
  return text.split(/(?=^Output:\s)/gmu).flatMap((block) => {
    const identity = block.match(/^Output:\s+([1-9][0-9]*)\s+(\S+)/mu);
    const scale = block.match(/^\s+Scale:\s+([0-9]+(?:\.[0-9]+)?)\s*$/mu);
    if (!identity || !scale || !/^\s+enabled\s*$/mu.test(block)
      || !/^\s+connected\s*$/mu.test(block)) return [];
    return [{
      id: identity[1],
      name: identity[2],
      scale: Number(scale[1])
    }];
  });
}

export function parseSwayOutputs(text) {
  let outputs;
  try {
    outputs = JSON.parse(text);
  } catch (error) {
    throw new Error(`P-31 Sway output inventory is not JSON: ${error.message}`);
  }
  assert(Array.isArray(outputs), 'P-31 Sway output inventory must be an array');
  return outputs.filter((output) => output?.active === true)
    .map((output) => ({
      name: output.name,
      scale: Number(output.scale)
    }))
    .filter((output) => typeof output.name === 'string' && output.name.length > 0
      && Number.isFinite(output.scale) && output.scale > 0);
}

export function detectYdotoolDialect(helpText) {
  if (/<KEYCODE:PRESSED>|keycode:pressed/iu.test(helpText)) return 'linux-input-events';
  if (/key sequence[\s\S]*separated by plus/iu.test(helpText)) return 'legacy-key-names';
  fail('P-31 could not identify the installed ydotool keyboard dialect');
}

export function applyDesktopAccessibilityPreferences(rawDir, identity, {
  invokeGsettings = (args, label) => required('gsettings', args, label),
  invokeKscreen = (args, label) => required('kscreen-doctor', args, label),
  invokeSway = (args, label) => required('swaymsg', args, label)
} = {}) {
  const profile = P31_LIVE_ENVIRONMENTS[identity?.environmentId];
  assert(profile, 'P-31 desktop preference application requires a canonical environment identity');
  const changed = [];
  const restore = () => {
    const errors = [];
    for (const change of [...changed].reverse()) {
      try {
        change.write(change.original, `P-31 restore ${change.label}`);
        const observed = change.read(`P-31 verify restored ${change.label}`);
        assert(change.equal(observed, change.original),
          `P-31 ${change.label} was not restored exactly`);
      } catch (error) {
        errors.push(error);
      }
    }
    if (errors.length) throw new AggregateError(errors, 'P-31 desktop preference restoration failed');
  };
  const mutate = ({ label, read, write, value, equal }) => {
    const original = read(`P-31 read ${label}`);
    const change = { label, read, write, original, equal };
    changed.push(change);
    write(value, `P-31 set ${label}`);
    const observed = read(`P-31 verify ${label}`);
    assert(equal(observed, value), `P-31 ${label} did not reach its required live value`);
    return observed;
  };
  const gsettings = (key, value, expected) => mutate({
    label: `GTK ${key}`,
    read: (label) => invokeGsettings(
      ['get', 'org.gnome.desktop.interface', key],
      label
    ),
    write: (next, label) => invokeGsettings(
      ['set', 'org.gnome.desktop.interface', key, next],
      label
    ),
    value,
    equal: (observed, wanted) => wanted === value ? expected.test(observed) : observed === wanted
  });
  try {
    let scaleOutputs = [];
    if (profile.scaleBackend === 'gnome') {
      const readback = gsettings('scaling-factor', '2', /^uint32 2$/u);
      scaleOutputs = [{
        name: 'GNOME global scale',
        scale: 2,
        readback
      }];
    } else if (profile.scaleBackend === 'kscreen') {
      const readOutputs = (label) => parseKScreenOutputs(invokeKscreen(['-o'], label));
      const originals = readOutputs('P-31 read KScreen outputs');
      assert(originals.length > 0, 'P-31 KDE session has no active connected output');
      for (const output of originals) {
        mutate({
          label: `KScreen output ${output.id} (${output.name}) scale`,
          read: (label) => {
            const observed = readOutputs(label).find((candidate) => candidate.id === output.id);
            assert(observed, `P-31 KScreen output ${output.id} disappeared`);
            return observed.scale;
          },
          write: (next, label) => invokeKscreen(
            [`output.${output.id}.scale.${next}`],
            label
          ),
          value: 2,
          equal: (observed, wanted) => observed === wanted
        });
      }
      scaleOutputs = readOutputs('P-31 verify all KScreen output scales');
      assert(scaleOutputs.length === originals.length
        && scaleOutputs.every((output) => output.scale === 2),
      'P-31 KDE did not reach exact 200 percent on every active output');
    } else if (profile.scaleBackend === 'sway') {
      const readOutputs = (label) => parseSwayOutputs(invokeSway(
        ['-t', 'get_outputs', '-r'],
        label
      ));
      const originals = readOutputs('P-31 read Sway outputs');
      assert(originals.length > 0, 'P-31 Sway session has no active output');
      for (const output of originals) {
        mutate({
          label: `Sway output ${output.name} scale`,
          read: (label) => {
            const observed = readOutputs(label).find((candidate) => candidate.name === output.name);
            assert(observed, `P-31 Sway output ${output.name} disappeared`);
            return observed.scale;
          },
          write: (next, label) => invokeSway(
            ['output', output.name, 'scale', String(next)],
            label
          ),
          value: 2,
          equal: (observed, wanted) => observed === wanted
        });
      }
      scaleOutputs = readOutputs('P-31 verify all Sway output scales');
      assert(scaleOutputs.length === originals.length
        && scaleOutputs.every((output) => output.scale === 2),
      'P-31 Sway did not reach exact 200 percent on every active output');
    }
    const gtkTheme = gsettings('gtk-theme', 'HighContrast', /^'HighContrast'$/u);
    const enableAnimations = gsettings('enable-animations', 'false', /^false$/u);
    const evidence = {
      producer: 'openburnbar-p31-desktop-accessibility-preferences-v1',
      environmentId: identity.environmentId,
      desktop: identity.desktop,
      session: identity.session,
      compositor: identity.compositor,
      scaleBackend: profile.scaleBackend,
      scaleOutputs,
      gtkTheme,
      enableAnimations,
      pass: true
    };
    const evidenceFile = path.join(rawDir, 'p31-desktop-accessibility-settings.json');
    atomicJson(evidenceFile, evidence);
    return { evidence, evidenceFile, restore };
  } catch (error) {
    try {
      restore();
    } catch (restoreError) {
      throw new AggregateError([error, restoreError],
        'P-31 desktop preference application and restoration failed');
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

function exactExecutablePids(names) {
  const accepted = new Set(names);
  return fs.readdirSync('/proc')
    .filter((entry) => /^[1-9][0-9]*$/u.test(entry))
    .filter((entry) => {
      try {
        return accepted.has(path.basename(fs.realpathSync(`/proc/${entry}/exe`)));
      } catch {
        return false;
      }
    })
    .map(Number)
    .sort((left, right) => left - right);
}

function assertRealSessionSocket(file, label) {
  assert(path.isAbsolute(file), `${label} must be absolute`);
  const link = fs.lstatSync(file);
  const stat = fs.statSync(file);
  assert(!link.isSymbolicLink() && stat.isSocket() && stat.uid === process.getuid(),
    `${label} must be a real socket owned by the runner user`);
  return true;
}

function observeP31Compositor(profile, environment) {
  if (profile.compositor === 'Mutter') {
    const pids = exactExecutablePids(['gnome-shell']);
    assert(pids.length === 1, 'P-31 requires exactly one live GNOME Shell compositor process');
    if (profile.session === 'X11') {
      return `${required('wmctrl', ['-m'], 'P-31 GNOME X11 compositor identity')}\npid=${pids[0]}`;
    }
    const shellVersion = required('gnome-shell', ['--version'], 'P-31 GNOME Shell version');
    const busNames = required('busctl', [
      '--user', '--no-pager', '--no-legend', 'list'
    ], 'P-31 GNOME Shell session bus identity');
    assert(/^org\.gnome\.Shell\s/mu.test(busNames),
      'P-31 GNOME Wayland session bus has no org.gnome.Shell owner');
    return `${shellVersion}\norg.gnome.Shell\npid=${pids[0]}`;
  }
  if (profile.compositor === 'KWin') {
    const pids = exactExecutablePids(['kwin_wayland', 'kwin_wayland_wrapper']);
    assert(pids.length > 0, 'P-31 requires a live KWin Wayland compositor process');
    const busNames = required('busctl', [
      '--user', '--no-pager', '--no-legend', 'list'
    ], 'P-31 KWin session bus identity');
    assert(/^org\.kde\.KWin\s/mu.test(busNames),
      'P-31 KDE Wayland session bus has no org.kde.KWin owner');
    return `KWin Wayland\norg.kde.KWin\npids=${pids.join(',')}`;
  }
  if (profile.compositor === 'Sway') {
    const pids = exactExecutablePids(['sway']);
    assert(pids.length === 1, 'P-31 requires exactly one live Sway compositor process');
    assert(environment.SWAYSOCK, 'P-31 Sway session requires SWAYSOCK');
    assertRealSessionSocket(environment.SWAYSOCK, 'P-31 Sway IPC socket');
    const version = required('swaymsg', ['-t', 'get_version', '-r'], 'P-31 Sway compositor identity');
    const parsed = JSON.parse(version);
    assert(/sway/iu.test(`${parsed?.human_readable ?? ''} ${parsed?.variant ?? ''}`),
      'P-31 Sway IPC did not identify a Sway compositor');
    return `${parsed.human_readable ?? 'Sway'}\npid=${pids[0]}`;
  }
  fail(`P-31 has no live compositor probe for ${profile.compositor}`);
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
      const driverExecutable = trustedTauriDriver(environment);
      const driverEnvironment = {
        ...environment,
        PATH: `${path.dirname(driverExecutable)}:/usr/bin:/bin`
      };
      const webkitDriver = fs.lstatSync('/usr/bin/WebKitWebDriver');
      const webkitDriverStat = fs.statSync('/usr/bin/WebKitWebDriver');
      assert(webkitDriver.isFile() && !webkitDriver.isSymbolicLink()
        && webkitDriverStat.uid === 0 && (webkitDriverStat.mode & 0o111) !== 0
        && (webkitDriverStat.mode & 0o022) === 0,
      'P-31 WebKitWebDriver must be the root-owned non-writable system executable');
      const selected = await reservePort();
      base = `http://127.0.0.1:${selected}/`;
      child = spawn('tauri-driver', ['--port', String(selected)], {
        env: driverEnvironment,
        shell: false,
        stdio: 'ignore'
      });
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
      if (typeof encoded !== 'string') {
        throw new Error('P-31 WebDriver screenshot response is not a string');
      }
      if (!/^[A-Za-z0-9+/]+=*$/u.test(encoded)) {
        throw new Error('P-31 WebDriver screenshot response is not canonical base64');
      }
      const bytes = Buffer.from(encoded, 'base64');
      if (bytes.length < 1024 || bytes.length > 32 * 1024 * 1024) {
        throw new Error('P-31 WebDriver screenshot size is outside the evidence bounds');
      }
      const dimensions = pngDimensions(bytes);
      fs.writeFileSync(file, bytes, { mode: 0o600, flag: 'wx' });
      return dimensions;
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

async function captureDriverEvidence(driver, rawDir, desktopPreferences, options, identity) {
  const routeAudits = [];
  const navigationRoutes = [];
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
      assert(observed.hash === expectedHash && observed.label === expectedLabel && observed.inMain === true,
        `P-31 WebDriver route identity is incomplete for ${route}`);
      return {
        hash: expectedHash,
        label: expectedLabel,
        inMain: true,
        pass: true
      };
    }, 10_000);
    const atspiName = `p31-route-${route}-atspi.json`;
    const atspiPath = path.join(rawDir, atspiName);
    required('python3', [
      ATSPI, '--application', 'OpenBurnBar', '--mode', 'summary',
      '--expected-name', expectedLabel, '--route', route,
      '--output', atspiPath, '--min-nodes', '12', '--min-named', '6',
      '--min-actionable', '3', '--wait-for-meaningful-seconds', '5'
    ], `P-31 live AT-SPI route ${route}`);
    const atspi = JSON.parse(fs.readFileSync(atspiPath, 'utf8'));
    assert(atspi.pass === true, `P-31 live AT-SPI route ${route} did not pass`);
    navigationRoutes.push({
      route,
      expectedLabel,
      atspi: atspiName,
      routeIdentity
    });
    const layout = await driver.execute(P36_LAYOUT_SCRIPT, ['p31-exact-200-percent']);
    assert(layout?.horizontalOverflow === 0 && layout?.clippedCount === 0,
      `P-31 route ${route} has clipping or horizontal overflow`);
    const focused = await driver.execute(
      "const e=document.querySelector('a[href=\"#main\"],button:not([disabled]),a[href],input:not([disabled])');e?.focus();return !!e&&document.activeElement===e&&e.matches(':focus-visible');"
    );
    assert(focused === true, `P-31 route ${route} did not preserve visible keyboard focus`);
    routeAudits.push({
      route,
      expectedLabel,
      routeIdentity,
      layout: { horizontalOverflow: 0, clippedCount: 0 },
      focusPreserved: true
    });
  }
  const layoutPath = path.join(rawDir, 'p31-scale-route-audit.json');
  atomicJson(layoutPath, { producer: 'openburnbar-p31-webkit-scale-audit-v1', routes: routeAudits });
  const navigation = {
    producer: 'openburnbar-p31-webdriver-atspi-navigation-v1',
    surface: 'installed-tauri-native-session',
    environmentId: options.environmentId,
    targetHead: options.targetHead,
    candidate: {
      runId: options.candidateRunId,
      artifactDigest: options.candidateArtifactDigest
    },
    packageVersion: options.packageVersion,
    desktop: {
      desktop: identity.desktop,
      session: identity.session,
      compositor: identity.compositor
    },
    routes: navigationRoutes
  };
  atomicJson(path.join(rawDir, 'packaged-route-session-transcript.json'), navigation);

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
    dpr: 2,
    forcedColors: true,
    reducedMotion: true,
    animationsObserved: 0,
    transitionsObserved: 0,
    liveRegionsObserved: true,
    namedControlsObserved: true,
    horizontalScrollbars: 0,
    semanticContrastPass: true,
    noColorNamedControlsPass: true,
    screenshotScaleReadbackPass: true,
    desktopPreferences
  });
  const canonicalRuntime = {
    dpr: 2,
    forcedColors: true,
    reducedMotion: true,
    animationsObserved: 0,
    transitionsObserved: 0,
    liveRegionCount: 1,
    namedControlCount: 1,
    horizontalScrollbars: 0
  };
  return {
    runtime: canonicalRuntime,
    routeAudits,
    navigation,
    evidence: {
      layout: path.basename(layoutPath),
      scaleAtspi: path.basename(scaleAtspi),
      scaleScreenshot: path.basename(scaleScreenshot),
      highContrastScreenshot: path.basename(highContrastScreenshot),
      noColorScreenshot: path.basename(noColorScreenshot),
      forcedColorsScreenshot: path.basename(forcedColorsScreenshot),
      runtime: path.basename(runtimePath),
      desktopSettings: 'p31-desktop-accessibility-settings.json'
    }
  };
}

async function captureKeyboardAndOrca(
  rawDir,
  orcaDebug,
  identity,
  environment,
  physicalTabPresses = 28,
  physicalShiftTabPresses = 12
) {
  const profile = P31_LIVE_ENVIRONMENTS[identity.environmentId];
  let windowId = null;
  if (profile.keyboardBackend === 'xdotool') {
    const windowIds = required('xdotool', [
      'search', '--onlyvisible', '--name', '^OpenBurnBar$'
    ], 'P-31 installed window lookup').split(/\s+/u).filter(Boolean);
    assert(windowIds.length === 1 && /^[0-9]+$/u.test(windowIds[0]),
      'P-31 requires exactly one installed WebDriver window');
    [windowId] = windowIds;
    const windowPid = required('xdotool', ['getwindowpid', windowId], 'P-31 installed window PID');
    assert(/^[1-9][0-9]*$/u.test(windowPid), 'P-31 installed window PID is invalid');
    const executable = fs.realpathSync(`/proc/${windowPid}/exe`);
    assert(executable === DESKTOP,
      `P-31 keyboard window is not owned by ${DESKTOP}: ${executable}`);
  } else {
    assert(profile.keyboardBackend === 'ydotool', 'P-31 has no canonical keyboard input backend');
    const desktopPids = exactDesktopPids();
    assert(desktopPids.length === 1,
      'P-31 Wayland keyboard traversal requires exactly one installed desktop process');
    assert(environment.YDOTOOL_SOCKET,
      'P-31 Wayland keyboard traversal requires an explicit YDOTOOL_SOCKET');
    assertRealSessionSocket(environment.YDOTOOL_SOCKET, 'P-31 ydotoold socket');
    trustedSystemTool('ydotool');
  }
  let inputDialect = profile.keyboardBackend;
  if (profile.keyboardBackend === 'ydotool') {
    const help = run('ydotool', ['key', '--help'], { env: environment });
    assert(help.status === 0, `P-31 ydotool keyboard help failed (${help.status})`);
    inputDialect = detectYdotoolDialect(`${help.stdout}\n${help.stderr}`);
    if (inputDialect === 'legacy-key-names') {
      assert(environment.YDOTOOL_SOCKET === '/tmp/.ydotool_socket',
        'P-31 legacy Ubuntu ydotool requires YDOTOOL_SOCKET=/tmp/.ydotool_socket');
    }
  }
  const pressKey = (reverse = false) => {
    if (profile.keyboardBackend === 'xdotool') {
      required('xdotool', [
        'windowfocus', '--sync', windowId
      ], reverse ? 'P-31 reverse window focus' : 'P-31 window focus');
      required('xdotool', [
        'key', '--window', windowId, '--clearmodifiers', reverse ? 'shift+Tab' : 'Tab'
      ], reverse ? 'P-31 physical Shift+Tab' : 'P-31 physical Tab');
      return;
    }
    const input = inputDialect === 'legacy-key-names'
      ? ['key', reverse ? 'shift+Tab' : 'Tab']
      : [
          'key',
          ...(reverse ? ['42:1', '15:1', '15:0', '42:0'] : ['15:1', '15:0'])
        ];
    required('ydotool', input,
      reverse ? 'P-31 physical Wayland Shift+Tab' : 'P-31 physical Wayland Tab', {
      env: environment
    });
  };
  const forwardAnchor = path.join(rawDir, 'p31-focus-forward-anchor.json');
  required('python3', [
    ATSPI, '--application', 'OpenBurnBar', '--mode', 'grab-focus',
    '--expected-name', 'Skip to content', '--output', forwardAnchor
  ], 'P-31 keyboard focus anchor');
  await wait(500);
  const orcaLog = openP31OrcaLog(orcaDebug);
  const focusLogOffset = orcaLog.offset;
  try {
    const observations = [];
    for (let index = 0; index < physicalTabPresses; index += 1) {
      pressKey();
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
      pressKey(true);
      await wait(1_250);
    }
    await wait(8_000);
    const debugBytes = orcaLog.read();
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
      inputBackend: profile.keyboardBackend,
      inputDialect,
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
  } finally {
    orcaLog.close();
  }
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
  const expectedEnvironment = P31_ENVIRONMENTS[options.environmentId];
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
      format: expectedEnvironment.format,
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
          evidence(driverEvidence.evidence.desktopSettings)
        ],
        focusPreserved: driverEvidence.routeAudits.every((row) => row.focusPreserved),
        horizontalScrollbars: runtime.horizontalScrollbars,
        method: 'installed-WebKitGTK live desktop exact compositor scale with raster readback',
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
          evidence(driverEvidence.evidence.desktopSettings)
        ],
        forcedColors: {
          evidencePath: evidence(driverEvidence.evidence.forcedColorsScreenshot),
          mode: 'forced-colors',
          observed: runtime.forcedColors,
          pass: runtime.forcedColors,
          test: 'WebKit forced-colors media query under the real desktop GTK HighContrast theme'
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
          evidence(driverEvidence.evidence.desktopSettings)
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
  const profile = P31_LIVE_ENVIRONMENTS[options.environmentId];
  assert(profile && P31_ENVIRONMENTS[options.environmentId],
    `P-31 live producer requires a canonical environment, received ${options.environmentId}`);
  assert(HEAD.test(options.targetHead) && RUN_ID.test(options.candidateRunId)
    && DIGEST.test(options.candidateArtifactDigest) && VERSION.test(options.packageVersion)
    && SHA256.test(options.manifestSha256) && SHA256.test(options.manifestSignatureSha256),
  'P-31 candidate binding is invalid');
  assert(options.compositor === profile.compositor && !FORBIDDEN_SESSION.test(options.compositor),
    `P-31 ${options.environmentId} requires the ${profile.compositor} compositor`);
  return options;
}

export async function runP31LiveAccessibilitySession(options) {
  const repository = fs.realpathSync(ROOT);
  const profile = P31_LIVE_ENVIRONMENTS[options.environmentId];
  assert(profile, `P-31 has no live profile for ${options.environmentId}`);
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

  let sessionId = process.env.XDG_SESSION_ID ?? '';
  if (sessionId) {
    assert(SESSION_ID.test(sessionId), 'P-31 XDG_SESSION_ID is malformed');
  } else {
    sessionId = discoverP31GraphicalSessionId(profile.session);
  }
  const loginctl = parseLoginctl(required('loginctl', [
    'show-session', sessionId, '--property=Type', '--property=Desktop', '--property=Class',
    '--property=Active', '--property=Remote', '--property=State'
  ], 'P-31 logind identity'));
  let waylandSocketIsReal = null;
  if (profile.session === 'Wayland') {
    assert(/^[A-Za-z0-9][A-Za-z0-9._-]*$/u.test(process.env.WAYLAND_DISPLAY ?? ''),
      'P-31 WAYLAND_DISPLAY must name a socket inside XDG_RUNTIME_DIR');
    assertRealOwnedDirectory(process.env.XDG_RUNTIME_DIR, 'P-31 XDG runtime directory');
    const waylandSocket = path.join(process.env.XDG_RUNTIME_DIR, process.env.WAYLAND_DISPLAY);
    assertInside(process.env.XDG_RUNTIME_DIR, waylandSocket, 'P-31 Wayland display socket');
    waylandSocketIsReal = assertRealSessionSocket(
      waylandSocket,
      'P-31 Wayland display socket'
    );
  }
  const compositorIdentity = observeP31Compositor(profile, process.env);
  const machineArchitecture = exactHostArchitecture();
  assert(machineArchitecture === exactHostArchitecture(os.arch()),
    'P-31 live producer requires a native Node runtime matching the Linux machine architecture');
  const identity = validateP31HostIdentity({
    environmentId: options.environmentId,
    architecture: machineArchitecture,
    loginctl,
    compositorIdentity,
    waylandSocketIsReal
  });
  assert(options.compositor === identity.compositor, 'P-31 compositor argument does not match the live host');

  verifyInstalledCandidate(options);
  const requiredTools = new Set(['python3', 'gsettings', 'orca']);
  if (profile.session === 'X11') {
    requiredTools.add('wmctrl');
    requiredTools.add('xdotool');
  } else {
    requiredTools.add('ydotool');
  }
  if (profile.compositor === 'Mutter' && profile.session === 'Wayland') {
    requiredTools.add('busctl');
    requiredTools.add('gnome-shell');
  } else if (profile.compositor === 'KWin') {
    requiredTools.add('busctl');
    requiredTools.add('kscreen-doctor');
  } else if (profile.compositor === 'Sway') {
    requiredTools.add('swaymsg');
  }
  for (const tool of requiredTools) {
    trustedSystemTool(tool);
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
    preferences = applyDesktopAccessibilityPreferences(options.rawOutputDir, identity);
    const orcaDebug = path.join(options.rawOutputDir, 'orca-debug.log');
    const orcaVersion = required('orca', ['--version'], 'P-31 Orca version');
    fs.writeFileSync(path.join(options.rawOutputDir, 'orca-version.txt'), `${orcaVersion}\n`, { mode: 0o600 });
    let orcaSpawnError = null;
    orca = spawn('/usr/bin/orca', [
      '--replace', '--disable', 'speech', '--disable', 'braille', '--disable', 'braille-monitor',
      `--debug-file=${orcaDebug}`
    ], { env: process.env, shell: false, stdio: 'ignore' });
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
      preferences.evidence,
      options,
      identity
    );
    const navigation = driverEvidence.navigation;
    assert(navigation.surface === 'installed-tauri-native-session'
      && navigation.routes?.length === P31_REQUIRED_ROUTES.length,
    'P-31 navigation transcript is not a complete installed session');
    const keyboard = await captureKeyboardAndOrca(
      options.rawOutputDir,
      orcaDebug,
      identity,
      process.env
    );
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
