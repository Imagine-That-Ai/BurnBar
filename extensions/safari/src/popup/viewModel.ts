import { agentsForMode, type PopupSnapshot } from '../shared/messages';
import type { BridgeAgentOption, SafariMode } from '../shared/protocol';
import type { PopupLocalState } from './state';

export interface PopupModeOption {
  id: SafariMode;
  label: string;
  accessibleLabel: string;
  description: string;
}

export interface PopupAgentGroup {
  label: string;
  agents: BridgeAgentOption[];
}

export interface PopupViewModel {
  ready: boolean;
  connectionLabel: string;
  connectionTone: 'ready' | 'warning' | 'offline';
  pageLabel: string;
  pageDetail: string;
  pageSensitive: boolean;
  permissionLabel: string;
  modes: PopupModeOption[];
  selectedMode: SafariMode;
  modeDescription: string;
  agentGroups: PopupAgentGroup[];
  selectedAgent?: BridgeAgentOption;
  noAgents: boolean;
  agentFilter: string;
  correctionDraft: string;
  correctionByteCount: number;
  correctionSubmitDisabled: boolean;
  correctionDisabledReason?: string;
  diagnosticsNotice?: {
    tone: 'success' | 'warning' | 'error';
    text: string;
  };
  diagnosticsClearArmed: boolean;
  draft: string;
  composerReadOnly: boolean;
  composerPlaceholder: string;
  primaryLabel: string;
  primaryDisabled: boolean;
  primaryDisabledReason?: string;
  showCloudDisclosure: boolean;
  showPermissionSheet: boolean;
  permissionSheetHost: string;
  permissionSheetNeedsSafari: boolean;
  permissionSheetNeedsSiteTrust: boolean;
  permissionSheetNeedsCloudDisclosure: boolean;
  stopEnabled: boolean;
  snapshot?: PopupSnapshot;
}

const DEFAULT_POPUP_MODE: PopupModeOption = {
  id: 'ask',
  label: 'Ask',
  accessibleLabel: 'Ask about this page',
  description: 'See the page with precise text and a live viewport image.'
};

const POPUP_MODES: PopupModeOption[] = [
  DEFAULT_POPUP_MODE,
  {
    id: 'agentic',
    label: 'Act',
    accessibleLabel: 'Agentic mode',
    description: 'Plan and perform verified steps through OpenBurnBar’s Computer Use rails.'
  },
  {
    id: 'watch',
    label: 'Watch',
    accessibleLabel: 'Watch and approve',
    description: 'Mirror active runs, inspect each proposed action, and approve from Safari.'
  },
  {
    id: 'handoff',
    label: 'Hand off',
    accessibleLabel: 'Hand off to an installed agent',
    description: 'Give an installed agent a read-only page briefing and follow its run.'
  }
];

const MAX_LEARNING_CORRECTION_BYTES = 4 * 1024;
const MIN_LEARNING_CORRECTION_BYTES = 8;

function groupAgents(agents: BridgeAgentOption[]): PopupAgentGroup[] {
  const groups = new Map<string, BridgeAgentOption[]>();
  for (const agent of agents) {
    const label = agent.kind === 'cli' ? 'Installed agents' : agent.providerName;
    const group = groups.get(label) ?? [];
    group.push(agent);
    groups.set(label, group);
  }
  return [...groups.entries()]
    .sort(([left], [right]) => left.localeCompare(right))
    .map(([label, items]) => ({
      label,
      agents: items.sort((left, right) => left.displayName.localeCompare(right.displayName))
    }));
}

