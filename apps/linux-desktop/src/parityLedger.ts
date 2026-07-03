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
    linux: 'In-app expansion only (v1)',
    substitution:
      'Future IME/fcitx/IBus integration with per-DE tests; no evdev/global keylogger in v1.'
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
  }
];