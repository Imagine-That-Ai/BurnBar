import * as path from "node:path";

import { beforeEach, describe, expect, it, vi } from "vitest";

import type {
  BurnBarWorkspaceApi,
  BurnBarWorkspaceEditBuilder,
  BurnBarWorkspacePosition,
  BurnBarWorkspaceRange,
  BurnBarWorkspaceTerminal,
  BurnBarWorkspaceTextDocument,
  BurnBarWorkspaceUri
} from "../src/workspace/api";
import { OpenBurnBarWorkspaceCompanion } from "../src/workspace/companion";
import { OpenBurnBarWorkspaceRpcClient } from "../src/workspace/rpc";
import { OpenBurnBarWorkspaceRpcError, type BurnBarWorkspaceRpcRequest } from "../src/workspace/types";

const commandRegistrations = new Map<string, (...args: unknown[]) => unknown>();

vi.mock("vscode", () => {
  return {
    commands: {
      registerCommand(command: string, callback: (...args: unknown[]) => unknown) {
        commandRegistrations.set(command, callback);
        return {
          dispose() {
            commandRegistrations.delete(command);
          }
        };
      }
    }
  };
}, { virtual: true });

describe("OpenBurnBar workspace RPC", () => {
  beforeEach(() => {
    commandRegistrations.clear();
  });

  it("bridges command RPC into the local workspace companion and executes workspace tools", async () => {
    const api = createFakeWorkspaceApi();
    const companion = new OpenBurnBarWorkspaceCompanion(api);
    const client = new OpenBurnBarWorkspaceRpcClient({
      executeCommand: async (_command, request: BurnBarWorkspaceRpcRequest) => companion.handle(request)
    });

    await expect(client.capabilities()).resolves.toMatchObject({
      localWorkspace: true,
      availableTools: ["read_file", "search_workspace", "apply_patch", "run_terminal"]
    });

    await expect(client.readFile({ path: "src/example.ts" })).resolves.toMatchObject({
      content: "const value = 1;\nconsole.log(value);\n"
    });

    await expect(client.searchWorkspace({ query: "console.log" })).resolves.toEqual({
      matches: [
        {
          path: "file:///workspace/src/example.ts",
          line: 1,
          character: 0,
          preview: "console.log(value);"
        }
      ]
    });

    await expect(
      client.applyPatch({
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
      })
    ).resolves.toEqual({
      applied: true,
      changedFiles: ["file:///workspace/src/example.ts"]
    });

    await expect(client.readFile({ path: "src/example.ts" })).resolves.toMatchObject({
      content: "const value = 2;\nconsole.log(value);\n"
    });

    await expect(client.runTerminal({ command: "npm test", cwd: "scripts" })).resolves.toEqual({
      terminalName: "OpenBurnBar",
      cwd: "/workspace/scripts"
    });
    expect(api.terminals[0]).toMatchObject({
      name: "OpenBurnBar",
      lastCommand: "npm test",
      shownWithPreserveFocus: true
    });

    companion.dispose();
  });

  it("gates unsafe tools while the workspace is untrusted", async () => {
    const api = createFakeWorkspaceApi({
      isTrusted: false
    });
    const companion = new OpenBurnBarWorkspaceCompanion(api);
    const client = new OpenBurnBarWorkspaceRpcClient({
      executeCommand: async (_command, request: BurnBarWorkspaceRpcRequest) => companion.handle(request)
    });

    await expect(
      client.applyPatch({
        changes: [
          {
            path: "src/example.ts",
            text: "blocked"
          }
        ]
      })
    ).rejects.toMatchObject<OpenBurnBarWorkspaceRpcError>({
      code: "TRUST_REQUIRED"
    });

    await expect(client.runTerminal({ command: "npm test" })).rejects.toMatchObject<OpenBurnBarWorkspaceRpcError>({
      code: "TRUST_REQUIRED"
    });

    companion.dispose();
  });

  it("rejects file and terminal access outside the opened workspace root", async () => {
    const api = createFakeWorkspaceApi();
    const companion = new OpenBurnBarWorkspaceCompanion(api);
    const client = new OpenBurnBarWorkspaceRpcClient({
      executeCommand: async (_command, request: BurnBarWorkspaceRpcRequest) => companion.handle(request)
    });

    await expect(client.readFile({ path: "/outside/secrets.txt" })).rejects.toMatchObject<OpenBurnBarWorkspaceRpcError>({
      code: "PATH_OUTSIDE_WORKSPACE"
    });

    await expect(
      client.applyPatch({
        changes: [
          {
            path: "../outside.txt",
            text: "blocked"
          }
        ]
      })
    ).rejects.toMatchObject<OpenBurnBarWorkspaceRpcError>({
      code: "PATH_OUTSIDE_WORKSPACE"
    });

    await expect(
      client.runTerminal({ command: "npm test", cwd: "../outside" })
    ).rejects.toMatchObject<OpenBurnBarWorkspaceRpcError>({
      code: "PATH_OUTSIDE_WORKSPACE"
    });

    companion.dispose();
  });

  it("opens patched files before saving so edits persist in Cursor-like workspaces", async () => {
    const api = createFakeWorkspaceApi({
      persistOnlyIfOpenedBeforeApply: true
    });
    const companion = new OpenBurnBarWorkspaceCompanion(api);
    const client = new OpenBurnBarWorkspaceRpcClient({
      executeCommand: async (_command, request: BurnBarWorkspaceRpcRequest) => companion.handle(request)
    });

    await expect(
      client.applyPatch({
        changes: [
          {
            path: "src/example.ts",
            text: "const value = 2;\nconsole.log(value);\n"
          }
        ]
      })
    ).resolves.toEqual({
      applied: true,
      changedFiles: ["file:///workspace/src/example.ts"]
    });

    await expect(client.readFile({ path: "src/example.ts" })).resolves.toMatchObject({
      content: "const value = 2;\nconsole.log(value);\n"
    });

    companion.dispose();
  });

  it("requires explicit terminal confirmation before command execution", async () => {
    const api = createFakeWorkspaceApi({ terminalConfirmation: false });
    const companion = new OpenBurnBarWorkspaceCompanion(api);
    const client = new OpenBurnBarWorkspaceRpcClient({
      executeCommand: async (_command, request: BurnBarWorkspaceRpcRequest) => companion.handle(request)
    });

    await expect(client.runTerminal({ command: "npm test" })).rejects.toMatchObject<OpenBurnBarWorkspaceRpcError>({
      code: "TERMINAL_CANCELLED"
    });
    expect(api.terminals).toHaveLength(0);

    companion.dispose();
  });
});

