import { providerDisplayPaths } from './providerPathRegistry.js';
import { displayLinuxConfigDir, displayLinuxSocketPath } from './shellPaths.js';

export type OnboardingStep = {
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
    title: 'Local daemon & socket',
    glyph: '⌬',
    kicker: 'Peer link',
    body: `OpenBurnBar talks to the Linux peer over AF_UNIX at ${displayLinuxSocketPath()}. Start the daemon with openburnbar-cli service foreground or your systemd user unit before using dashboard features. Support data lives under ~/.local/share/openburnbar (XDG_DATA_HOME). If you still have a legacy ~/.config/OpenBurnBar directory, set OPENBURNBAR_DAEMON_SUPPORT_DIR to that path or move the tree before first launch.`
  },
  {
    title: 'Secret Service / SQLCipher',
    glyph: '⬡',
    kicker: 'Key custody',
    body: `Database keys live in libsecret/KWallet when available. Headless peers may require an explicit passphrase path documented in Settings. Config: ${displayLinuxConfigDir()}.`
  },
  {
    title: 'Provider log paths',
    glyph: '☰',
    kicker: 'XDG paths',
    body: `Linux parsers and Settings share one provider path registry. Primary paths: ${providerDisplayPaths().slice(0, 5).join(', ')}, and more under Settings → Providers.`
  },
  {
    title: 'Cloud identity & sync trust',
    glyph: '◇',
    kicker: 'Trust boundary',
    body: 'Linux cloud identity starts lower-trust. Local SQLite remains canonical while signed out, and encrypted sync only resumes after explicit login and SecretStore recovery.'
  },
  {
    title: 'Portal capture & input',
    glyph: '⊞',
    kicker: 'Wayland consent',
    body: 'Wayland screen capture and remote control require xdg-desktop-portal consent. Computer Use adapters are separate; this shell surfaces permission copy and Support diagnostics only.'
  },
  {
    title: 'Tray & desktop environment',
    glyph: '▤',
    kicker: 'Shell chrome',
    body: 'Ayatana AppIndicator is used when present. Some DEs hide legacy tray icons — use Support → Reopen dashboard and keep the app pinned if the tray is unavailable.'
  },
  {
    title: 'Updates & restart',
    glyph: '↻',
    kicker: 'Package channel',
    body: 'Package updates are verified through the Linux package channel. If a package replacement requires restart, quit from the tray or Support after the package manager finishes.'
  },
  {
    title: 'Privacy choices',
    glyph: '◉',
    kicker: 'Opt-in only',
    body: 'Provider paths, telemetry, and cloud sync are opt-in surfaces. Redacted diagnostics can be exported from Support without exposing provider payloads or local secrets.'
  }
];
