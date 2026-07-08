import { displayLinuxConfigDir, displayLinuxSocketPath } from './shellPaths.js';

export type OnboardingStep = { title: string; body: string };

/**
 * Linux first-run wizard copy. Every step names a real Linux permission,
 * path, or trust boundary — the wizard never silently grants anything.
 * The evidence harness cites this module as the copy source of truth.
 */
export const ONBOARDING_STEPS: OnboardingStep[] = [
  {
    title: 'Local daemon & socket',
    body: `OpenBurnBar talks to the Linux peer over AF_UNIX at ${displayLinuxSocketPath()}. Start the daemon with openburnbar-cli service foreground or your systemd user unit before using dashboard features.`
  },
  {
    title: 'Secret Service / SQLCipher',
    body: `Database keys live in libsecret/KWallet when available. Headless peers may require an explicit passphrase path documented in Settings. Config: ${displayLinuxConfigDir()}.`
  },
  {
    title: 'Provider log paths',
    body: 'Linux parsers read ~/.local/share/opencode, ~/.local/share/goose/sessions, ~/.codex, and other XDG paths. Confirm paths in Settings → Providers before expecting ingest.'
  },
  {
    title: 'Cloud identity & sync trust',
    body: 'Linux cloud identity starts lower-trust. Local SQLite remains canonical while signed out, and encrypted sync only resumes after explicit login and SecretStore recovery.'
  },
  {
    title: 'Portal capture & input',
    body: 'Wayland screen capture and remote control require xdg-desktop-portal consent. Computer Use adapters are separate; this shell surfaces permission copy and Support diagnostics only.'
  },
  {
    title: 'Tray & desktop environment',
    body: 'Ayatana AppIndicator is used when present. Some DEs hide legacy tray icons — use Support → Reopen dashboard and keep the app pinned if the tray is unavailable.'
  },
  {
    title: 'Updates & restart',
    body: 'Package updates are verified through the Linux package channel. If a package replacement requires restart, quit from the tray or Support after the package manager finishes.'
  },
  {
    title: 'Privacy choices',
    body: 'Provider paths, telemetry, and cloud sync are opt-in surfaces. Redacted diagnostics can be exported from Support without exposing provider payloads or local secrets.'
  }
];