function createFakeWorkspaceApi(options: {
  isTrusted?: boolean;
  persistOnlyIfOpenedBeforeApply?: boolean;
  terminalConfirmation?: boolean;
} = {}): BurnBarWorkspaceApi & {
  terminals: Array<FakeTerminal & BurnBarWorkspaceTerminal>;
} {
  const files = new Map<string, string>([["file:///workspace/src/example.ts", "const value = 1;\nconsole.log(value);\n"]]);
  const openDocuments = new Map<string, FakeDocument>();
  const terminals: Array<FakeTerminal & BurnBarWorkspaceTerminal> = [];

  return {
    hostKind: "ui",
    remoteName: undefined,
    isTrusted: options.isTrusted ?? true,
    workspaceFolders: [
      {
        uri: createUri("file:///workspace")
      }
    ],
    terminals,
    isWritableFileSystem: () => true,
    async readFile(uri) {
      const content = files.get(uri.toString()) ?? "";
      return new TextEncoder().encode(content);
    },
    async findFiles() {
      return [...files.keys()].map((value) => createUri(value));
    },
    async openTextDocument(uri) {
      const key = uri.toString();
      const existing = openDocuments.get(key);
      if (existing) {
        return existing;
      }

      const document = new FakeDocument(key, files);
      openDocuments.set(key, document);
      return document;
    },
    async applyEdit(edit) {
      for (const change of (edit as FakeWorkspaceEdit).changes) {
        const key = change.uri.toString();
        const current = files.get(key) ?? "";
        const document = openDocuments.get(key);

        if (options.persistOnlyIfOpenedBeforeApply) {
          if (!document) {
            continue;
          }

          document.replace(change.range, change.text);
          continue;
        }

        if (document) {
          document.replace(change.range, change.text);
          files.set(key, document.getText());
          continue;
        }

        files.set(key, replaceText(current, change.range, change.text));
      }
      return true;
    },
    async saveAll() {
      return true;
    },
    createWorkspaceEdit() {
      return new FakeWorkspaceEdit();
    },
    createRange(startLine, startCharacter, endLine, endCharacter) {
      return {
        start: { line: startLine, character: startCharacter },
        end: { line: endLine, character: endCharacter }
      };
    },
    async confirmTerminalCommand() {
      return options.terminalConfirmation ?? true;
    },
    createTerminal(options) {
      const terminal = new FakeTerminal(options.name, options.cwd);
      terminals.push(terminal);
      return terminal;
    },
    parseUri(value) {
      return createUri(value);
    },
    fileUri(value) {
      return createUri(`file://${value}`);
    },
    joinPath(base, ...segments) {
      return createUri(`file://${path.posix.join(base.fsPath, ...segments)}`);
    }
  };
}

