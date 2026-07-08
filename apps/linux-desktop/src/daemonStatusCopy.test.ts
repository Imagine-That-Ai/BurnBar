import { describe, expect, it } from 'vitest';
import { buildDaemonStatusCopy } from './daemonStatusCopy.js';

const socketPath = '~/.local/share/openburnbar/openburnbar-daemon.sock';

describe('buildDaemonStatusCopy', () => {
  it('maps a missing AF_UNIX socket error to product copy while preserving raw diagnostics', () => {
    const status = buildDaemonStatusCopy({
      ok: false,
      fixtureMode: false,
      bridgeAvailable: true,
      healthError: 'No such file or directory (os error 2)',
      displaySocketPath: socketPath
    });

    expect(status.label).toBe('Daemon offline');
    expect(status.detail).toContain(socketPath);
    expect(status.detail).not.toContain('os error 2');
    expect(status.rawDetail).toBe('No such file or directory (os error 2)');
    expect(status.tone).toBe('err');
  });

  it('keeps browser preview mode distinct from packaged daemon failure', () => {
    const status = buildDaemonStatusCopy({
      ok: false,
      fixtureMode: false,
      bridgeAvailable: false,
      healthError: 'Packaged shell required for live daemon health (browser preview mode).',
      displaySocketPath: socketPath
    });

    expect(status.label).toBe('Browser preview mode');
    expect(status.tone).toBe('warn');
    expect(status.detail).toContain('packaged Linux app');
  });

  it('names permission failures without implying the daemon is missing', () => {
    const status = buildDaemonStatusCopy({
      ok: false,
      fixtureMode: false,
      bridgeAvailable: true,
      healthError: 'EACCES permission denied',
      displaySocketPath: socketPath
    });

    expect(status.label).toBe('Daemon permission blocked');
    expect(status.detail).toContain('socket ownership');
    expect(status.rawDetail).toBe('EACCES permission denied');
  });
});
