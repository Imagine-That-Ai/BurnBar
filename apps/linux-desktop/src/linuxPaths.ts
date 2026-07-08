import { homedir } from 'node:os';
import { join } from 'node:path';

export function linuxSupportDir(): string {
  const xdg = process.env.XDG_DATA_HOME?.trim();
  if (xdg) return join(xdg, 'OpenBurnBar');
  return join(homedir(), '.local', 'share', 'openburnbar');
}

export function linuxSocketPath(): string {
  const override = process.env.OPENBURNBAR_SOCKET_PATH?.trim();
  if (override) return override;
  const runtime = process.env.XDG_RUNTIME_DIR?.trim();
  if (runtime) return join(runtime, 'openburnbar', 'daemon.sock');
  return join(linuxSupportDir(), 'openburnbar-daemon.sock');
}

export function linuxAuthTokenPath(): string {
  return join(linuxSupportDir(), 'daemon-socket-auth-token');
}

export function linuxConfigDir(): string {
  const xdg = process.env.XDG_CONFIG_HOME?.trim();
  if (xdg) return join(xdg, 'openburnbar');
  return join(homedir(), '.config', 'openburnbar');
}
