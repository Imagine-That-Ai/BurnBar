import * as assert from "node:assert/strict";
import * as path from "node:path";
import * as vscode from "vscode";

import {
  BURNBAR_WORKSPACE_RPC_COMMAND,
  type BurnBarApplyPatchResult,
  type BurnBarReadFileResult,
  type BurnBarRunTerminalResult,
  type BurnBarWorkspaceCapabilities,
  type BurnBarWorkspaceRpcResponse,
  type BurnBarWorkspaceRpcResult
} from "../../../src/workspace/types";

suite("BurnBar extension host local workspace", () => {
  setup(async () => {
    const extension = vscode.extensions.all.find((candidate) => candidate.packageJSON.name === "burnbar");
    assert.ok(extension, "Expected the BurnBar extension to be present in the extension host.");
    await extension.activate();
  });

  test("executes workspace companion commands against a real workspace folder", async () => {
    const workspaceFolder = vscode.workspace.workspaceFolders?.[0];
    assert.ok(workspaceFolder, "Expected the extension-host suite to open a workspace folder.");

    const capabilities = await invokeCommand<BurnBarWorkspaceCapabilities>({
      method: "workspace.capabilities"
    });
    assert.equal(capabilities.localWorkspace, true);
    assert.equal(capabilities.remoteWorkspace, false);
    assert.deepEqual(capabilities.gatedTools, []);
    assert.ok(capabilities.availableTools.includes("apply_patch"));
    assert.ok(capabilities.availableTools.includes("run_terminal"));

    const readResult = await invokeCommand<BurnBarReadFileResult>({
      method: "workspace.read_file",
      params: {
        path: "src/example.ts"
      }
    });
    assert.match(readResult.content, /const value = 1;/u);

    const patchResult = await invokeCommand<BurnBarApplyPatchResult>({
      method: "workspace.apply_patch",
      params: {
        changes: [
          {
            path: "src/example.ts",
            range: {
              start: { line: 0, character: 14 },
              end: { line: 0, character: 15 }
            },
            text: "2"
          }
        ]
      }
    });
    assert.equal(patchResult.applied, true);

    const patchedReadResult = await invokeCommand<BurnBarReadFileResult>({
      method: "workspace.read_file",
      params: {
        path: "src/example.ts"
      }
    });
    assert.match(patchedReadResult.content, /const value = 2;/u);

    const terminalResult = await invokeCommand<BurnBarRunTerminalResult>({
      method: "workspace.run_terminal",
      params: {
        command: "echo burnbar-extension-host",
        cwd: "."
      }
    });
    assert.equal(terminalResult.terminalName, "BurnBar");
    assert.equal(terminalResult.cwd, path.join(workspaceFolder.uri.fsPath, "."));
  });
});

async function invokeCommand<Result extends BurnBarWorkspaceRpcResult>(request: unknown): Promise<Result> {
  const response = await vscode.commands.executeCommand<BurnBarWorkspaceRpcResponse<Result>>(
    BURNBAR_WORKSPACE_RPC_COMMAND,
    request
  );

  assert.ok(response, "Expected the BurnBar workspace RPC command to return a response.");
  assert.equal(response.ok, true);
  return response.result;
}
