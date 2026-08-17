import { realpathSync } from 'node:fs';
import * as path from 'node:path';
import { tmpdir } from 'node:os';
import { fileURLToPath } from 'node:url';

import * as vscode from 'vscode';

import { OpenBurnBarWorkspaceRpcError, type BurnBarWorkspaceHostKind, type OpenBurnBarApplyPatchChange } from './types';

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
  createRange(startLine: number, startCharacter: number, endLine: number, endCharacter: number): BurnBarWorkspaceRange;
  confirmWorkspaceEdit(
    changes: readonly OpenBurnBarApplyPatchChange[],
    changedFiles: readonly string[]
  ): Thenable<boolean>;
  confirmTerminalCommand(command: string, cwd: string): Thenable<boolean>;
  createTerminal(options: { name: string; cwd?: string }): BurnBarWorkspaceTerminal;
  parseUri(value: string): BurnBarWorkspaceUri;
  fileUri(value: string): BurnBarWorkspaceUri;
  joinPath(base: BurnBarWorkspaceUri, ...paths: string[]): BurnBarWorkspaceUri;
}

interface CursorSmokeWorkspaceEditConfiguration {
  autoConfirm?: boolean;
  outputPath?: string;
  filePath?: string;
}

export function createBurnBarWorkspaceApi(hostKind: BurnBarWorkspaceHostKind): BurnBarWorkspaceApi {
  return {
    hostKind,
    remoteName: vscode.env.remoteName,
    isTrusted: vscode.workspace.isTrusted,
    workspaceFolders: vscode.workspace.workspaceFolders,
    isWritableFileSystem: (scheme) => vscode.workspace.fs.isWritableFileSystem(scheme),
    readFile: (uri) => vscode.workspace.fs.readFile(toVSCodeUri(uri)),
    findFiles: (include, exclude, maxResults) => vscode.workspace.findFiles(include, exclude, maxResults),
    openTextDocument: (uri) => vscode.workspace.openTextDocument(toVSCodeUri(uri)),
    applyEdit: (edit) => vscode.workspace.applyEdit(toWorkspaceEdit(edit)),
    saveAll: (includeUntitled) => vscode.workspace.saveAll(includeUntitled),
    createWorkspaceEdit: () => new vscode.WorkspaceEdit(),
    createRange: (startLine, startCharacter, endLine, endCharacter) =>
      new vscode.Range(startLine, startCharacter, endLine, endCharacter),
    confirmWorkspaceEdit: async (changes, changedFiles) => {
      const smokeConfig =
        typeof vscode.workspace.getConfiguration === 'function' ? vscode.workspace.getConfiguration() : undefined;
      const smokeConfiguration = {
        autoConfirm: smokeConfig?.get<boolean>('openburnbar.cursorSmoke.autoConfirm'),
        outputPath: smokeConfig?.get<string>('openburnbar.cursorSmoke.outputPath'),
        filePath: smokeConfig?.get<string>('openburnbar.cursorSmoke.filePath')
      };
      const autoConfirmAllowed = isCursorSmokeWorkspaceEditAutoConfirmAllowed(
        changes,
        changedFiles,
        process.env,
        smokeConfiguration
      );
      if (autoConfirmAllowed) {
        return true;
      }
      const selection = await vscode.window.showWarningMessage(
        'OpenBurnBar wants to edit workspace files.',
        {
          modal: true,
          detail: summarizeWorkspaceEdit(changes, changedFiles)
        },
        'Apply Patch'
      );
      return selection === 'Apply Patch';
    },
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
    joinPath: (base, ...segments) => vscode.Uri.joinPath(toVSCodeUri(base), ...segments)
  };
}

