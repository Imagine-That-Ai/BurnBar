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
    linux: 'Approval buttons disabled; approval flows ride agent runs, not gateway chat.',
    substitution: 'Wire workspace.executeTool / approval.respond when Linux agent runs land in the shell.'
  },
  {
    feature: 'Memory review queue',
    macos: 'In-process MemoryServing quarantine inbox (no daemon RPC on any platform)',
    linux: 'Recalled memories shown as approved with revoke-as-forget via daemon.memory.forget; fixture mode demos the queue UX.'
  },
  {
    feature: 'Smart-display integration controls',
    macos: 'Live layout/palette/theme pickers and test-display actions in Settings',
    linux: 'Read-and-explain status rows from openburnbar-cli devices parity; configuration happens daemon/CLI-side in v1.'
  }
];
