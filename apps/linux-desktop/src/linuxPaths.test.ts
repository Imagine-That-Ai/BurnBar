import { afterEach, describe, expect, it } from 'vitest';
import {
  linuxAuthTokenPath,
  linuxConfigDir,
  linuxPathContract,
  linuxSocketPath,
  linuxSupportDir
} from './linuxPaths.js';
import { LINUX_PATH_GOLDENS } from './pathContractGoldens.js';

const keys = [
  'OPENBURNBAR_SOCKET_PATH',
  'OPENBURNBAR_DAEMON_SOCKET_PATH',
  'BURNBAR_DAEMON_SOCKET_PATH',
  'OPENBURNBAR_DAEMON_SUPPORT_DIR',
  'BURNBAR_DAEMON_SUPPORT_DIR',
  'XDG_RUNTIME_DIR',
  'XDG_DATA_HOME',
  'XDG_CONFIG_HOME'
] as const;

const originalEnv: Record<string, string | undefined> = {};
for (const key of keys) {
  originalEnv[key] = process.env[key];
}

afterEach(() => {
  for (const key of keys) {
    if (originalEnv[key] === undefined) {
      delete process.env[key];
    } else {
      process.env[key] = originalEnv[key];
    }
  }
});

function clearPathEnv(): void {
  for (const key of keys) {
    delete process.env[key];
  }
}

