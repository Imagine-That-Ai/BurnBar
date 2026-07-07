import type { KernelId } from '@openburnbar/gl-engine/engine/types';
import { useLaneLoad } from '../state/useLaneLoad.js';
import { useOverviewStore } from '../state/overviewStore.js';
import { DeckBurnHero } from './DeckBurnHero.js';
import { DeckBrandMark } from './DeckBrandMark.js';
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
      <DeckBrandMark />

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