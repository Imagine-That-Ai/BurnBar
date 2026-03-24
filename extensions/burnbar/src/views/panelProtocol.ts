import type { BurnBarPanelViewModel } from "../state/panelViewModel";

// Host → Webview messages
export type BurnBarPanelHostMessage =
  | { type: "snapshot"; viewModel: BurnBarPanelViewModel }
  | { type: "error"; message: string }
  | { type: "theme"; kind: "dark" | "light" | "high-contrast" };

// Webview → Host messages (sidebar panel)
export type BurnBarPanelWebviewMessage =
  | { type: "startRun"; prompt: string; modelID: string; mode: "explain" | "fix" | "inspect" }
  | { type: "refresh" }
  | { type: "repair" }
  | { type: "selectRun"; runId: string }
  | { type: "cancelRun"; runId: string }
  | { type: "retryRun"; runId: string }
  | { type: "approveRun"; runId: string }
  | { type: "rejectRun"; runId: string }
  | { type: "openApp" }
  | { type: "openWorkspace" };

// Webview → Host messages (workspace editor pane)
export type BurnBarWorkspaceWebviewMessage =
  | { type: "startRun"; prompt: string; modelID: string; mode: "explain" | "fix" | "inspect" }
  | { type: "refresh" }
  | { type: "repair" }
  | { type: "selectRun"; runId: string }
  | { type: "cancelRun"; runId: string }
  | { type: "retryRun"; runId: string }
  | { type: "approveRun"; runId: string }
  | { type: "rejectRun"; runId: string }
  | { type: "openApp" }
  | { type: "switchSection"; section: "command" | "runs" | "system" }
  | { type: "openConversationSearch" };
