import type { KernelId } from '@openburnbar/gl-engine/engine/types';
import { DeckBurnHero } from './DeckBurnHero.js';
import { DeckBrandMark } from './DeckBrandMark.js';
import { DeckOverflowMenu } from './DeckOverflowMenu.js';
import { KernelSwitcher } from './KernelSwitcher.js';
import { StatusPill } from './StatusPill.js';
import { TopTabbar } from './TopTabbar.js';
import { WorkspaceContextPill } from './WorkspaceContextPill.js';
import { useLaneLoad } from '../state/useLaneLoad.js';
import { useOverviewStore } from '../state/overviewStore.js';
import { useDaemonStatusCopy, useShellStore } from '../state/shellStore.js';
import { usePrimarySectionShortcuts } from './usePrimarySectionShortcuts.js';
import './TopChrome.css';
import './CommandDeck.css';

type TopChromeProps = {
  onOpenCommandPalette: () => void;
  kernelId: KernelId;
  onKernelChange: (id: KernelId) => void;
};

/**
 * macOS Command Deck + primary tab strip (`BurnBarTopRail` + `DashboardMainRoute`).
 */
export function TopChrome({ onOpenCommandPalette, kernelId, onKernelChange }: TopChromeProps) {
  const status = useDaemonStatusCopy();
  const summary = useOverviewStore((s) => s.summary);
  const loading = useOverviewStore((s) => s.loading);
  const load = useOverviewStore((s) => s.load);
  const setRoute = useShellStore((s) => s.setRoute);

  usePrimarySectionShortcuts(setRoute);
  useLaneLoad(load);

  return (
    <div className="top-chrome">
      <header className="command-deck top-toolbar" role="banner">
        <DeckBrandMark logoOnly />

        <button
          type="button"
          className="top-omnibar"
          onClick={onOpenCommandPalette}
          aria-label="Open command palette"
        >
          <span className="top-omnibar-icon" aria-hidden="true">
            ⌘
          </span>
          <span className="top-omnibar-placeholder">Search or jump to…</span>
          <kbd className="top-omnibar-kbd">⌘K</kbd>
        </button>

        <WorkspaceContextPill />

        <div className="deck-spacer" />

        <StatusPill status={status} />

        <KernelSwitcher kernelId={kernelId} onKernelChange={onKernelChange} />

        <DeckBurnHero summary={summary} loading={loading && !summary} />

        <button
          type="button"
          className="ghost deck-capsule-trigger deck-capsule-trigger--icon deck-toolbar-icon"
          title="Import sessions"
          onClick={() => setRoute('support')}
        >
          <span aria-hidden="true">↓</span>
        </button>
        <button
          type="button"
          className="ghost deck-capsule-trigger deck-capsule-trigger--icon deck-toolbar-icon"
          title="Account"
          onClick={() => setRoute('account')}
        >
          <span aria-hidden="true">◎</span>
        </button>
        <button
          type="button"
          className="ghost deck-capsule-trigger deck-capsule-trigger--icon deck-toolbar-icon"
          title="Settings"
          onClick={() => setRoute('settings')}
        >
          <span aria-hidden="true">⚙</span>
        </button>

        <DeckOverflowMenu recountDisabled />
      </header>
      <TopTabbar />
    </div>
  );
}