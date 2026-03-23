import * as vscode from "vscode";

import {
  BURNBAR_WORKSPACE_RPC_COMMAND,
  BurnBarWorkspaceRpcError,
  type BurnBarApplyPatchRequest,
  type BurnBarApplyPatchResult,
  type BurnBarReadFileRequest,
  type BurnBarReadFileResult,
  type BurnBarRunTerminalRequest,
  type BurnBarRunTerminalResult,
  type BurnBarSearchWorkspaceRequest,
  type BurnBarSearchWorkspaceResult,
  type BurnBarWorkspaceCapabilities,
  type BurnBarWorkspaceRpcRequest,
  type BurnBarWorkspaceRpcResponse,
  type BurnBarWorkspaceRpcResult
} from "./types";

export interface BurnBarWorkspaceRpcClientLike {
  capabilities(): Promise<BurnBarWorkspaceCapabilities>;
  readFile?(params: BurnBarReadFileRequest): Promise<BurnBarReadFileResult>;
  searchWorkspace?(params: BurnBarSearchWorkspaceRequest): Promise<BurnBarSearchWorkspaceResult>;
  applyPatch?(params: BurnBarApplyPatchRequest): Promise<BurnBarApplyPatchResult>;
  runTerminal?(params: BurnBarRunTerminalRequest): Promise<BurnBarRunTerminalResult>;
}

export interface BurnBarWorkspaceCommandExecutor {
  executeCommand<Result>(command: string, ...rest: unknown[]): Thenable<Result>;
}

export class BurnBarWorkspaceRpcClient implements BurnBarWorkspaceRpcClientLike {
  constructor(private readonly commandExecutor: BurnBarWorkspaceCommandExecutor = vscode.commands) {}

  capabilities(): Promise<BurnBarWorkspaceCapabilities> {
    return this.invoke<BurnBarWorkspaceCapabilities>({ method: "workspace.capabilities" });
  }

  readFile(params: BurnBarReadFileRequest): Promise<BurnBarReadFileResult> {
    return this.invoke<BurnBarReadFileResult>({ method: "workspace.read_file", params });
  }

  searchWorkspace(params: BurnBarSearchWorkspaceRequest): Promise<BurnBarSearchWorkspaceResult> {
    return this.invoke<BurnBarSearchWorkspaceResult>({ method: "workspace.search_workspace", params });
  }

  applyPatch(params: BurnBarApplyPatchRequest): Promise<BurnBarApplyPatchResult> {
    return this.invoke<BurnBarApplyPatchResult>({ method: "workspace.apply_patch", params });
  }

  runTerminal(params: BurnBarRunTerminalRequest): Promise<BurnBarRunTerminalResult> {
    return this.invoke<BurnBarRunTerminalResult>({ method: "workspace.run_terminal", params });
  }

  private async invoke<Result extends BurnBarWorkspaceRpcResult>(request: BurnBarWorkspaceRpcRequest): Promise<Result> {
    const response = await this.commandExecutor.executeCommand<BurnBarWorkspaceRpcResponse<Result>>(
      BURNBAR_WORKSPACE_RPC_COMMAND,
      request
    );

    if (!response) {
      throw new BurnBarWorkspaceRpcError("NO_RESPONSE", "BurnBar workspace companion did not return a response.");
    }

    if (!response.ok) {
      throw new BurnBarWorkspaceRpcError(response.error.code, response.error.message);
    }

    return response.result;
  }
}
