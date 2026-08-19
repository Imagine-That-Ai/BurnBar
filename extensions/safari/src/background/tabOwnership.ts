import type { BrowserTab } from '../shared/browser';
import { SafariExtensionError } from '../shared/errors';

interface OwnedTab {
  tabId: number;
  sessionId: string;
  source: 'user-handed' | 'agent-opened';
  claimedAt: string;
  origin?: string;
}

export class TabOwnershipRegistry {
  private readonly tabs = new Map<number, OwnedTab>();

  claimUserHanded(tab: BrowserTab, sessionId: string, now: () => Date = () => new Date()): OwnedTab {
    const tabId = this.requireTabId(tab);
    if (!tab.active) {
      throw new SafariExtensionError('tab_not_active', 'The user-handed Safari tab must be active.');
    }
    const origin = tab.url ? safeOrigin(tab.url) : undefined;
    const ownership: OwnedTab = {
      tabId,
      sessionId,
      source: 'user-handed',
      claimedAt: now().toISOString(),
      ...(origin === undefined ? {} : { origin })
    };
    this.tabs.set(tabId, ownership);
    return ownership;
  }

  registerAgentOpened(tab: BrowserTab, sessionId: string, now: () => Date = () => new Date()): OwnedTab {
    const tabId = this.requireTabId(tab);
    const origin = tab.url ? safeOrigin(tab.url) : undefined;
    const ownership: OwnedTab = {
      tabId,
      sessionId,
      source: 'agent-opened',
      claimedAt: now().toISOString(),
      ...(origin === undefined ? {} : { origin })
    };
    this.tabs.set(tabId, ownership);
    return ownership;
  }

  assertOwned(tab: BrowserTab, sessionId: string, requireActive = true): OwnedTab {
    const tabId = this.requireTabId(tab);
    const ownership = this.tabs.get(tabId);
    if (!ownership || ownership.sessionId !== sessionId) {
      throw new SafariExtensionError(
        'tab_not_owned',
        'OpenBurnBar may only control the tab the user handed it or a tab it opened.'
      );
    }
    if (requireActive && !tab.active) {
      throw new SafariExtensionError('background_tab_blocked', 'OpenBurnBar never acts on a background tab.');
    }
    return ownership;
  }

  release(tabId: number): void {
    this.tabs.delete(tabId);
  }

  releaseSession(sessionId: string): void {
    for (const [tabId, ownership] of this.tabs) {
      if (ownership.sessionId === sessionId) {
        this.tabs.delete(tabId);
      }
    }
  }

  isOwned(tabId: number, sessionId?: string): boolean {
    const ownership = this.tabs.get(tabId);
    return Boolean(ownership && (sessionId === undefined || ownership.sessionId === sessionId));
  }

  list(): OwnedTab[] {
    return [...this.tabs.values()];
  }

  private requireTabId(tab: BrowserTab): number {
    if (typeof tab.id !== 'number') {
      throw new SafariExtensionError('tab_id_missing', 'Safari did not provide an active tab identifier.');
    }
    return tab.id;
  }
}

function safeOrigin(url: string): string | undefined {
  try {
    return new URL(url).origin;
  } catch {
    return undefined;
  }
}
