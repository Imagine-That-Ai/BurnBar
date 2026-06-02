import { TextDecoder, TextEncoder } from 'node:util';

import * as vscode from 'vscode';

import {
  createBurnBarWorkspaceApi,
  resolveWorkspaceUri,
  type BurnBarWorkspaceApi,
  type BurnBarWorkspaceTextDocument
} from './api';
import { detectWorkspaceCapabilities } from './capabilities';
import {
  BURNBAR_WORKSPACE_RPC_COMMAND,
  OpenBurnBarWorkspaceRpcError,
  type OpenBurnBarApplyPatchChange,
  type OpenBurnBarApplyPatchRequest,
  type OpenBurnBarApplyPatchResult,
  type BurnBarReadFileRequest,
  type BurnBarReadFileResult,
  type BurnBarRunTerminalRequest,
  type BurnBarRunTerminalResult,
  type BurnBarSearchBurnbarIndexRequest,
  type BurnBarSearchBurnbarIndexResult,
  type BurnBarSearchWorkspaceMatch,
  type BurnBarSearchWorkspaceRequest,
  type BurnBarSearchWorkspaceResult,
  type BurnBarWorkspaceCapabilities,
  type BurnBarWorkspaceHostKind,
  type BurnBarWorkspaceRpcRequest,
  type BurnBarWorkspaceRpcResponse,
  type BurnBarWorkspaceRpcResult
} from './types';

const DEFAULT_SEARCH_INCLUDE = '**/*';
const DEFAULT_SEARCH_MAX_FILES = 100;
const DEFAULT_SEARCH_MAX_RESULTS = 50;
const DEFAULT_SEARCH_MAX_FILE_BYTES = 256_000;
const MAX_READ_FILE_BYTES = 1_000_000;
const MAX_SEARCH_FILES = 200;
const MAX_SEARCH_RESULTS = 100;
const MAX_SEARCH_FILE_BYTES = 512_000;
const MAX_SEARCH_QUERY_BYTES = 4_096;
const MAX_GLOB_BYTES = 512;
const MAX_PREVIEW_CHARACTERS = 500;
const decoder = new TextDecoder('utf-8');
const encoder = new TextEncoder();

export type BurnBarIndexedSearchBridge = (
  params: BurnBarSearchBurnbarIndexRequest
) => Promise<BurnBarSearchBurnbarIndexResult>;

export class OpenBurnBarWorkspaceCompanion implements vscode.Disposable {
  private readonly registration: vscode.Disposable;

  constructor(
    private readonly api: BurnBarWorkspaceApi,
    private readonly indexedSearch?: BurnBarIndexedSearchBridge
  ) {
    this.registration = vscode.commands.registerCommand(
      BURNBAR_WORKSPACE_RPC_COMMAND,
      (request: BurnBarWorkspaceRpcRequest) => this.handle(request)
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
        error instanceof OpenBurnBarWorkspaceRpcError
          ? error
          : new OpenBurnBarWorkspaceRpcError(
              'UNKNOWN',
              error instanceof Error ? error.message : 'Unknown workspace RPC error.'
            );

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
      case 'workspace.capabilities':
        return Promise.resolve(this.capabilities());
      case 'workspace.read_file':
        return this.readFile(request.params);
      case 'workspace.search_workspace':
        return this.searchWorkspace(request.params);
      case 'workspace.search_burnbar_index':
        return this.searchBurnbarIndex(request.params);
      case 'workspace.apply_patch':
        return this.applyPatch(request.params);
      case 'workspace.run_terminal':
        return this.runTerminal(request.params);
      default: {
        // Exhaustiveness check - this should never be reached
        const exhaustiveCheck: never = request;
        return Promise.reject(new Error(`Unknown workspace method: ${String(exhaustiveCheck)}`));
      }
    }
  }

  private capabilities(): BurnBarWorkspaceCapabilities {
    return detectWorkspaceCapabilities(this.api);
  }

  private async readFile(request: BurnBarReadFileRequest): Promise<BurnBarReadFileResult> {
    smokeDebug(`read_file:start path=${request.path}`);
    const uri = resolveWorkspaceUri(this.api, request.path);
    await this.assertFileWithinByteLimit(uri, MAX_READ_FILE_BYTES, 'READ_FILE_TOO_LARGE');
    const document = await this.api.openTextDocument(uri);
    const content = document.getText();
    const byteLength = encoder.encode(content).byteLength;
    if (byteLength > MAX_READ_FILE_BYTES) {
      throw new OpenBurnBarWorkspaceRpcError(
        'READ_FILE_TOO_LARGE',
        `OpenBurnBar read_file is limited to ${MAX_READ_FILE_BYTES} bytes.`
      );
    }
    smokeDebug(`read_file:end path=${request.path} bytes=${byteLength}`);
    return {
      path: uri.toString(),
      content
    };
  }

