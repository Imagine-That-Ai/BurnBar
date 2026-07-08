import { afterEach, describe, expect, it } from 'vitest';
import { linuxSocketPath } from './linuxPaths.js';

const originalEnv = {
  OPENBURNBAR_SOCKET_PATH: process.env.OPENBURNBAR_SOCKET_PATH,
  XDG_RUNTIME_DIR: process.env.XDG_RUNTIME_DIR
};

afterEach(() => {
  if (originalEnv.OPENBURNBAR_SOCKET_PATH === undefined) {
    delete process.env.OPENBURNBAR_SOCKET_PATH;
  } else {
    process.env.OPENBURNBAR_SOCKET_PATH = originalEnv.OPENBURNBAR_SOCKET_PATH;
  }
  if (originalEnv.XDG_RUNTIME_DIR === undefined) {
    delete process.env.XDG_RUNTIME_DIR;
  } else {
    process.env.XDG_RUNTIME_DIR = originalEnv.XDG_RUNTIME_DIR;
  }
});

describe('linuxSocketPath', () => {
  it('keeps explicit socket overrides authoritative', () => {
    process.env.OPENBURNBAR_SOCKET_PATH = '/tmp/openburnbar/custom.sock';
    process.env.XDG_RUNTIME_DIR = '/run/user/501';

    expect(linuxSocketPath()).toBe('/tmp/openburnbar/custom.sock');
  });

  it('defaults to the systemd user runtime socket', () => {
    delete process.env.OPENBURNBAR_SOCKET_PATH;
    process.env.XDG_RUNTIME_DIR = '/run/user/501';

    expect(linuxSocketPath()).toBe('/run/user/501/openburnbar/daemon.sock');
  });
});
