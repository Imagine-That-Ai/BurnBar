import { homedir } from 'node:os';
import { join } from 'node:path';

/**
 * Canonical Linux path contract (XDG).
 *
 * - Runtime socket: `$XDG_RUNTIME_DIR/openburnbar/daemon.sock`
 * - Support / data: `$XDG_DATA_HOME/openburnbar` (default `~/.local/share/openburnbar`)
 * - Config: `$XDG_CONFIG_HOME/openburnbar` (default `~/.config/openburnbar`)
 * - Auth token: `<support>/daemon-socket-auth-token`
 *
 * Casing is lowercase `openburnbar` for XDG segments. Overrides:
 * - `OPENBURNBAR_SOCKET_PATH` / `OPENBURNBAR_DAEMON_SOCKET_PATH`
 * - `OPENBURNBAR_DAEMON_SUPPORT_DIR` / `BURNBAR_DAEMON_SUPPORT_DIR`
 */
export const LINUX_APP_DIR_NAME = 'openburnbar';
export const LINUX_SOCKET_FILE_NAME = 'daemon.sock';
export const LINUX_SOCKET_FALLBACK_FILE_NAME = 'openburnbar-daemon.sock';
export const LINUX_AUTH_TOKEN_FILE_NAME = 'daemon-socket-auth-token';

function nonEmpty(value: string | undefined): string | undefined {
  const trimmed = value?.trim();
  return trimmed ? trimmed : undefined;
}

export function linuxSupportDir(
  env: NodeJS.ProcessEnv = process.env,
  home: string = homedir()
): string {
  const override =
    nonEmpty(env.OPENBURNBAR_DAEMON_SUPPORT_DIR) ?? nonEmpty(env.BURNBAR_DAEMON_SUPPORT_DIR);
  if (override) return override;
  const xdg = nonEmpty(env.XDG_DATA_HOME);
  if (xdg) return join(xdg, LINUX_APP_DIR_NAME);
  return join(home, '.local', 'share', LINUX_APP_DIR_NAME);
}

export function linuxSocketPath(
  env: NodeJS.ProcessEnv = process.env,
  home: string = homedir()
): string {
  const override =
    nonEmpty(env.OPENBURNBAR_SOCKET_PATH) ??
    nonEmpty(env.OPENBURNBAR_DAEMON_SOCKET_PATH) ??
    nonEmpty(env.BURNBAR_DAEMON_SOCKET_PATH);
  if (override) return override;
  const runtime = nonEmpty(env.XDG_RUNTIME_DIR);
  if (runtime) return join(runtime, LINUX_APP_DIR_NAME, LINUX_SOCKET_FILE_NAME);
  return join(linuxSupportDir(env, home), LINUX_SOCKET_FALLBACK_FILE_NAME);
}

export function linuxAuthTokenPath(
  env: NodeJS.ProcessEnv = process.env,
  home: string = homedir()
): string {
  return join(linuxSupportDir(env, home), LINUX_AUTH_TOKEN_FILE_NAME);
}

export function linuxConfigDir(
  env: NodeJS.ProcessEnv = process.env,
  home: string = homedir()
): string {
  const xdg = nonEmpty(env.XDG_CONFIG_HOME);
  if (xdg) return join(xdg, LINUX_APP_DIR_NAME);
  return join(home, '.config', LINUX_APP_DIR_NAME);
}

/** Path contract snapshot for settings / onboarding / diagnostics. */
export function linuxPathContract(
  env: NodeJS.ProcessEnv = process.env,
  home: string = homedir()
): {
  supportDir: string;
  socketPath: string;
  configDir: string;
  authTokenPath: string;
  runtimeDir: string | null;
} {
  return {
    supportDir: linuxSupportDir(env, home),
    socketPath: linuxSocketPath(env, home),
    configDir: linuxConfigDir(env, home),
    authTokenPath: linuxAuthTokenPath(env, home),
    runtimeDir: nonEmpty(env.XDG_RUNTIME_DIR) ?? null
  };
}