  private async searchWorkspace(request: BurnBarSearchWorkspaceRequest): Promise<BurnBarSearchWorkspaceResult> {
    const capabilities = this.capabilities();
    if (!capabilities.hasWorkspace) {
      throw new OpenBurnBarWorkspaceRpcError(
        'NO_WORKSPACE',
        'Open a workspace folder before using OpenBurnBar workspace search.'
      );
    }

    const query = boundedString(request.query, 'search_workspace.query', MAX_SEARCH_QUERY_BYTES).trim();
    if (!query) {
      throw new OpenBurnBarWorkspaceRpcError(
        'INVALID_SEARCH_QUERY',
        'OpenBurnBar workspace search requires a non-empty query.'
      );
    }
    const include = request.include
      ? boundedString(request.include, 'search_workspace.include', MAX_GLOB_BYTES)
      : DEFAULT_SEARCH_INCLUDE;
    const exclude = request.exclude
      ? boundedString(request.exclude, 'search_workspace.exclude', MAX_GLOB_BYTES)
      : undefined;
    const maxFiles = boundedInteger(
      request.maxFiles,
      'search_workspace.maxFiles',
      DEFAULT_SEARCH_MAX_FILES,
      MAX_SEARCH_FILES
    );
    const maxResults = boundedInteger(
      request.maxResults,
      'search_workspace.maxResults',
      DEFAULT_SEARCH_MAX_RESULTS,
      MAX_SEARCH_RESULTS,
      0
    );
    const maxFileBytes = boundedInteger(
      request.maxFileBytes,
      'search_workspace.maxFileBytes',
      DEFAULT_SEARCH_MAX_FILE_BYTES,
      MAX_SEARCH_FILE_BYTES
    );
    if (maxResults === 0) {
      return { matches: [] };
    }
    const files = await this.api.findFiles(include, exclude, maxFiles);
    const matches: BurnBarSearchWorkspaceMatch[] = [];
    const needle = request.caseSensitive ? query : query.toLowerCase();

    for (const uri of files) {
      if (matches.length >= maxResults) {
        break;
      }

      if (!(await this.isFileWithinByteLimit(uri, maxFileBytes))) {
        continue;
      }

      const bytes = await this.api.readFile(uri);
      if (bytes.byteLength > maxFileBytes) {
        continue;
      }
      const content = decoder.decode(bytes);
      const lines = content.split(/\r?\n/u);

      for (let lineIndex = 0; lineIndex < lines.length; lineIndex += 1) {
        const line = lines[lineIndex] ?? '';
        const haystack = request.caseSensitive ? line : line.toLowerCase();
        const character = haystack.indexOf(needle);
        if (character === -1) {
          continue;
        }

        matches.push({
          path: uri.toString(),
          line: lineIndex,
          character,
          preview: truncatePreview(line.trim())
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

  private async searchBurnbarIndex(
    request: BurnBarSearchBurnbarIndexRequest
  ): Promise<BurnBarSearchBurnbarIndexResult> {
    if (!this.indexedSearch) {
      throw new OpenBurnBarWorkspaceRpcError(
        'UNSUPPORTED',
        'OpenBurnBar indexed search is not available (daemon bridge not configured).'
      );
    }
    return this.indexedSearch(request);
  }

  private async applyPatch(request: OpenBurnBarApplyPatchRequest): Promise<OpenBurnBarApplyPatchResult> {
    smokeDebug(`apply_patch:start changes=${request.changes.length}`);
    const capabilities = this.capabilities();
    assertTrustedToolAllowed(capabilities, 'apply_patch');

    if (capabilities.readonlyWorkspace) {
      throw new OpenBurnBarWorkspaceRpcError(
        'READONLY_WORKSPACE',
        'OpenBurnBar cannot apply patches because the workspace filesystem is read-only.'
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
      throw new OpenBurnBarWorkspaceRpcError('APPLY_EDIT_FAILED', 'VS Code rejected the OpenBurnBar workspace edit.');
    }

    for (const changedFile of changedFiles) {
      const document = openedDocuments.get(changedFile);
      if (!document) {
        continue;
      }
      const saved = await document.save?.();
      if (saved === false) {
        throw new OpenBurnBarWorkspaceRpcError(
          'SAVE_FAILED',
          `OpenBurnBar applied the workspace edit, but VS Code did not persist ${changedFile}.`
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
    assertTrustedToolAllowed(capabilities, 'run_terminal');

    if (!capabilities.hasWorkspace) {
      throw new OpenBurnBarWorkspaceRpcError(
        'NO_WORKSPACE',
        'Open a workspace folder before running OpenBurnBar terminal commands.'
      );
    }

    if (capabilities.virtualWorkspace) {
      throw new OpenBurnBarWorkspaceRpcError(
        'VIRTUAL_WORKSPACE',
        'OpenBurnBar cannot run terminal commands from a virtual workspace.'
      );
    }

    const cwd = request.cwd ? this.cwdFor(request.cwd) : this.defaultWorkspaceCwd();
    const confirmed = await this.api.confirmTerminalCommand(request.command, cwd);
    if (!confirmed) {
      throw new OpenBurnBarWorkspaceRpcError(
        'TERMINAL_CANCELLED',
        'Terminal command execution was cancelled by the operator.'
      );
    }

    const terminal = this.api.createTerminal({
      name: request.name ?? 'OpenBurnBar',
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
    change: OpenBurnBarApplyPatchChange,
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
      throw new OpenBurnBarWorkspaceRpcError(
        'NO_WORKSPACE',
        'Open a workspace folder before running OpenBurnBar terminal commands.'
      );
    }

    if (workspaceUri.scheme !== 'file') {
      throw new OpenBurnBarWorkspaceRpcError(
        'VIRTUAL_WORKSPACE',
        'OpenBurnBar cannot map this workspace to a terminal working directory.'
      );
    }

    return workspaceUri.fsPath;
  }

  private cwdFor(target: string): string {
    const uri = resolveWorkspaceUri(this.api, target);
    if (uri.scheme !== 'file') {
      throw new OpenBurnBarWorkspaceRpcError(
        'VIRTUAL_WORKSPACE',
        'OpenBurnBar can only launch terminals from file-backed workspace paths.'
      );
    }

    return uri.fsPath;
  }

  private async assertFileWithinByteLimit(uri: ReturnType<typeof resolveWorkspaceUri>, maxBytes: number, code: string) {
    if (await this.isFileWithinByteLimit(uri, maxBytes)) {
      return;
    }

    throw new OpenBurnBarWorkspaceRpcError(code, `OpenBurnBar workspace file access is limited to ${maxBytes} bytes.`);
  }

  private async isFileWithinByteLimit(uri: ReturnType<typeof resolveWorkspaceUri>, maxBytes: number): Promise<boolean> {
    const stat = await this.api.stat(uri);
    return Number.isFinite(stat.size) && stat.size <= maxBytes;
  }
}

export function activateOpenBurnBarWorkspaceCompanion(
  hostKind: BurnBarWorkspaceHostKind,
  deps?: { indexedSearch?: BurnBarIndexedSearchBridge }
): OpenBurnBarWorkspaceCompanion {
  return new OpenBurnBarWorkspaceCompanion(createBurnBarWorkspaceApi(hostKind), deps?.indexedSearch);
}

function assertTrustedToolAllowed(
  capabilities: BurnBarWorkspaceCapabilities,
  tool: 'apply_patch' | 'run_terminal'
): void {
  if (!capabilities.untrustedWorkspace) {
    return;
  }

  throw new OpenBurnBarWorkspaceRpcError(
    'TRUST_REQUIRED',
    `OpenBurnBar cannot ${tool === 'apply_patch' ? 'apply patches' : 'run terminal commands'} while the workspace is in restricted mode. Trust the workspace to enable this tool.`
  );
}

function smokeDebug(message: string): void {
  if (process.env.BURNBAR_CURSOR_SMOKE_OUTPUT) {
    console.warn(`[OpenBurnBar smoke] ${message}`);
  }
}

function boundedString(value: unknown, label: string, maxBytes: number): string {
  if (typeof value !== 'string') {
    throw new OpenBurnBarWorkspaceRpcError('INVALID_PARAMS', `${label} must be a string.`);
  }
  if (encoder.encode(value).byteLength > maxBytes) {
    throw new OpenBurnBarWorkspaceRpcError('INVALID_PARAMS', `${label} is limited to ${maxBytes} bytes.`);
  }
  return value;
}

function boundedInteger(
  value: unknown,
  label: string,
  defaultValue: number,
  maxValue: number,
  minValue = 1
): number {
  if (value === undefined || value === null) {
    return defaultValue;
  }
  if (typeof value !== 'number' || !Number.isFinite(value) || value < minValue) {
    throw new OpenBurnBarWorkspaceRpcError(
      'INVALID_PARAMS',
      `${label} must be a finite number greater than or equal to ${minValue}.`
    );
  }
  return Math.min(Math.floor(value), maxValue);
}

function truncatePreview(value: string): string {
  return value.length > MAX_PREVIEW_CHARACTERS ? `${value.slice(0, MAX_PREVIEW_CHARACTERS)}...` : value;
}
