import { providerDisplayPaths } from './providerPathRegistry.js';
import { displayLinuxConfigDir, displayLinuxSocketPath } from './shellPaths.js';
import type { LinuxOnboardingRequirement, LinuxOnboardingStepId } from './onboardingStore.js';

export type OnboardingStep = {
  id: LinuxOnboardingStepId;
  requirement: LinuxOnboardingRequirement;
  title: string;
  body: string;
  /** Compact mono-friendly glyph shown in the glass step badge. */
  glyph: string;
  /** Uppercase micro-label under the step number (editorial kicker). */
  kicker: string;
};

/**
 * Linux first-run wizard copy. Every step names a real Linux permission,
 * path, or trust boundary — the wizard never silently grants anything.
 * The evidence harness cites this module as the copy source of truth.
 */
export const ONBOARDING_STEPS: OnboardingStep[] = [
  {
    id: 'daemon',
    requirement: 'required',
    title: 'Local daemon & socket',
    glyph: '⌬',
    kicker: 'Peer link',
    body: `OpenBurnBar talks to the Linux peer over AF_UNIX at ${displayLinuxSocketPath()}. openburnbar-cli service foreground starts the packaged systemd user unit when needed, or you can start the unit directly before using dashboard features. Support data lives under ~/.local/share/openburnbar (XDG_DATA_HOME). If you still have a legacy ~/.config/OpenBurnBar directory, set OPENBURNBAR_DAEMON_SUPPORT_DIR to that path or move the tree before first launch.`
  },
  {
    id: 'secret_store',
    requirement: 'required',
    title: 'Secret Service / SQLCipher',
    glyph: '⬡',
    kicker: 'Key custody',
    body: `Database keys live in libsecret/KWallet when available. Headless peers may require an explicit passphrase path documented in Settings. Config: ${displayLinuxConfigDir()}.`
  },
  {
    id: 'provider_paths',
    requirement: 'required',
    title: 'Local data & provider paths',
    glyph: '☰',
    kicker: 'XDG paths',
    body: `OpenBurnBar first verifies that its XDG support directory can persist local data. Provider scanners then look in ${providerDisplayPaths().slice(0, 5).join(', ')}, with the full list under Settings → Providers. Provider connection is confirmed separately.`
  },
  {
    id: 'cloud_identity',
    requirement: 'optional',
    title: 'Cloud identity & sync trust',
    glyph: '◇',
    kicker: 'Trust boundary',
    body: 'Linux cloud identity starts lower-trust. Local SQLite remains canonical while signed out, and encrypted sync only resumes after explicit login and SecretStore recovery.'
  },
  {
    id: 'portal_input',
    requirement: 'optional',
    title: 'Portal capture & input',
    glyph: '⊞',
    kicker: 'Wayland consent',
    body: 'Wayland screen capture and remote control require xdg-desktop-portal consent. Computer Use adapters are separate; this shell surfaces permission copy and Support diagnostics only.'
  },
  {
    id: 'tray',
    requirement: 'optional',
    title: 'Tray & desktop environment',
    glyph: '▤',
    kicker: 'Shell chrome',
    body: 'Ayatana AppIndicator is used when present. Some DEs hide legacy tray icons — use Support → Reopen dashboard and keep the app pinned if the tray is unavailable.'
  },
  {
    id: 'updates',
    requirement: 'optional',
    title: 'Updates & restart',
    glyph: '↻',
    kicker: 'Package channel',
    body: 'Package updates are verified through the Linux package channel. If a package replacement requires restart, quit from the tray or Support after the package manager finishes.'
  },
  {
    id: 'privacy',
    requirement: 'required',
    title: 'Privacy choices',
    glyph: '◉',
    kicker: 'Opt-in only',
    body: 'Provider paths, telemetry, and cloud sync are opt-in surfaces. Redacted diagnostics can be exported from Support without exposing provider payloads or local secrets.'
  }
];
