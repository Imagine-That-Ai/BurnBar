import { TextDecoder } from "node:util";

import * as vscode from "vscode";

import {
  createBurnBarWorkspaceApi,
  resolveWorkspaceUri,
  type BurnBarWorkspaceApi,
  type BurnBarWorkspaceTextDocument
} from "./api";
import { detectWorkspaceCapabilities } from "./capabilities";
import {
  BURNBAR_WORKSPACE_RPC_COMMAND,
  BurnBarWorkspaceRpcError,
  type BurnBarApplyPatchChange,
  type BurnBarApplyPatchRequest,
  type BurnBarApplyPatchResult,
  type BurnBarReadFileRequest,
  type BurnBarReadFileResult,
  type BurnBarRunTerminalRequest,
  type BurnBarRunTerminalResult,
  type BurnBarSearchWorkspaceMatch,
  type BurnBarSearchWorkspaceRequest,
  type BurnBarSearchWorkspaceResult,
  type BurnBarWorkspaceCapabilities,
  type BurnBarWorkspaceHostKind,
  type BurnBarWorkspaceRpcRequest,
  type BurnBarWorkspaceRpcResponse,
  type BurnBarWorkspaceRpcResult
} from "./types";

const DEFAULT_SEARCH_INCLUDE = "**/*";
const DEFAULT_SEARCH_MAX_FILES = 100;
const DEFAULT_SEARCH_MAX_RESULTS = 50;
const DEFAULT_SEARCH_MAX_FILE_BYTES = 256_000;
const decoder = new TextDecoder("utf-8");

export class BurnBarWorkspaceCompanion implements vscode.Disposable {
  private readonly registration: vscode.Disposable;

  constructor(private readonly api: BurnBarWorkspaceApi) {
    this.registration = vscode.commands.registerCommand(BURNBAR_WORKSPACE_RPC_COMMAND, (request: BurnBarWorkspaceRpcRequest) =>
      this.handle(request)
    );
  }

  async handle(request: BurnBarWorkspaceRpcRequest): Promise<BurnBarWorkspaceRpcResponse> {
    try {
      const result = await this.execute(request);
      return {
        ok: true,
        result
      };
    } catch (error) {
      const rpcError =
        error instanceof BurnBarWorkspaceRpcError
          ? error
          : new BurnBarWorkspaceRpcError("UNKNOWN", error instanceof Error ? error.message : "Unknown workspace RPC error.");

      return {
        ok: false,
        error: {
          code: rpcError.code,
          message: rpcError.message
        }
      };
    }
  }

  dispose(): void {
    this.registration.dispose();
  }

  private execute(request: BurnBarWorkspaceRpcRequest): Promise<BurnBarWorkspaceRpcResult> {
    switch (request.method) {
      case "workspace.capabilities":
        return Promise.resolve(this.capabilities());
      case "workspace.read_file":
        return this.readFile(request.params);
      case "workspace.search_workspace":
        return this.searchWorkspace(request.params);
      case "workspace.apply_patch":
        return this.applyPatch(request.params);
      case "workspace.run_terminal":
        return this.runTerminal(request.params);
    }
  }

  private capabilities(): BurnBarWorkspaceCapabilities {
    return detectWorkspaceCapabilities(this.api);
  }

  private async readFile(request: BurnBarReadFileRequest): Promise<BurnBarReadFileResult> {
    smokeDebug(`read_file:start path=${request.path}`);
    const uri = resolveWorkspaceUri(this.api, request.path);
    const document = await this.api.openTextDocument(uri);
    const content = document.getText();
    smokeDebug(`read_file:end path=${request.path} bytes=${content.length}`);
    return {
      path: uri.toString(),
      content
    };
  }

  private async searchWorkspace(request: BurnBarSearchWorkspaceRequest): Promise<BurnBarSearchWorkspaceResult> {
    const capabilities = this.capabilities();
    if (!capabilities.hasWorkspace) {
      throw new BurnBarWorkspaceRpcError(
        "NO_WORKSPACE",
        "Open a workspace folder before using BurnBar workspace search."
      );
    }

    const include = request.include ?? DEFAULT_SEARCH_INCLUDE;
    const maxFiles = request.maxFiles ?? DEFAULT_SEARCH_MAX_FILES;
    const maxResults = request.maxResults ?? DEFAULT_SEARCH_MAX_RESULTS;
    const maxFileBytes = request.maxFileBytes ?? DEFAULT_SEARCH_MAX_FILE_BYTES;
    const files = await this.api.findFiles(include, request.exclude, maxFiles);
    const matches: BurnBarSearchWorkspaceMatch[] = [];
    const needle = request.caseSensitive ? request.query : request.query.toLowerCase();

    for (const uri of files) {
      if (matches.length >= maxResults) {
        break;
      }

      const bytes = await this.api.readFile(uri);
      if (bytes.byteLength > maxFileBytes) {
        continue;
      }

      const content = decoder.decode(bytes);
      const lines = content.split(/\r?\n/u);

      for (let lineIndex = 0; lineIndex < lines.length; lineIndex += 1) {
        const line = lines[lineIndex] ?? "";
        const haystack = request.caseSensitive ? line : line.toLowerCase();
        const character = haystack.indexOf(needle);
        if (character === -1) {
          continue;
        }

        matches.push({
          path: uri.toString(),
          line: lineIndex,
          character,
          preview: line.trim()
        });

        if (matches.length >= maxResults) {
          break;
        }
      }
    }

    return {
      matches
    };
  }

