import type { BurnBarPanelViewModel } from "../state/panelViewModel";

// Host → Webview messages
export type BurnBarPanelHostMessage =
  | { type: "snapshot"; viewModel: BurnBarPanelViewModel }
  | { type: "error"; message: string }
  | { type: "theme"; kind: "dark" | "light" | "high-contrast" };

// Webview → Host messages
export type BurnBarPanelWebviewMessage =
  | { type: "startRun"; prompt: string; modelID: string; mode: "explain" | "fix" | "inspect" }
  | { type: "refresh" }
  | { type: "repair" }
  | { type: "selectRun"; runId: string }
  | { type: "cancelRun"; runId: string }
  | { type: "retryRun"; runId: string }
  | { type: "approveRun"; runId: string }
  | { type: "rejectRun"; runId: string };
