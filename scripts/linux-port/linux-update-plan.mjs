#!/usr/bin/env node

/**
 * Build the package-manager-native update/rollback plan shown by the Linux
 * shell. This module is deliberately pure: it never invokes a package
 * manager and never interpolates an unvalidated URL or executable path.
 */

const STRICT_SEMVER = /^(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)$/u;
const CHANNELS = new Set(['deb', 'rpm', 'appimage', 'unknown']);

function assertVersion(value, label) {
  if (typeof value !== 'string' || !STRICT_SEMVER.test(value)) {
    throw new Error(`${label} must be strict X.Y.Z semver`);
  }
  return value;
}

function action({ id, label, instruction, command, available, requiresConfirmation }) {
  if (/[;&|`$<>\n\r]/u.test(command ?? '')) {
    throw new Error(`${id} command contains shell metacharacters`);
  }
  return { id, label, instruction, command: command ?? null, available, requiresConfirmation };
}

export function buildLinuxUpdatePlan({
  packageChannel,
  currentVersion,
  latestVersion = null
}) {
  if (!CHANNELS.has(packageChannel)) throw new Error(`unsupported Linux package channel: ${packageChannel}`);
  const current = assertVersion(currentVersion, 'currentVersion');
  const latest = latestVersion == null ? null : assertVersion(latestVersion, 'latestVersion');
  const packageManager = packageChannel === 'deb'
    ? 'apt'
    : packageChannel === 'rpm'
      ? 'dnf'
      : packageChannel;
  const versionLabel = latest ?? current;
  const install = packageChannel === 'deb'
    ? action({
        id: 'install', label: 'Update with apt',
        instruction: 'Review the signed artifact, then let apt replace the installed package.',
        command: 'sudo apt-get install --only-upgrade open-burn-bar',
        available: true, requiresConfirmation: true
      })
    : packageChannel === 'rpm'
      ? action({
          id: 'install', label: 'Update with dnf',
          instruction: 'Review the signed artifact, then let dnf replace the installed package.',
          command: 'sudo dnf upgrade --refresh open-burn-bar',
          available: true, requiresConfirmation: true
        })
      : packageChannel === 'appimage'
        ? action({
            id: 'install', label: 'Replace the AppImage',
            instruction: 'Download the signed artifact, replace the current AppImage atomically, and keep its executable bit.',
            available: true, requiresConfirmation: true
          })
        : action({
            id: 'install', label: 'Use your package manager',
            instruction: 'Identify the owning package channel before replacing OpenBurnBar.',
            available: false, requiresConfirmation: true
          });
  const rollback = packageChannel === 'deb'
    ? action({
        id: 'rollback', label: 'Roll back with apt',
        instruction: `Choose a previously signed version, verify its digest, then ask apt to install that exact version (current: ${current}, feed: ${versionLabel}).`,
        command: 'sudo apt-get install --allow-downgrades open-burn-bar=PREVIOUS_VERSION',
        available: true, requiresConfirmation: true
      })
    : packageChannel === 'rpm'
      ? action({
          id: 'rollback', label: 'Roll back with dnf',
          instruction: `Choose a previously signed version, verify its digest, then downgrade the package (current: ${current}, feed: ${versionLabel}).`,
          command: 'sudo dnf downgrade open-burn-bar',
          available: true, requiresConfirmation: true
        })
      : packageChannel === 'appimage'
        ? action({
            id: 'rollback', label: 'Restore the previous AppImage',
            instruction: 'Restore a previously signed AppImage backup, verify its digest, and relaunch OpenBurnBar.',
            available: true, requiresConfirmation: true
          })
        : action({
            id: 'rollback', label: 'Rollback guidance unavailable',
            instruction: 'The owning package channel is unknown; do not replace binaries until it is identified.',
            available: false, requiresConfirmation: true
          });
  const restart = action({
    id: 'restart',
    label: 'Restart OpenBurnBar',
    instruction: 'Quit OpenBurnBar from the tray, let the package manager finish, then launch it again.',
    command: 'systemctl --user restart openburnbar-daemon.service',
    available: true,
    requiresConfirmation: false
  });
  return { packageManager, install, rollback, restart };
}

if (import.meta.url === `file://${process.argv[1]}`) {
  const args = new Map();
  for (let index = 2; index < process.argv.length; index += 2) args.set(process.argv[index], process.argv[index + 1]);
  try {
    const plan = buildLinuxUpdatePlan({
      packageChannel: args.get('--channel') ?? 'unknown',
      currentVersion: args.get('--current') ?? '0.0.0',
      latestVersion: args.get('--latest') ?? null
    });
    process.stdout.write(`${JSON.stringify(plan, null, 2)}\n`);
  } catch (error) {
    process.stderr.write(`${error instanceof Error ? error.message : String(error)}\n`);
    process.exitCode = 1;
  }
}
