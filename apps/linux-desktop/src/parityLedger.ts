export type ParityRow = {
  feature: string;
  macos: string;
  linux: string;
  substitution?: string;
};

export const PARITY_LEDGER: ParityRow[] = [
  {
    feature: 'System-wide text expansion (Wayland)',
    macos: 'CGEvent session tap + Accessibility',
    linux: 'Explicit-consent signed IBus engine when the packaged daemon reports it; in-app fallback otherwise',
    substitution:
      'Fcitx native addon remains unavailable; secure-field denial and no evdev/global keylogger are enforced.'
  },
  {
    feature: 'PetCompanion always-on-top click-through',
    macos: 'NSPanel non-activating overlay',
    linux: 'Tier A pass-through overlay when supported; Tier B draggable panel on GNOME Wayland and restricted DEs.'
  },
  {
    feature: 'Menu bar tray',
    macos: 'NSStatusItem / MenuBarExtra',
    linux: 'Ayatana AppIndicator when present; otherwise documented DE fallback via Support route.'
  },
  {
    feature: 'Mercury media engine (calls, screen share, file transfer)',
    macos: 'In-process Mercury engine with live call UX',
    linux: 'Daemon-owned iroh sessions, call controls, portal/PipeWire capture, encrypted media frames, and bidirectional file transfer.',
    substitution: 'Runtime capability probing keeps the route available for calls and files when capture codecs are degraded, and blocks it when the daemon media runtime is absent.'
  },
  {
    feature: 'Chat tool approvals',
    macos: 'In-chat tool approval riding in-process agent runs',
    linux: 'Daemon-issued approval IDs enable approve/reject/cancel in chat; gateway calls without a verified run identity remain unavailable.',
    substitution: 'Gateway tool calls without a daemon approval identity stay visibly unavailable rather than inventing an approval token.'
  },
  {
    feature: 'Memory review queue',
    macos: 'In-process MemoryServing quarantine inbox (no daemon RPC on any platform)',
    linux: 'Daemon-owned review status supports pending, approved, rejected, and forgotten transitions with a bounded quarantine feed and audit hashes; fixture mode only demos the queue UX.',
    substitution:
      'Cross-device review replication and installed cloud-authority proof remain separate from the local daemon lifecycle.'
  },
  {
    feature: 'Smart-display integration controls',
    macos: 'Live layout/palette/theme pickers and test-display actions in Settings',
    linux: 'Typed root-owned discovery/status/test probes for SmartHub, Cast, Home Assistant, PixelClock, and AWTRIX via the trusted packaged CLI.',
    substitution: 'Device-specific configuration remains daemon/CLI-owned; the renderer never exposes arbitrary shell or credential fields.'
  }
];
