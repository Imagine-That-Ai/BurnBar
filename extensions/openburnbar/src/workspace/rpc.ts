import * as vscode from 'vscode';

import {
  BURNBAR_WORKSPACE_RPC_COMMAND,
  OpenBurnBarWorkspaceRpcError,
  type OpenBurnBarApplyPatchRequest,
  type OpenBurnBarApplyPatchResult,
  type BurnBarReadFileRequest,
  type BurnBarReadFileResult,
  type BurnBarRunTerminalRequest,
  type BurnBarRunTerminalResult,
  type BurnBarSearchBurnbarIndexRequest,
  type BurnBarSearchBurnbarIndexResult,
  type BurnBarSearchWorkspaceRequest,
  type BurnBarSearchWorkspaceResult,
  type BurnBarWorkspaceCapabilities,
  type BurnBarWorkspaceRpcRequest,
  type BurnBarWorkspaceRpcResponse,
  type BurnBarWorkspaceRpcResult
} from './types';

export interface OpenBurnBarWorkspaceRpcClientLike {
  capabilities(): Promise<BurnBarWorkspaceCapabilities>;
  readFile?(params: BurnBarReadFileRequest): Promise<BurnBarReadFileResult>;
  searchWorkspace?(params: BurnBarSearchWorkspaceRequest): Promise<BurnBarSearchWorkspaceResult>;
  searchBurnbarIndex?(params: BurnBarSearchBurnbarIndexRequest): Promise<BurnBarSearchBurnbarIndexResult>;
  applyPatch?(params: OpenBurnBarApplyPatchRequest): Promise<OpenBurnBarApplyPatchResult>;
  runTerminal?(params: BurnBarRunTerminalRequest): Promise<BurnBarRunTerminalResult>;
}

export interface BurnBarWorkspaceCommandExecutor {
  executeCommand<Result>(command: string, ...rest: unknown[]): Thenable<Result>;
}

export class OpenBurnBarWorkspaceRpcClient implements OpenBurnBarWorkspaceRpcClientLike {
  constructor(private readonly commandExecutor: BurnBarWorkspaceCommandExecutor = vscode.commands) {}

  capabilities(): Promise<BurnBarWorkspaceCapabilities> {
    return this.invoke<BurnBarWorkspaceCapabilities>({ method: 'workspace.capabilities' });
  }

  readFile(params: BurnBarReadFileRequest): Promise<BurnBarReadFileResult> {
    return this.invoke<BurnBarReadFileResult>({ method: 'workspace.read_file', params });
  }

  searchWorkspace(params: BurnBarSearchWorkspaceRequest): Promise<BurnBarSearchWorkspaceResult> {
    return this.invoke<BurnBarSearchWorkspaceResult>({ method: 'workspace.search_workspace', params });
  }

  searchBurnbarIndex(params: BurnBarSearchBurnbarIndexRequest): Promise<BurnBarSearchBurnbarIndexResult> {
    return this.invoke<BurnBarSearchBurnbarIndexResult>({ method: 'workspace.search_burnbar_index', params });
  }

  applyPatch(params: OpenBurnBarApplyPatchRequest): Promise<OpenBurnBarApplyPatchResult> {
    return this.invoke<OpenBurnBarApplyPatchResult>({ method: 'workspace.apply_patch', params });
  }

  runTerminal(params: BurnBarRunTerminalRequest): Promise<BurnBarRunTerminalResult> {
    return this.invoke<BurnBarRunTerminalResult>({ method: 'workspace.run_terminal', params });
  }

  private async invoke<Result extends BurnBarWorkspaceRpcResult>(request: BurnBarWorkspaceRpcRequest): Promise<Result> {
    const response = await this.commandExecutor.executeCommand<BurnBarWorkspaceRpcResponse<Result>>(
      BURNBAR_WORKSPACE_RPC_COMMAND,
      request
    );

    if (!response) {
      throw new OpenBurnBarWorkspaceRpcError(
        'NO_RESPONSE',
        'OpenBurnBar workspace companion did not return a response.'
      );
    }

    if (!response.ok) {
      throw new OpenBurnBarWorkspaceRpcError(response.error.code, response.error.message);
    }

    return response.result;
  }
}