class FakeWorkspaceEdit implements BurnBarWorkspaceEditBuilder {
  readonly changes: Array<{ uri: BurnBarWorkspaceUri; range: BurnBarWorkspaceRange; text: string }> = [];

  replace(uri: BurnBarWorkspaceUri, range: BurnBarWorkspaceRange, text: string): void {
    this.changes.push({ uri, range, text });
  }
}

class FakeTerminal implements BurnBarWorkspaceTerminal {
  lastCommand?: string;
  shownWithPreserveFocus?: boolean;

  constructor(
    readonly name: string,
    readonly cwd?: string
  ) {}

  show(preserveFocus?: boolean): void {
    this.shownWithPreserveFocus = preserveFocus;
  }

  sendText(text: string): void {
    this.lastCommand = text;
  }
}

class FakeDocument implements BurnBarWorkspaceTextDocument {
  private content: string;
  private dirty = false;

  constructor(
    private readonly key: string,
    private readonly files: Map<string, string>
  ) {
    this.content = files.get(key) ?? "";
  }

  getText(): string {
    return this.content;
  }

  positionAt(offset: number): BurnBarWorkspacePosition {
    const prefix = this.content.slice(0, offset);
    const lines = prefix.split("\n");
    return {
      line: lines.length - 1,
      character: lines.at(-1)?.length ?? 0
    };
  }

  async save(): Promise<boolean> {
    if (this.dirty) {
      this.files.set(this.key, this.content);
      this.dirty = false;
    }

    return true;
  }

  replace(range: BurnBarWorkspaceRange | undefined, text: string): void {
    this.content = range ? replaceText(this.content, range, text) : text;
    this.dirty = true;
  }
}

function replaceText(content: string, range: BurnBarWorkspaceRange, text: string): string {
  const startOffset = offsetAt(content, range.start);
  const endOffset = offsetAt(content, range.end);
  return `${content.slice(0, startOffset)}${text}${content.slice(endOffset)}`;
}

function offsetAt(content: string, position: BurnBarWorkspacePosition): number {
  const lines = content.split("\n");
  let offset = 0;

  for (let lineIndex = 0; lineIndex < position.line; lineIndex += 1) {
    offset += (lines[lineIndex]?.length ?? 0) + 1;
  }

  return offset + position.character;
}

function createUri(value: string): BurnBarWorkspaceUri {
  const normalized = value.startsWith("file://") ? value : value.replace("file:/", "file://");
  const fsPath = normalized.replace(/^file:\/\//u, "");
  return {
    scheme: normalized.split(":")[0] ?? "file",
    fsPath,
    toString: () => normalized
  };
}