function primaryDisabledReason(snapshot: PopupSnapshot, selectedAgent?: BridgeAgentOption): string | undefined {
  if (snapshot.bridge.connection === 'disconnected') {
    return 'Open the OpenBurnBar app or repair the daemon connection.';
  }
  if (snapshot.busy) {
    return 'OpenBurnBar is already handling another request.';
  }
  if (snapshot.mode === 'watch') {
    return 'Watch mode is read-only. Switch to Ask, Act, or Hand off to start a request.';
  }
  if (!snapshot.page) {
    return 'Open a regular webpage in Safari.';
  }
  if (snapshot.page.permission === 'unsupported') {
    return 'Safari does not allow extensions on this page.';
  }
  if (snapshot.page.permission !== 'granted') {
    return 'Grant Safari website access before sharing page context.';
  }
  if (!snapshot.trust.siteAllowed) {
    return 'Allow this website in Trust controls.';
  }
  if (snapshot.mode !== 'ask' && (snapshot.trust.globalKillSwitch || snapshot.bridge.killSwitchEnabled)) {
    return 'The global Computer Use kill switch is on. Ask mode remains available.';
  }
  if (!selectedAgent) {
    return snapshot.mode === 'handoff' ? 'No installed agent CLI is available.' : 'No compatible model is available.';
  }
  if (snapshot.mode === 'ask' && !snapshot.bridge.gatewayReady) {
    return 'The local OpenBurnBar model gateway is unavailable.';
  }
  if (snapshot.page.sensitive && snapshot.mode !== 'ask' && !snapshot.trust.sensitiveSiteOverride) {
    return 'This sensitive site needs an explicit override before agentic actions.';
  }
  if (selectedAgent.cloud && !snapshot.trust.cloudScreenshotAcknowledged) {
    return 'Acknowledge the cloud screenshot disclosure for this session.';
  }
  return undefined;
}

function correctionDisabledReason(state: PopupLocalState, snapshot: PopupSnapshot | undefined): string | undefined {
  if (!snapshot) {
    return 'Connecting to OpenBurnBar…';
  }
  if (!snapshot.learning.eligible || !snapshot.learning.optedIn) {
    return 'Turn on Pro+ learning first.';
  }
  if (snapshot.bridge.connection !== 'connected') {
    return 'Reconnect OpenBurnBar before teaching a correction.';
  }
  if (state.submitting || snapshot.busy) {
    return 'Wait for the current request to finish.';
  }
  if (!snapshot.page || !snapshot.page.isActive || !snapshot.page.isTopFrame) {
    return 'Open the page this correction belongs to.';
  }
  if (snapshot.page.permission !== 'granted' || !snapshot.trust.siteAllowed) {
    return 'Allow this website before teaching a correction.';
  }
  const byteLength = new TextEncoder().encode(state.correctionDraft.trim()).byteLength;
  if (byteLength < MIN_LEARNING_CORRECTION_BYTES) {
    return 'Write a specific correction using at least 8 bytes.';
  }
  if (byteLength > MAX_LEARNING_CORRECTION_BYTES) {
    return 'Shorten this correction to 4 KiB or less.';
  }
  return undefined;
}