  private async applyPatch(request: BurnBarApplyPatchRequest): Promise<BurnBarApplyPatchResult> {
    smokeDebug(`apply_patch:start changes=${request.changes.length}`);
    const capabilities = this.capabilities();
    assertTrustedToolAllowed(capabilities, "apply_patch");

    if (capabilities.readonlyWorkspace) {
      throw new BurnBarWorkspaceRpcError(
        "READONLY_WORKSPACE",
        "BurnBar cannot apply patches because the workspace filesystem is read-only."
      );
    }

    const edit = this.api.createWorkspaceEdit();
    const changedFiles = new Set<string>();
    const openedDocuments = new Map<string, BurnBarWorkspaceTextDocument>();

    for (const change of request.changes) {
      const uri = resolveWorkspaceUri(this.api, change.path);
      const document = await this.api.openTextDocument(uri);
      openedDocuments.set(uri.toString(), document);
      const range = await this.rangeForChange(uri, change, document);
      edit.replace(uri, range, change.text);
      changedFiles.add(uri.toString());
    }

    const applied = await this.api.applyEdit(edit);
    if (!applied) {
      throw new BurnBarWorkspaceRpcError("APPLY_EDIT_FAILED", "VS Code rejected the BurnBar workspace edit.");
    }

    for (const changedFile of changedFiles) {
      const document = openedDocuments.get(changedFile);
      if (!document) {
        continue;
      }
      const saved = await document.save?.();
      if (saved === false) {
        throw new BurnBarWorkspaceRpcError(
          "SAVE_FAILED",
          `BurnBar applied the workspace edit, but VS Code did not persist ${changedFile}.`
        );
      }
    }

    smokeDebug(`apply_patch:end changedFiles=${changedFiles.size}`);
    return {
      applied,
      changedFiles: [...changedFiles]
    };
  }

  private async runTerminal(request: BurnBarRunTerminalRequest): Promise<BurnBarRunTerminalResult> {
    const capabilities = this.capabilities();
    assertTrustedToolAllowed(capabilities, "run_terminal");

    if (!capabilities.hasWorkspace) {
      throw new BurnBarWorkspaceRpcError(
        "NO_WORKSPACE",
        "Open a workspace folder before running BurnBar terminal commands."
      );
    }

    if (capabilities.virtualWorkspace) {
      throw new BurnBarWorkspaceRpcError(
        "VIRTUAL_WORKSPACE",
        "BurnBar cannot run terminal commands from a virtual workspace."
      );
    }

    const cwd = request.cwd ? this.cwdFor(request.cwd) : this.defaultWorkspaceCwd();
    const terminal = this.api.createTerminal({
      name: request.name ?? "BurnBar",
      cwd
    });

    terminal.show(request.preserveFocus ?? true);
    terminal.sendText(request.command, true);

    return {
      terminalName: terminal.name,
      cwd
    };
  }

  private async rangeForChange(
    uri: ReturnType<typeof resolveWorkspaceUri>,
    change: BurnBarApplyPatchChange,
    document?: BurnBarWorkspaceTextDocument
  ) {
    if (change.range) {
      return this.api.createRange(
        change.range.start.line,
        change.range.start.character,
        change.range.end.line,
        change.range.end.character
      );
    }

    const textDocument = document ?? (await this.api.openTextDocument(uri));
    const fullText = textDocument.getText();
    const end = textDocument.positionAt(fullText.length);
    return this.api.createRange(0, 0, end.line, end.character);
  }

  private defaultWorkspaceCwd(): string {
    const workspaceUri = this.api.workspaceFolders?.[0]?.uri;
    if (!workspaceUri) {
      throw new BurnBarWorkspaceRpcError("NO_WORKSPACE", "Open a workspace folder before running BurnBar terminal commands.");
    }

    if (workspaceUri.scheme !== "file") {
      throw new BurnBarWorkspaceRpcError(
        "VIRTUAL_WORKSPACE",
        "BurnBar cannot map this workspace to a terminal working directory."
      );
    }

    return workspaceUri.fsPath;
  }

  private cwdFor(target: string): string {
    const uri = resolveWorkspaceUri(this.api, target);
    if (uri.scheme !== "file") {
      throw new BurnBarWorkspaceRpcError(
        "VIRTUAL_WORKSPACE",
        "BurnBar can only launch terminals from file-backed workspace paths."
      );
    }

    return uri.fsPath;
  }
}

export function activateBurnBarWorkspaceCompanion(
  hostKind: BurnBarWorkspaceHostKind
): BurnBarWorkspaceCompanion {
  return new BurnBarWorkspaceCompanion(createBurnBarWorkspaceApi(hostKind));
}

function assertTrustedToolAllowed(
  capabilities: BurnBarWorkspaceCapabilities,
  tool: "apply_patch" | "run_terminal"
): void {
  if (!capabilities.untrustedWorkspace) {
    return;
  }

  throw new BurnBarWorkspaceRpcError(
    "TRUST_REQUIRED",
    `BurnBar cannot ${tool === "apply_patch" ? "apply patches" : "run terminal commands"} while the workspace is in restricted mode. Trust the workspace to enable this tool.`
  );
}

function smokeDebug(message: string): void {
  if (process.env.BURNBAR_CURSOR_SMOKE_OUTPUT) {
    console.info(`[BurnBar smoke] ${message}`);
  }
}
