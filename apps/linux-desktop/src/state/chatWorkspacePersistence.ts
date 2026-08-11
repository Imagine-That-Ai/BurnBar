import type { ChatBackendId } from '../surfaces/chat/chatTypes.js';
import type { ChatThinkingSelection } from '../surfaces/chat/chatOptions.js';
import { validStoredThreadID } from './chatStore.js';

export const CHAT_WORKSPACE_STORAGE_KEY = 'openburnbar.chat.workspace.v2';
export const CHAT_WORKSPACE_VERSION = 2;
export const CHAT_WORKSPACE_MIN_FRACTION = 0.15;
export const CHAT_WORKSPACE_MAX_FRACTION = 0.85;
export const CHAT_WORKSPACE_MAX_TABS = 20;
export const CHAT_WORKSPACE_MAX_PANES = 32;
export const CHAT_WORKSPACE_MAX_DEPTH = 8;
export const CHAT_WORKSPACE_CLOSED_TAB_LIMIT = 5;

export type ChatWorkspaceSplitAxis = 'horizontal' | 'vertical';
export type ChatWorkspaceColorToken = 'whimsy' | 'aureate' | 'ember' | 'amber' | 'success' | 'frost';

export type PersistedChatPane = {
  kind: 'leaf';
  id: string;
  threadID: string | null;
  isPrimary: boolean;
  title: string | null;
  colorToken: ChatWorkspaceColorToken | null;
  backend: ChatBackendId;
  modelLabel: string;
  modelOptionID: string;
  thinkingLevel: ChatThinkingSelection;
  unseenCompletionAt: string | null;
  alertsEnabled: boolean;
};

export type PersistedChatSplit = {
  kind: 'split';
  id: string;
  axis: ChatWorkspaceSplitAxis;
  fraction: number;
  first: PersistedChatNode;
  second: PersistedChatNode;
};

export type PersistedChatNode = PersistedChatPane | PersistedChatSplit;

export type PersistedChatTab = {
  id: string;
  title: string | null;
  colorToken: ChatWorkspaceColorToken | null;
  root: PersistedChatNode;
  activePaneID: string;
  zoomedPaneID: string | null;
};

export type ChatWorkspaceSnapshotV2 = {
  version: typeof CHAT_WORKSPACE_VERSION;
  tabs: PersistedChatTab[];
  selectedTabID: string;
  closedTabs: PersistedChatTab[];
};

export type ChatWorkspacePaneControls = Pick<
  PersistedChatPane,
  'backend' | 'modelLabel' | 'modelOptionID' | 'thinkingLevel'
>;

type DecodeContext = {
  idFactory: () => string;
  usedNodeIDs: Set<string>;
  paneCount: number;
};

const BACKENDS: ReadonlySet<ChatBackendId> = new Set([
  'hermes',
  'openclaw',
  'codex',
  'claude',
  'pi-agent',
  'openclaude',
  'omp',
  'droid',
  'forge',
  'antigravity',
  'cursor-agent',
  'junie',
  'cli'
]);
const THINKING_LEVELS: ReadonlySet<ChatThinkingSelection> = new Set([
  'default',
  'low',
  'medium',
  'high',
  'xhigh',
  'max'
]);
const COLOR_TOKENS: ReadonlySet<ChatWorkspaceColorToken> = new Set([
  'whimsy',
  'aureate',
  'ember',
  'amber',
  'success',
  'frost'
]);

let fallbackIDSequence = 0;

export function newChatWorkspaceID(): string {
  if (typeof globalThis.crypto?.randomUUID === 'function') {
    return globalThis.crypto.randomUUID();
  }
  fallbackIDSequence = (fallbackIDSequence + 1) % Number.MAX_SAFE_INTEGER;
  return `workspace-${Date.now().toString(36)}-${fallbackIDSequence.toString(36)}`;
}

export function clampChatWorkspaceFraction(value: number): number {
  if (!Number.isFinite(value)) return 0.5;
  return Math.min(CHAT_WORKSPACE_MAX_FRACTION, Math.max(CHAT_WORKSPACE_MIN_FRACTION, value));
}

export function createDefaultChatWorkspaceSnapshot(
  primaryThreadID: string | null,
  idFactory: () => string = newChatWorkspaceID,
  controls?: ChatWorkspacePaneControls
): ChatWorkspaceSnapshotV2 {
  const paneID = idFactory();
  const tabID = idFactory();
  return {
    version: CHAT_WORKSPACE_VERSION,
    tabs: [{
      id: tabID,
      title: null,
      colorToken: null,
      root: defaultPane(paneID, validStoredThreadID(primaryThreadID), true, controls),
      activePaneID: paneID,
      zoomedPaneID: null
    }],
    selectedTabID: tabID,
    closedTabs: []
  };
}

export function encodeChatWorkspaceSnapshot(snapshot: ChatWorkspaceSnapshotV2): string {
  return JSON.stringify(snapshot);
}

