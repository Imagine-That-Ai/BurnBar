import * as path from "node:path";

import * as vscode from "vscode";

import type { BurnBarWorkspaceHostKind } from "./types";

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
    createTerminal: (options) => vscode.window.createTerminal(options),
    parseUri: (value) => vscode.Uri.parse(value),
    fileUri: (value) => vscode.Uri.file(value),
    joinPath: (base, ...segments) => vscode.Uri.joinPath(base as vscode.Uri, ...segments)
  };
}

export function resolveWorkspaceUri(api: Pick<BurnBarWorkspaceApi, "workspaceFolders" | "parseUri" | "fileUri" | "joinPath">, target: string): BurnBarWorkspaceUri {
  if (looksLikeUri(target)) {
    return api.parseUri(target);
  }

  if (path.isAbsolute(target)) {
    return api.fileUri(target);
  }

  const root = api.workspaceFolders?.[0]?.uri;
  if (!root) {
    throw new Error("Open a workspace folder before using BurnBar workspace tools with relative paths.");
  }

  return api.joinPath(root, ...target.split("/").filter(Boolean));
}

function looksLikeUri(value: string): boolean {
  return /^[a-z][a-z0-9+.-]*:/i.test(value);
}
