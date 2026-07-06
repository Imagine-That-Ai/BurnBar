import type { KernelId } from '@openburnbar/gl-engine/engine/types';
import { DeckBurnHero } from './DeckBurnHero.js';
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

        <button
          type="button"
          className="top-omnibar"
          onClick={onOpenCommandPalette}
          aria-label="Search and jump (Command K)"
        >
          <span className="top-omnibar-icon" aria-hidden="true">
            <svg width="14" height="14" viewBox="0 0 16 16" focusable="false">
              <path
                fill="currentColor"
                d="M7 2.5a4.5 4.5 0 1 1 0 9 4.5 4.5 0 0 1 0-9Zm5.2 9.8 2.3 2.3-1.1 1.1-2.3-2.3 1.1-1.1Z"
              />
            </svg>
          </span>
          <span className="top-omnibar-placeholder">Search sessions, routes, settings…</span>
          <span className="top-omnibar-kbd" aria-hidden="true">
            ⌘K
          </span>
        </button>

        <WorkspaceContextPill />

        <div className="deck-spacer" />

        <StatusPill status={status} />

        <KernelSwitcher kernelId={kernelId} onKernelChange={onKernelChange} />

        <DeckBurnHero summary={summary} loading={loading && !summary} />

        <button
          type="button"
          className="ghost deck-toolbar-icon"
          aria-label="Import sessions"
          title="Import sessions"
          onClick={() => setRoute('support')}
        >
          <span aria-hidden="true">↓</span>
        </button>
        <button
          type="button"
          className="ghost deck-toolbar-icon"
          aria-label="Recount totals"
          title="Recount totals"
          disabled
        >
          <span aria-hidden="true">↻</span>
        </button>
        <button
          type="button"
          className="ghost deck-toolbar-icon"
          aria-label="Settings"
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