export function decodeChatWorkspaceSnapshot(
  raw: string | null,
  primaryThreadID: string | null,
  idFactory: () => string = newChatWorkspaceID,
  controls?: ChatWorkspacePaneControls
): ChatWorkspaceSnapshotV2 {
  if (!raw) return createDefaultChatWorkspaceSnapshot(primaryThreadID, idFactory, controls);
  let parsed: unknown;
  try {
    parsed = JSON.parse(raw);
  } catch {
    return createDefaultChatWorkspaceSnapshot(primaryThreadID, idFactory, controls);
  }
  const record = object(parsed);
  if (!record || record.version !== CHAT_WORKSPACE_VERSION || !Array.isArray(record.tabs)) {
    return createDefaultChatWorkspaceSnapshot(primaryThreadID, idFactory, controls);
  }
  if (record.tabs.length === 0 || record.tabs.length > CHAT_WORKSPACE_MAX_TABS) {
    return createDefaultChatWorkspaceSnapshot(primaryThreadID, idFactory, controls);
  }

  const context: DecodeContext = {
    idFactory,
    usedNodeIDs: new Set(),
    paneCount: 0
  };
  const usedTabIDs = new Set<string>();
  const tabs = record.tabs.flatMap((value) => {
    const tab = decodeTab(value, context, usedTabIDs, true);
    return tab ? [tab] : [];
  });
  if (tabs.length === 0 || context.paneCount > CHAT_WORKSPACE_MAX_PANES) {
    return createDefaultChatWorkspaceSnapshot(primaryThreadID, idFactory, controls);
  }

  repairPrimaryInvariant(tabs);
  const selectedTabID = safeID(record.selectedTabID, null);
  const selected = selectedTabID && tabs.some((tab) => tab.id === selectedTabID)
    ? selectedTabID
    : tabs[0]!.id;

  const closedContext: DecodeContext = {
    idFactory,
    usedNodeIDs: new Set(context.usedNodeIDs),
    paneCount: 0
  };
  const closedTabIDs = new Set(usedTabIDs);
  const closedTabs = Array.isArray(record.closedTabs)
    ? record.closedTabs.slice(-CHAT_WORKSPACE_CLOSED_TAB_LIMIT).flatMap((value) => {
        const tab = decodeTab(value, closedContext, closedTabIDs, false);
        if (!tab) return [];
        visitPanes(tab.root, (pane) => {
          pane.isPrimary = false;
          pane.unseenCompletionAt = null;
        });
        return [tab];
      })
    : [];

  return {
    version: CHAT_WORKSPACE_VERSION,
    tabs,
    selectedTabID: selected,
    closedTabs
  };
}

function decodeTab(
  value: unknown,
  context: DecodeContext,
  usedTabIDs: Set<string>,
  allowPrimary: boolean
): PersistedChatTab | null {
  const record = object(value);
  if (!record) return null;
  const root = decodeNode(record.root, context, 0, allowPrimary);
  if (!root) return null;
  const paneIDs = new Set(collectPersistedPanes(root).map((pane) => pane.id));
  const requestedID = safeID(record.id, null);
  const id = requestedID && !usedTabIDs.has(requestedID) ? requestedID : uniqueID(context.idFactory, usedTabIDs);
  usedTabIDs.add(id);
  const activeCandidate = safeID(record.activePaneID, null);
  const activePaneID = activeCandidate && paneIDs.has(activeCandidate)
    ? activeCandidate
    : firstPersistedPane(root).id;
  const zoomCandidate = safeID(record.zoomedPaneID, null);
  const zoomedPaneID = zoomCandidate && paneIDs.has(zoomCandidate) ? zoomCandidate : null;
  return {
    id,
    title: safeTitle(record.title),
    colorToken: safeColor(record.colorToken),
    root,
    activePaneID,
    zoomedPaneID
  };
}

function decodeNode(
  value: unknown,
  context: DecodeContext,
  depth: number,
  allowPrimary: boolean
): PersistedChatNode | null {
  if (depth > CHAT_WORKSPACE_MAX_DEPTH || context.paneCount >= CHAT_WORKSPACE_MAX_PANES) return null;
  const record = object(value);
  if (!record) return null;
  if (record.kind === 'leaf') {
    context.paneCount += 1;
    const requestedID = safeID(record.id, null);
    const id = requestedID && !context.usedNodeIDs.has(requestedID)
      ? requestedID
      : uniqueID(context.idFactory, context.usedNodeIDs);
    context.usedNodeIDs.add(id);
    return {
      kind: 'leaf',
      id,
      threadID: safeThreadID(record.threadID),
      isPrimary: allowPrimary && record.isPrimary === true,
      title: safeTitle(record.title),
      colorToken: safeColor(record.colorToken),
      backend: safeBackend(record.backend),
      modelLabel: safeBoundedString(record.modelLabel, 200) ?? 'hermes',
      modelOptionID: safeBoundedString(record.modelOptionID, 200) ?? 'hermes',
      thinkingLevel: safeThinkingLevel(record.thinkingLevel),
      unseenCompletionAt: safeTimestamp(record.unseenCompletionAt),
      alertsEnabled: record.alertsEnabled !== false
    };
  }
  if (record.kind !== 'split') return null;
  const first = decodeNode(record.first, context, depth + 1, allowPrimary);
  const second = decodeNode(record.second, context, depth + 1, allowPrimary);
  if (!first || !second) return null;
  const requestedID = safeID(record.id, null);
  const id = requestedID && !context.usedNodeIDs.has(requestedID)
    ? requestedID
    : uniqueID(context.idFactory, context.usedNodeIDs);
  context.usedNodeIDs.add(id);
  return {
    kind: 'split',
    id,
    axis: record.axis === 'vertical' ? 'vertical' : 'horizontal',
    fraction: clampChatWorkspaceFraction(typeof record.fraction === 'number' ? record.fraction : 0.5),
    first,
    second
  };
}

