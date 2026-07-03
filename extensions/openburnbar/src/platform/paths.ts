import { homedir } from 'node:os';
import { join } from 'node:path';

function linuxXdgConfigHome(): string {
  return process.env.XDG_CONFIG_HOME ?? join(homedir(), '.config');
}

/** Default OpenBurnBar support directory for the current OS (override via env). */
export function defaultBurnBarSupportDir(): string {
  const override = process.env.OPENBURNBAR_DAEMON_SUPPORT_DIR ?? process.env.BURNBAR_DAEMON_SUPPORT_DIR;
  if (override?.trim()) {
    return override.trim();
  }
  if (process.platform === 'darwin') {
    return join(homedir(), 'Library', 'Application Support', 'OpenBurnBar');
  }
  if (process.platform === 'linux') {
    return join(linuxXdgConfigHome(), 'OpenBurnBar');
  }
  return join(homedir(), '.openburnbar');
}

export function defaultBurnBarSocketPath(): string {
  const override = process.env.OPENBURNBAR_DAEMON_SOCKET_PATH ?? process.env.BURNBAR_DAEMON_SOCKET_PATH;
  if (override?.trim()) {
    return override.trim();
  }
  return join(defaultBurnBarSupportDir(), 'openburnbar-daemon.sock');
}

export function defaultBurnBarSocketAuthTokenFile(): string {
  const override =
    process.env.OPENBURNBAR_DAEMON_SOCKET_AUTH_TOKEN_FILE ??
    process.env.BURNBAR_DAEMON_SOCKET_AUTH_TOKEN_FILE;
  if (override?.trim()) {
    return override.trim();
  }
  return join(defaultBurnBarSupportDir(), 'daemon-socket-auth-token');
}

/** Documented Linux unit path sample for extension-host / operator docs. */
export function defaultLinuxSystemdUnitPath(): string {
  return join(homedir(), '.config', 'systemd', 'user', 'openburnbar-daemon.service');
}