export function buildPopupViewModel(state: PopupLocalState): PopupViewModel {
  const snapshot = state.snapshot;
  const selectedMode = snapshot?.mode ?? 'ask';
  const mode = POPUP_MODES.find((option) => option.id === selectedMode) ?? DEFAULT_POPUP_MODE;
  const available = snapshot ? agentsForMode(snapshot.bridge.agents, selectedMode) : [];
  const query = state.agentFilter.trim().toLocaleLowerCase();
  const filtered = query
    ? available.filter((agent) => `${agent.displayName} ${agent.providerName}`.toLocaleLowerCase().includes(query))
    : available;
  const selectedAgent = available.find((agent) => agent.id === snapshot?.selectedAgentId);
  const disabledReason = snapshot ? primaryDisabledReason(snapshot, selectedAgent) : 'Connecting to OpenBurnBar…';
  const learningCorrectionDisabledReason = correctionDisabledReason(state, snapshot);
  const correctionByteCount = new TextEncoder().encode(state.correctionDraft.trim()).byteLength;
  const pageURL = snapshot?.page?.url;
  let pageDetail = 'Open a webpage to begin';
  let pageOrigin = '';
  if (pageURL) {
    try {
      const parsed = new URL(pageURL);
      pageDetail = parsed.hostname;
      pageOrigin = parsed.origin;
    } catch {
      pageDetail = pageURL;
    }
  }
  const permissionSheetNeedsSafari =
    Boolean(snapshot?.page) && snapshot?.page?.permission !== 'granted' && snapshot?.page?.permission !== 'unsupported';
  const permissionSheetNeedsSiteTrust =
    Boolean(snapshot?.page) && snapshot?.page?.permission !== 'unsupported' && !snapshot?.trust.siteAllowed;
  const permissionSheetNeedsCloudDisclosure =
    Boolean(selectedAgent?.cloud) && !snapshot?.trust.cloudScreenshotAcknowledged;
  const showPermissionSheet =
    Boolean(snapshot?.page) &&
    snapshot?.page?.permission !== 'unsupported' &&
    (permissionSheetNeedsSafari || permissionSheetNeedsSiteTrust || permissionSheetNeedsCloudDisclosure);

  return {
    ready: state.initialized && Boolean(snapshot),
    connectionLabel:
      snapshot?.bridge.connection === 'connected'
        ? 'Connected'
        : snapshot?.bridge.connection === 'degraded'
          ? 'Limited'
          : 'Offline',
    connectionTone:
      snapshot?.bridge.connection === 'connected'
        ? 'ready'
        : snapshot?.bridge.connection === 'degraded'
          ? 'warning'
          : 'offline',
    pageLabel: snapshot?.page?.title || 'No active page',
    pageDetail,
    pageSensitive: snapshot?.page?.sensitive ?? false,
    permissionLabel:
      snapshot?.page?.permission === 'granted'
        ? 'Website access granted'
        : snapshot?.page?.permission === 'prompt'
          ? 'Website access available on request'
          : snapshot?.page?.permission === 'denied'
            ? 'Website access denied'
            : 'Unsupported page',
    modes: POPUP_MODES,
    selectedMode,
    modeDescription: mode.description,
    agentGroups: groupAgents(filtered),
    ...(selectedAgent === undefined ? {} : { selectedAgent }),
    noAgents: filtered.length === 0,
    agentFilter: state.agentFilter,
    correctionDraft: state.correctionDraft,
    correctionByteCount,
    correctionSubmitDisabled: Boolean(learningCorrectionDisabledReason),
    ...(learningCorrectionDisabledReason ? { correctionDisabledReason: learningCorrectionDisabledReason } : {}),
    ...(state.diagnosticsNotice ? { diagnosticsNotice: state.diagnosticsNotice } : {}),
    diagnosticsClearArmed: state.diagnosticsClearArmed,
    draft: state.draft,
    composerReadOnly: selectedMode === 'watch',
    composerPlaceholder:
      selectedMode === 'ask'
        ? 'What do you want to know about this page?'
        : selectedMode === 'watch'
          ? 'Watch mode mirrors the active run and keeps this chat dock in view.'
          : selectedMode === 'handoff'
            ? 'What should the agent investigate from this page?'
            : 'What should OpenBurnBar do on this page?',
    primaryLabel:
      selectedMode === 'ask'
        ? 'Ask OpenBurnBar'
        : selectedMode === 'handoff'
          ? 'Prepare hand-off'
          : 'Start verified run',
    primaryDisabled:
      Boolean(disabledReason) || state.submitting || Boolean(snapshot?.busy) || state.draft.trim().length === 0,
    ...(disabledReason ? { primaryDisabledReason: disabledReason } : {}),
    showCloudDisclosure: selectedAgent?.cloud ?? false,
    showPermissionSheet,
    permissionSheetHost: pageOrigin || pageDetail,
    permissionSheetNeedsSafari,
    permissionSheetNeedsSiteTrust,
    permissionSheetNeedsCloudDisclosure,
    stopEnabled: Boolean(snapshot?.running || snapshot?.busy),
    ...(snapshot ? { snapshot } : {})
  };
}