function repairPrimaryInvariant(tabs: PersistedChatTab[]): void {
  let foundPrimary = false;
  for (const tab of tabs) {
    visitPanes(tab.root, (pane) => {
      if (!pane.isPrimary) return;
      if (foundPrimary) {
        pane.isPrimary = false;
      } else {
        foundPrimary = true;
      }
    });
  }
  if (!foundPrimary) firstPersistedPane(tabs[0]!.root).isPrimary = true;
}

export function collectPersistedPanes(node: PersistedChatNode): PersistedChatPane[] {
  if (node.kind === 'leaf') return [node];
  return [...collectPersistedPanes(node.first), ...collectPersistedPanes(node.second)];
}

export function firstPersistedPane(node: PersistedChatNode): PersistedChatPane {
  return node.kind === 'leaf' ? node : firstPersistedPane(node.first);
}

function visitPanes(node: PersistedChatNode, visit: (pane: PersistedChatPane) => void): void {
  if (node.kind === 'leaf') {
    visit(node);
    return;
  }
  visitPanes(node.first, visit);
  visitPanes(node.second, visit);
}

function defaultPane(
  id: string,
  threadID: string | null,
  isPrimary: boolean,
  controls?: ChatWorkspacePaneControls
): PersistedChatPane {
  return {
    kind: 'leaf',
    id,
    threadID,
    isPrimary,
    title: null,
    colorToken: null,
    backend: controls?.backend ?? 'hermes',
    modelLabel: controls?.modelLabel ?? 'hermes',
    modelOptionID: controls?.modelOptionID ?? 'hermes',
    thinkingLevel: controls?.thinkingLevel ?? 'default',
    unseenCompletionAt: null,
    alertsEnabled: true
  };
}

function object(value: unknown): Record<string, unknown> | null {
  return value !== null && typeof value === 'object' && !Array.isArray(value)
    ? value as Record<string, unknown>
    : null;
}

function safeID(value: unknown, fallback: string | null): string | null {
  return safeBoundedString(value, 128) ?? fallback;
}

function safeThreadID(value: unknown): string | null {
  return typeof value === 'string' ? validStoredThreadID(value) : null;
}

function safeTitle(value: unknown): string | null {
  const title = safeBoundedString(value, 80)?.trim();
  return title || null;
}

function safeColor(value: unknown): ChatWorkspaceColorToken | null {
  return typeof value === 'string' && COLOR_TOKENS.has(value as ChatWorkspaceColorToken)
    ? value as ChatWorkspaceColorToken
    : null;
}

function safeBackend(value: unknown): ChatBackendId {
  return typeof value === 'string' && BACKENDS.has(value as ChatBackendId)
    ? value as ChatBackendId
    : 'hermes';
}

function safeThinkingLevel(value: unknown): ChatThinkingSelection {
  return typeof value === 'string' && THINKING_LEVELS.has(value as ChatThinkingSelection)
    ? value as ChatThinkingSelection
    : 'default';
}

function safeTimestamp(value: unknown): string | null {
  if (typeof value !== 'string' || value.length > 40) return null;
  const timestamp = Date.parse(value);
  return Number.isFinite(timestamp) ? new Date(timestamp).toISOString() : null;
}

function safeBoundedString(value: unknown, maxLength: number): string | null {
  if (typeof value !== 'string' || value.length === 0 || value.length > maxLength) return null;
  if ([...value].some((character) => character.charCodeAt(0) < 0x20 || character.charCodeAt(0) === 0x7f)) {
    return null;
  }
  return value;
}

function uniqueID(idFactory: () => string, used: Set<string>): string {
  for (let attempt = 0; attempt < 32; attempt += 1) {
    const candidate = safeID(idFactory(), null);
    if (candidate && !used.has(candidate)) return candidate;
  }
  let suffix = used.size + 1;
  while (used.has(`workspace-repaired-${suffix}`)) suffix += 1;
  return `workspace-repaired-${suffix}`;
}