describe('linux path contract', () => {
  it('keeps explicit socket overrides authoritative', () => {
    clearPathEnv();
    process.env.OPENBURNBAR_SOCKET_PATH = '/tmp/openburnbar/custom.sock';
    process.env.XDG_RUNTIME_DIR = '/run/user/501';

    expect(linuxSocketPath()).toBe('/tmp/openburnbar/custom.sock');
  });

  it('honors OPENBURNBAR_DAEMON_SOCKET_PATH and BURNBAR_DAEMON_SOCKET_PATH precedence', () => {
    clearPathEnv();
    process.env.OPENBURNBAR_DAEMON_SOCKET_PATH = '/srv/a.sock';
    process.env.BURNBAR_DAEMON_SOCKET_PATH = '/srv/b.sock';
    expect(linuxSocketPath()).toBe('/srv/a.sock');

    delete process.env.OPENBURNBAR_DAEMON_SOCKET_PATH;
    expect(linuxSocketPath()).toBe('/srv/b.sock');
  });

  it('ignores blank/whitespace socket overrides before fallback', () => {
    clearPathEnv();
    process.env.OPENBURNBAR_SOCKET_PATH = '   ';
    process.env.OPENBURNBAR_DAEMON_SOCKET_PATH = '';
    process.env.BURNBAR_DAEMON_SOCKET_PATH = '/srv/openburnbar/daemon.sock';
    process.env.XDG_RUNTIME_DIR = '/run/user/1';
    expect(linuxSocketPath()).toBe('/srv/openburnbar/daemon.sock');
  });

  it('defaults to the systemd user runtime socket', () => {
    clearPathEnv();
    process.env.XDG_RUNTIME_DIR = '/run/user/501';

    expect(linuxSocketPath()).toBe('/run/user/501/openburnbar/daemon.sock');
  });

  it('falls back to support-dir socket when runtime dir is missing', () => {
    clearPathEnv();
    process.env.XDG_DATA_HOME = '/var/data';

    expect(linuxSocketPath()).toBe('/var/data/openburnbar/openburnbar-daemon.sock');
  });

  it('uses lowercase XDG data home for support (not OpenBurnBar casing)', () => {
    clearPathEnv();
    process.env.XDG_DATA_HOME = '/custom/data';

    expect(linuxSupportDir()).toBe('/custom/data/openburnbar');
    expect(linuxAuthTokenPath()).toBe('/custom/data/openburnbar/daemon-socket-auth-token');
  });

  it('honors support-dir overrides (OPENBURNBAR and BURNBAR keys)', () => {
    clearPathEnv();
    process.env.OPENBURNBAR_DAEMON_SUPPORT_DIR = '/tmp/obb-support';
    expect(linuxSupportDir()).toBe('/tmp/obb-support');
    expect(linuxAuthTokenPath()).toBe('/tmp/obb-support/daemon-socket-auth-token');

    clearPathEnv();
    process.env.BURNBAR_DAEMON_SUPPORT_DIR = '/tmp/bb-support';
    expect(linuxSupportDir()).toBe('/tmp/bb-support');
  });

  it('ignores blank support overrides', () => {
    clearPathEnv();
    process.env.OPENBURNBAR_DAEMON_SUPPORT_DIR = '  ';
    process.env.XDG_DATA_HOME = '/data';
    expect(linuxSupportDir()).toBe('/data/openburnbar');
  });

  it('uses XDG config home for config dir', () => {
    clearPathEnv();
    process.env.XDG_CONFIG_HOME = '/custom/config';

    expect(linuxConfigDir()).toBe('/custom/config/openburnbar');
  });

  it('defaults config and support under home when XDG vars are unset', () => {
    clearPathEnv();
    const home = '/home/alice';
    expect(linuxSupportDir(process.env, home)).toBe('/home/alice/.local/share/openburnbar');
    expect(linuxConfigDir(process.env, home)).toBe('/home/alice/.config/openburnbar');
  });

  it('exposes a contract snapshot for settings/onboarding', () => {
    clearPathEnv();
    process.env.XDG_RUNTIME_DIR = '/run/user/1000';
    process.env.XDG_DATA_HOME = '/data';
    process.env.XDG_CONFIG_HOME = '/cfg';

    expect(linuxPathContract()).toEqual({
      supportDir: '/data/openburnbar',
      socketPath: '/run/user/1000/openburnbar/daemon.sock',
      configDir: '/cfg/openburnbar',
      authTokenPath: '/data/openburnbar/daemon-socket-auth-token',
      runtimeDir: '/run/user/1000'
    });
  });

  it('golden vectors match extension client defaults', () => {
    // Shared golden: home=/home/alberto, XDG_DATA_HOME, XDG_RUNTIME_DIR
    clearPathEnv();
    const env = {
      XDG_DATA_HOME: '/home/alberto/.local/share',
      XDG_RUNTIME_DIR: '/run/user/1000'
    } as NodeJS.ProcessEnv;
    const home = '/home/alberto';
    expect(linuxSupportDir(env, home)).toBe('/home/alberto/.local/share/openburnbar');
    expect(linuxSocketPath(env, home)).toBe('/run/user/1000/openburnbar/daemon.sock');
    expect(linuxAuthTokenPath(env, home)).toBe(
      '/home/alberto/.local/share/openburnbar/daemon-socket-auth-token'
    );
  });

  it.each(LINUX_PATH_GOLDENS)('golden: $name', (golden) => {
    clearPathEnv();
    const env = { ...golden.env } as NodeJS.ProcessEnv;
    expect(linuxSupportDir(env, golden.home)).toBe(golden.expect.supportDir);
    expect(linuxSocketPath(env, golden.home)).toBe(golden.expect.socketPath);
    expect(linuxAuthTokenPath(env, golden.home)).toBe(golden.expect.authTokenPath);
    expect(linuxConfigDir(env, golden.home)).toBe(golden.expect.configDir);
  });

  it('auth token path always lives under support dir (0600 contract documented)', () => {
    clearPathEnv();
    process.env.OPENBURNBAR_DAEMON_SUPPORT_DIR = '/secure/support';
    const token = linuxAuthTokenPath();
    expect(token).toBe('/secure/support/daemon-socket-auth-token');
    expect(token.startsWith(linuxSupportDir())).toBe(true);
    // Shell/Rust readers refuse group/other bits; packaging launch script chmod 600.
  });
});