export function isCursorSmokeWorkspaceEditAutoConfirmAllowed(
  changes: readonly OpenBurnBarApplyPatchChange[],
  changedFiles: readonly string[],
  env: Record<string, string | undefined> = process.env,
  config: CursorSmokeWorkspaceEditConfiguration = {},
  approvedTempRoots: readonly string[] = cursorSmokeTempRoots()
): boolean {
  const autoConfirm = env.BURNBAR_CURSOR_SMOKE_AUTO_CONFIRM;
  const isAutoConfirmEnabled = autoConfirm === undefined ? config.autoConfirm === true : autoConfirm === '1';
  if (!isAutoConfirmEnabled || changes.length !== 1 || changedFiles.length !== 1) {
    return false;
  }

  const outputPath = env.BURNBAR_CURSOR_SMOKE_OUTPUT?.trim() || config.outputPath?.trim();
  const targetPath = env.BURNBAR_CURSOR_SMOKE_FILE_PATH?.trim() || config.filePath?.trim();
  const changePath = changes[0]?.path;
  const changedFile = changedFiles[0];
  if (
    !outputPath ||
    !targetPath ||
    !changePath ||
    !changedFile ||
    !path.isAbsolute(outputPath) ||
    !path.isAbsolute(targetPath)
  ) {
    return false;
  }

  const resolvedOutputRoot = path.dirname(path.resolve(outputPath));
  const outputRootIsApproved = approvedTempRoots.some((root) =>
    isStrictPathDescendant(canonicalizePath(resolvedOutputRoot), canonicalizePath(root))
  );
  const resolvedTarget = path.resolve(targetPath);
  const targetRelativeToOutput = path.relative(resolvedOutputRoot, resolvedTarget);
  if (
    !outputRootIsApproved ||
    targetRelativeToOutput === '' ||
    targetRelativeToOutput.startsWith('..') ||
    path.isAbsolute(targetRelativeToOutput) ||
    path.resolve(changePath) !== resolvedTarget
  ) {
    return false;
  }

  try {
    const resolvedChangedFile = changedFile.startsWith('file:')
      ? path.resolve(fileURLToPath(changedFile))
      : path.resolve(changedFile);
    return resolvedChangedFile === resolvedTarget;
  } catch {
    return false;
  }
}

function cursorSmokeTempRoots(): readonly string[] {
  if (process.platform === 'win32') {
    return [tmpdir()];
  }
  return process.platform === 'darwin' ? [tmpdir(), '/tmp', '/private/tmp'] : [tmpdir(), '/tmp'];
}

function canonicalizePath(value: string): string {
  const resolved = path.resolve(value);
  try {
    return realpathSync(resolved);
  } catch {
    const parent = path.dirname(resolved);
    if (parent === resolved) {
      return resolved;
    }
    try {
      return path.join(realpathSync(parent), path.basename(resolved));
    } catch {
      return resolved;
    }
  }
}

function isStrictPathDescendant(candidate: string, root: string): boolean {
  const relative = path.relative(root, candidate);
  return relative !== '' && !relative.startsWith('..') && !path.isAbsolute(relative);
}

function summarizeWorkspaceEdit(
  changes: readonly OpenBurnBarApplyPatchChange[],
  changedFiles: readonly string[]
): string {
  const fileSummary = changedFiles.length === 0
    ? 'No resolved files.'
    : changedFiles.slice(0, 12).join('\n');
  const omitted = changedFiles.length > 12 ? `\n...and ${changedFiles.length - 12} more file(s).` : '';
  const replacementBytes = changes.reduce((total, change) => total + change.text.length, 0);
  return `Files: ${changedFiles.length}\nChanges: ${changes.length}\nReplacement bytes: ${replacementBytes}\n\n${fileSummary}${omitted}`;
}

function toVSCodeUri(uri: BurnBarWorkspaceUri): vscode.Uri {
  if (uri instanceof vscode.Uri) {
    return uri;
  }
  return uri.scheme === 'file' ? vscode.Uri.file(uri.fsPath) : vscode.Uri.parse(uri.toString());
}

function toWorkspaceEdit(edit: BurnBarWorkspaceEditBuilder): vscode.WorkspaceEdit {
  if (edit instanceof vscode.WorkspaceEdit) {
    return edit;
  }
  throw new OpenBurnBarWorkspaceRpcError(
    'APPLY_EDIT_FAILED',
    'OpenBurnBar could not apply an incompatible workspace edit.'
  );
}

export function resolveWorkspaceUri(
  api: Pick<BurnBarWorkspaceApi, 'workspaceFolders' | 'parseUri' | 'fileUri' | 'joinPath'>,
  target: string
): BurnBarWorkspaceUri {
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
