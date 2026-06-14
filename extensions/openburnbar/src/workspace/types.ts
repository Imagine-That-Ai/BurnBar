export const BURNBAR_WORKSPACE_RPC_COMMAND = 'openburnbar.private.workspace.rpc';

export type BurnBarWorkspaceHostKind = 'ui' | 'workspace';
export type BurnBarWorkspaceToolName = 'read_file' | 'search_workspace' | 'apply_patch' | 'run_terminal';
export interface BurnBarWorkspaceCapabilities {
  hasWorkspace: boolean;
  localWorkspace: boolean;
  remoteWorkspace: boolean;
  readonlyWorkspace: boolean;
  virtualWorkspace: boolean;
  untrustedWorkspace: boolean;
  workspaceHost: BurnBarWorkspaceHostKind;
  availableTools: BurnBarWorkspaceToolName[];
  gatedTools: BurnBarWorkspaceToolName[];
  explanation: string;
}

export interface BurnBarReadFileRequest {
  path: string;
}

export interface BurnBarReadFileResult {
  path: string;
  content: string;
}

export interface BurnBarSearchWorkspaceRequest {
  query: string;
  include?: string;
  exclude?: string;
  maxResults?: number;
  maxFiles?: number;
  maxFileBytes?: number;
  caseSensitive?: boolean;
}

export interface BurnBarSearchWorkspaceMatch {
  path: string;
  line: number;
  character: number;
  preview: string;
}

export interface BurnBarSearchWorkspaceResult {
  matches: BurnBarSearchWorkspaceMatch[];
}

/** OpenBurnBar local index (SQLite FTS + transcript counts) via daemon — not workspace file grep. */
export interface BurnBarSearchBurnbarIndexRequest {
  query: string;
  providerRaw?: string;
  projectName?: string;
  dateRangeStartEpoch?: number;
  dateRangeEndEpoch?: number;
  resultLimit?: number;
}

export interface BurnBarIndexedSearchHit {
  chunkID: string;
  sourceKind: string;
  sourceID: string;
  title: string;
  snippet: string;
  provider?: string | null;
  projectName?: string | null;
}

export interface BurnBarSearchBurnbarIndexResult {
  plan: {
    mode: string;
    lexicalFTSQuery: string;
    semanticText: string;
    aggregatePatterns: string[];
    note?: string | null;
  };
  aggregateOccurrenceCount?: number | null;
  hits: BurnBarIndexedSearchHit[];
  degradedMessage?: string | null;
}

interface BurnBarPatchPosition {
  line: number;
  character: number;
}

interface BurnBarPatchRange {
  start: BurnBarPatchPosition;
  end: BurnBarPatchPosition;
}

export interface OpenBurnBarApplyPatchChange {
  path: string;
  range?: BurnBarPatchRange;
  text: string;
}

export interface OpenBurnBarApplyPatchRequest {
  changes: OpenBurnBarApplyPatchChange[];
}

export interface OpenBurnBarApplyPatchResult {
  applied: boolean;
  changedFiles: string[];
}

export interface BurnBarRunTerminalRequest {
  command: string;
  cwd?: string;
  name?: string;
  preserveFocus?: boolean;
}

export interface BurnBarRunTerminalResult {
  terminalName: string;
  cwd?: string;
}

export type BurnBarWorkspaceRpcRequest =
  | { method: 'workspace.capabilities' }
  | { method: 'workspace.read_file'; params: BurnBarReadFileRequest }
  | { method: 'workspace.search_workspace'; params: BurnBarSearchWorkspaceRequest }
  | { method: 'workspace.search_burnbar_index'; params: BurnBarSearchBurnbarIndexRequest }
  | { method: 'workspace.apply_patch'; params: OpenBurnBarApplyPatchRequest }
  | { method: 'workspace.run_terminal'; params: BurnBarRunTerminalRequest };

export type BurnBarWorkspaceRpcResult =
  | BurnBarWorkspaceCapabilities
  | BurnBarReadFileResult
  | BurnBarSearchWorkspaceResult
  | BurnBarSearchBurnbarIndexResult
  | OpenBurnBarApplyPatchResult
  | BurnBarRunTerminalResult;

interface BurnBarWorkspaceRpcFailure {
  ok: false;
  error: {
    code: string;
    message: string;
  };
}

interface BurnBarWorkspaceRpcSuccess<Result extends BurnBarWorkspaceRpcResult> {
  ok: true;
  result: Result;
}

export type BurnBarWorkspaceRpcResponse<Result extends BurnBarWorkspaceRpcResult = BurnBarWorkspaceRpcResult> =
  | BurnBarWorkspaceRpcSuccess<Result>
  | BurnBarWorkspaceRpcFailure;

export class OpenBurnBarWorkspaceRpcError extends Error {
  constructor(
    readonly code: string,
    message: string
  ) {
    super(message);
    this.name = 'OpenBurnBarWorkspaceRpcError';
  }
}
