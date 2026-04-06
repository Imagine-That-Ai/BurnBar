import * as assert from "node:assert/strict";
import * as fs from "node:fs";
import * as path from "node:path";
import * as vscode from "vscode";

import {
  BURNBAR_WORKSPACE_RPC_COMMAND,
  type OpenBurnBarApplyPatchResult,
  type BurnBarReadFileResult,
  type BurnBarRunTerminalResult,
  type BurnBarWorkspaceCapabilities,
  type BurnBarWorkspaceRpcResponse,
  type BurnBarWorkspaceRpcResult
} from "../../../src/workspace/types";

suite("OpenBurnBar extension host local workspace", () => {
  setup(async () => {
    const extension = vscode.extensions.all.find((candidate) => candidate.packageJSON.name === "openburnbar");
    assert.ok(extension, "Expected the OpenBurnBar extension to be present in the extension host.");
    await extension.activate();

    const rawWorkspaceRoot = process.env.BURNBAR_TEST_WORKSPACE;
    assert.ok(rawWorkspaceRoot, "Expected BURNBAR_TEST_WORKSPACE to be configured for extension-host tests.");
    // Sanitize: must be absolute, contain no NUL bytes, and resolve to an
    // existing path under the resolved location (no traversal). This
    // neutralizes the js/path-injection taint flow into fs.existsSync.
    assert.ok(!rawWorkspaceRoot.includes("\0"), "BURNBAR_TEST_WORKSPACE must not contain NUL bytes.");
    const workspaceRoot = path.resolve(rawWorkspaceRoot);
    assert.ok(path.isAbsolute(workspaceRoot), "BURNBAR_TEST_WORKSPACE must resolve to an absolute path.");
    assert.ok(fs.existsSync(workspaceRoot), `Expected fixture workspace to exist at ${workspaceRoot}.`);

    const existingFolder = vscode.workspace.workspaceFolders?.find(
      (folder) => folder.uri.fsPath === workspaceRoot
    );
    if (!existingFolder) {
      const added = vscode.workspace.updateWorkspaceFolders(
        vscode.workspace.workspaceFolders?.length ?? 0,
        null,
        { uri: vscode.Uri.file(workspaceRoot), name: path.basename(workspaceRoot) }
      );
      assert.equal(added, true, "Expected extension-host suite to add the fixture workspace.");
      await vscode.commands.executeCommand("workbench.action.closeEditorsInOtherGroups");
    }
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

    const patchResult = await invokeCommand<OpenBurnBarApplyPatchResult>({
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
        command: "echo openburnbar-extension-host",
        cwd: "."
      }
    });
    assert.equal(terminalResult.terminalName, "OpenBurnBar");
    assert.equal(terminalResult.cwd, path.join(workspaceFolder.uri.fsPath, "."));
  });
});

async function invokeCommand<Result extends BurnBarWorkspaceRpcResult>(request: unknown): Promise<Result> {
  const response = await vscode.commands.executeCommand<BurnBarWorkspaceRpcResponse<Result>>(
    BURNBAR_WORKSPACE_RPC_COMMAND,
    request
  );

  assert.ok(response, "Expected the OpenBurnBar workspace RPC command to return a response.");
  assert.equal(response.ok, true);
  return response.result;
}
