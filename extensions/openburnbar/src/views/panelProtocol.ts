import type { OpenBurnBarPanelViewModel } from '../state/panelViewModel';

type HostMessageEnvelope = { hostNonce?: string };

// Host → Webview messages
export type OpenBurnBarPanelHostMessage =
  | ({ type: 'snapshot'; viewModel: OpenBurnBarPanelViewModel } & HostMessageEnvelope)
  | ({ type: 'error'; message: string } & HostMessageEnvelope)
  | ({ type: 'theme'; kind: 'dark' | 'light' | 'high-contrast' } & HostMessageEnvelope);

// Webview → Host messages (sidebar panel)
export type OpenBurnBarPanelWebviewMessage =
  | { type: 'startRun'; prompt: string; modelID: string; mode: 'explain' | 'fix' | 'inspect' }
  | { type: 'refresh' }
  | { type: 'repair' }
  | { type: 'selectRun'; runId: string }
  | { type: 'cancelRun'; runId: string }
  | { type: 'retryRun'; runId: string }
  | { type: 'approveRun'; runId: string }
  | { type: 'rejectRun'; runId: string }
  | { type: 'openApp' }
  | { type: 'openWorkspace' };

// Webview → Host messages (workspace editor pane)
export type OpenBurnBarWorkspaceWebviewMessage =
  | { type: 'startRun'; prompt: string; modelID: string; mode: 'explain' | 'fix' | 'inspect' }
  | { type: 'refresh' }
  | { type: 'repair' }
  | { type: 'selectRun'; runId: string }
  | { type: 'cancelRun'; runId: string }
  | { type: 'retryRun'; runId: string }
  | { type: 'approveRun'; runId: string }
  | { type: 'rejectRun'; runId: string }
  | { type: 'openApp' }
  | { type: 'switchSection'; section: 'command' | 'runs' | 'system' }
  | { type: 'openConversationSearch' };
