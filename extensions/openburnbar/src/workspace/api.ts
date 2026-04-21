import * as path from 'node:path';

import * as vscode from 'vscode';

import { OpenBurnBarWorkspaceRpcError, type BurnBarWorkspaceHostKind } from './types';

export interface BurnBarWorkspaceUri {
  scheme: string;
  fsPath: string;
  toString(): string;
}

export interface BurnBarWorkspaceFolder {
  uri: BurnBarWorkspaceUri;
}

export interface BurnBarWorkspaceTextDocument {
  getText(): string;
  positionAt(offset: number): BurnBarWorkspacePosition;
  save?(): Thenable<boolean>;
}

export interface BurnBarWorkspacePosition {
  line: number;
  character: number;
}

export interface BurnBarWorkspaceRange {
  start: BurnBarWorkspacePosition;
  end: BurnBarWorkspacePosition;
}

export interface BurnBarWorkspaceEditBuilder {
  replace(uri: BurnBarWorkspaceUri, range: BurnBarWorkspaceRange, text: string): void;
}

export interface BurnBarWorkspaceTerminal {
  name: string;
  show(preserveFocus?: boolean): void;
  sendText(text: string, addNewLine?: boolean): void;
}

export interface BurnBarWorkspaceApi {
  readonly hostKind: BurnBarWorkspaceHostKind;
  readonly remoteName: string | undefined;
  readonly isTrusted: boolean;
  readonly workspaceFolders: readonly BurnBarWorkspaceFolder[] | undefined;
  isWritableFileSystem(scheme: string): boolean | undefined;
  readFile(uri: BurnBarWorkspaceUri): Thenable<Uint8Array>;
  findFiles(include: string, exclude: string | undefined, maxResults: number): Thenable<readonly BurnBarWorkspaceUri[]>;
  openTextDocument(uri: BurnBarWorkspaceUri): Thenable<BurnBarWorkspaceTextDocument>;
  applyEdit(edit: BurnBarWorkspaceEditBuilder): Thenable<boolean>;
  saveAll(includeUntitled?: boolean): Thenable<boolean>;
  createWorkspaceEdit(): BurnBarWorkspaceEditBuilder;
  createRange(
    startLine: number,
    startCharacter: number,
    endLine: number,
    endCharacter: number
  ): BurnBarWorkspaceRange;
  confirmTerminalCommand(command: string, cwd: string): Thenable<boolean>;
  createTerminal(options: { name: string; cwd?: string }): BurnBarWorkspaceTerminal;
  parseUri(value: string): BurnBarWorkspaceUri;
  fileUri(value: string): BurnBarWorkspaceUri;
  joinPath(base: BurnBarWorkspaceUri, ...paths: string[]): BurnBarWorkspaceUri;
}

export function createBurnBarWorkspaceApi(hostKind: BurnBarWorkspaceHostKind): BurnBarWorkspaceApi {
  return {
    hostKind,
    remoteName: vscode.env.remoteName,
    isTrusted: vscode.workspace.isTrusted,
    workspaceFolders: vscode.workspace.workspaceFolders,
    isWritableFileSystem: (scheme) => vscode.workspace.fs.isWritableFileSystem(scheme),
    readFile: (uri) => vscode.workspace.fs.readFile(uri as vscode.Uri),
    findFiles: (include, exclude, maxResults) => vscode.workspace.findFiles(include, exclude, maxResults),
    openTextDocument: (uri) => vscode.workspace.openTextDocument(uri as vscode.Uri),
    applyEdit: (edit) => vscode.workspace.applyEdit(edit as vscode.WorkspaceEdit),
    saveAll: (includeUntitled) => vscode.workspace.saveAll(includeUntitled),
    createWorkspaceEdit: () => new vscode.WorkspaceEdit(),
    createRange: (startLine, startCharacter, endLine, endCharacter) =>
      new vscode.Range(startLine, startCharacter, endLine, endCharacter),
    confirmTerminalCommand: async (command, cwd) => {
      const selection = await vscode.window.showWarningMessage(
        'OpenBurnBar wants to run a terminal command.',
        {
          modal: true,
          detail: `Command: ${command}\nWorking directory: ${cwd}`
        },
        'Run Command'
      );
      return selection === 'Run Command';
    },
    createTerminal: (options) => vscode.window.createTerminal(options),
    parseUri: (value) => vscode.Uri.parse(value),
    fileUri: (value) => vscode.Uri.file(value),
    joinPath: (base, ...segments) => vscode.Uri.joinPath(base as vscode.Uri, ...segments)
  };
}

export function resolveWorkspaceUri(api: Pick<BurnBarWorkspaceApi, 'workspaceFolders' | 'parseUri' | 'fileUri' | 'joinPath'>, target: string): BurnBarWorkspaceUri {
  const roots = api.workspaceFolders ?? [];
  if (roots.length === 0) {
    throw new OpenBurnBarWorkspaceRpcError(
      'NO_WORKSPACE',
      'Open a workspace folder before using OpenBurnBar workspace tools.'
    );
  }

  let resolved: BurnBarWorkspaceUri;
  if (looksLikeUri(target)) {
    resolved = api.parseUri(target);
  } else if (path.isAbsolute(target)) {
    resolved = api.fileUri(target);
  } else {
    const workspaceRoot = roots[0];
    if (!workspaceRoot) {
      throw new OpenBurnBarWorkspaceRpcError(
        'NO_WORKSPACE',
        'Open a workspace folder before using OpenBurnBar workspace tools.'
      );
    }
    resolved = api.joinPath(workspaceRoot.uri, ...target.split('/').filter(Boolean));
  }

  if (!isWithinWorkspaceRoots(resolved, roots)) {
    throw new OpenBurnBarWorkspaceRpcError(
      'PATH_OUTSIDE_WORKSPACE',
      `OpenBurnBar cannot access '${target}' because it is outside the opened workspace root.`
    );
  }

  return resolved;
}

function looksLikeUri(value: string): boolean {
  return /^[a-z][a-z0-9+.-]*:/i.test(value);
}

function isWithinWorkspaceRoots(
  candidate: BurnBarWorkspaceUri,
  workspaceFolders: readonly BurnBarWorkspaceFolder[]
): boolean {
  return workspaceFolders.some((folder) => isWithinWorkspaceRoot(candidate, folder.uri));
}

function isWithinWorkspaceRoot(candidate: BurnBarWorkspaceUri, root: BurnBarWorkspaceUri): boolean {
  if (candidate.scheme !== root.scheme) {
    return false;
  }

  if (candidate.scheme === 'file') {
    return isWithinFileRoot(candidate.fsPath, root.fsPath);
  }

  return isUriDescendant(candidate.toString(), root.toString());
}

function isWithinFileRoot(candidatePath: string, rootPath: string): boolean {
  const normalizedCandidate = path.resolve(candidatePath);
  const normalizedRoot = path.resolve(rootPath);

  if (normalizedCandidate === normalizedRoot) {
    return true;
  }

  const relativePath = path.relative(normalizedRoot, normalizedCandidate);
  return relativePath !== '' && !relativePath.startsWith('..') && !path.isAbsolute(relativePath);
}

function isUriDescendant(candidate: string, root: string): boolean {
  const normalizedRoot = root.endsWith('/') ? root.slice(0, -1) : root;
  return candidate === normalizedRoot || candidate.startsWith(`${normalizedRoot}/`);
}
