import type { KernelId } from '@openburnbar/gl-engine/engine/types';
import { useLaneLoad } from '../state/useLaneLoad.js';
import { useOverviewStore } from '../state/overviewStore.js';
import { DeckBurnHero } from './DeckBurnHero.js';
import { DeckOverflowMenu } from './DeckOverflowMenu.js';
import { DeckSectionSwitcher } from './DeckSectionSwitcher.js';
import { KernelSwitcher } from './KernelSwitcher.js';
import './CommandDeck.css';

/**
 * Command Deck — macOS-style top toolbar (`DashboardToolbarContent.swift`).
 *
 * [brand · section switcher · ⌘K] … [BURN hero · overflow]
 */
export function CommandDeck({
  onOpenCommandPalette,
  kernelId,
  onKernelChange
}: {
  onOpenCommandPalette: () => void;
  kernelId: KernelId;
  onKernelChange: (id: KernelId) => void;
}) {
  const summary = useOverviewStore((s) => s.summary);
  const loading = useOverviewStore((s) => s.loading);
  const load = useOverviewStore((s) => s.load);

  useLaneLoad(load);

  return (
    <header className="command-deck" role="banner">
      <div className="deck-brand">
        <span className="deck-brand-mark" aria-hidden="true">
          <svg viewBox="0 0 16 16" focusable="false">
            <path d="M8 2c1.8 1.2 3.2 3 3.8 5.2.5 1.8.4 3.6-.2 5.3-.4 1.1-1.1 2-2 2.7-.3.2-.7.3-1.1.3-.8 0-1.5-.5-1.9-1.2C5.8 13 5 11.2 5 9.2 5 6.4 6.2 4 8 2Z" />
          </svg>
        </span>
        <span className="deck-wordmark">
          Open<span className="deck-wordmark-accent">BurnBar</span>
        </span>
      </div>

      <DeckSectionSwitcher />

      <button
        type="button"
        className="ghost deck-cmdk-chip"
        onClick={onOpenCommandPalette}
        aria-label="Open command palette"
      >
        <span aria-hidden="true">⌘</span>K
      </button>

      <div className="deck-spacer" />

      <KernelSwitcher kernelId={kernelId} onKernelChange={onKernelChange} />

      <DeckBurnHero summary={summary} loading={loading && !summary} />

      <DeckOverflowMenu recountDisabled />
    </header>
  );
}