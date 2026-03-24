import { beforeEach, describe, expect, it, vi } from "vitest";

const registeredCommands = new Map<string, (...args: unknown[]) => unknown>();
const createdViews: string[] = [];
const registeredWebviewProviders = new Map<string, unknown>();
const infoMessages: string[] = [];
const warningMessages: string[] = [];
const inputPrompts: string[] = [];
const quickPickPrompts: string[] = [];

class MockDisposable {
  constructor(private readonly callback: () => void = () => undefined) {}

  dispose(): void {
    this.callback();
  }
}

class MockEventEmitter<T> {
  private listeners = new Set<(value: T) => void>();

  readonly event = (listener: (value: T) => void): MockDisposable => {
    this.listeners.add(listener);
    return new MockDisposable(() => this.listeners.delete(listener));
  };

  fire(value: T): void {
    for (const listener of this.listeners) {
      listener(value);
    }
  }

  dispose(): void {
    this.listeners.clear();
  }
}

class MockTreeItem {
  label: string;
  description?: string;
  tooltip?: string;
  iconPath?: unknown;
  contextValue?: string;
  id?: string;

  constructor(label: string) {
    this.label = label;
  }
}

class MockThemeIcon {
  constructor(readonly id: string) {}
}

const windowStateEmitter = new MockEventEmitter<{ focused: boolean }>();

vi.mock("vscode", () => {
  return {
    EventEmitter: MockEventEmitter,
    TreeItem: MockTreeItem,
    TreeItemCollapsibleState: {
      None: 0
    },
    ThemeIcon: MockThemeIcon,
    commands: {
      registerCommand(command: string, callback: (...args: unknown[]) => unknown) {
        registeredCommands.set(command, callback);
        return new MockDisposable(() => registeredCommands.delete(command));
      }
    },
    env: {
      remoteName: undefined
    },
    ExtensionKind: {
      UI: 1,
      Workspace: 2
    },
    workspace: {
      isTrusted: true,
      getConfiguration: () => ({
        get: (_key: string, fallback?: unknown) => fallback
      }),
      workspaceFolders: [
        {
          uri: {
            scheme: "file",
            fsPath: "/workspace",
            toString: () => "file:///workspace"
          }
        }
      ],
      fs: {
        isWritableFileSystem: () => true,
        readFile: () => Promise.resolve(new Uint8Array())
      },
      findFiles: () => Promise.resolve([]),
      openTextDocument: () =>
        Promise.resolve({
          getText: () => "",
          positionAt: () => ({ line: 0, character: 0 })
        }),
      applyEdit: () => Promise.resolve(true)
    },
    window: {
      createTreeView(viewId: string, _options: unknown) {
        createdViews.push(viewId);
        return {
          onDidChangeSelection: () => new MockDisposable(),
          dispose: () => undefined
        };
      },
      registerWebviewViewProvider(viewType: string, provider: unknown) {
        registeredWebviewProviders.set(viewType, provider);
        return new MockDisposable(() => registeredWebviewProviders.delete(viewType));
      },
      onDidChangeWindowState(listener: (state: { focused: boolean }) => void) {
        return windowStateEmitter.event(listener);
      },
      showInformationMessage(message: string) {
        infoMessages.push(message);
        return Promise.resolve(undefined);
      },
      showWarningMessage(message: string) {
        warningMessages.push(message);
        return Promise.resolve(undefined);
      },
      showInputBox(options: { title?: string }) {
        inputPrompts.push(options.title ?? "");
        return Promise.resolve(undefined);
      },
      showQuickPick(_items: unknown[], options: { title?: string }) {
        quickPickPrompts.push(options.title ?? "");
        return Promise.resolve(undefined);
      },
      createTerminal() {
        return {
          name: "BurnBar",
          show: () => undefined,
          sendText: () => undefined
        };
      },
      createWebviewPanel() {
        return {
          webview: {
            html: "",
            options: {},
            asWebviewUri: (uri: unknown) => uri,
            onDidReceiveMessage: () => new MockDisposable(),
            postMessage: () => Promise.resolve(true),
            cspSource: "https://test.example"
          },
          onDidDispose: () => new MockDisposable(),
          reveal: () => undefined,
          dispose: () => undefined
        };
      }
    },
    ViewColumn: {
      One: 1
    },
    Uri: {
      joinPath: (...parts: unknown[]) => parts.join("/")
    }
  };
}, { virtual: true });

describe("activateBurnBarExtension", () => {
  beforeEach(() => {
    registeredCommands.clear();
    createdViews.length = 0;
    registeredWebviewProviders.clear();
    infoMessages.length = 0;
    warningMessages.length = 0;
    inputPrompts.length = 0;
    quickPickPrompts.length = 0;
  });

  it("registers BurnBar views and commands during activation", async () => {
    const { activateBurnBarExtension } = await import("../src/extension");

    const context = {
      subscriptions: [] as Array<{ dispose(): void }>,
      globalState: {
        get: () => undefined,
        update: () => Promise.resolve()
      }
    };
    await activateBurnBarExtension(context as never, {
      controllerDependencies: {
        client: {
          health: vi.fn().mockResolvedValue({
            ok: true,
            daemonVersion: "0.1.0",
            protocolVersion: 1,
            socketPath: "/tmp/burnbar.sock"
          }),
          catalog: vi.fn().mockResolvedValue({
            schemaVersion: 1,
            providers: []
          }),
          config: vi.fn().mockResolvedValue({ providers: [] }),
          recentUsage: vi.fn().mockResolvedValue([]),
          attach: vi.fn().mockResolvedValue({
            attachedClientID: "test-client",
            negotiatedProtocolVersion: 1
          }),
          detach: vi.fn().mockResolvedValue({
            activeClientID: "test-client",
            attachedClientIDs: ["test-client"]
          }),
          createRun: vi.fn(),
          listRuns: vi.fn().mockResolvedValue([]),
          pollRuns: vi.fn().mockResolvedValue({
            runs: [],
            approvals: [],
            pendingToolCalls: [],
            arbitration: {
              activeClientID: "test-client",
              attachedClientIDs: ["test-client"]
            },
            emittedAt: "2026-03-22T10:00:00.000Z"
          }),
          getRun: vi.fn().mockResolvedValue({ run: null, approvalRequest: null, arbitration: null }),
          cancelRun: vi.fn().mockResolvedValue({ run: null, approvalRequest: null, arbitration: null }),
          retryRun: vi.fn().mockResolvedValue({ run: null, approvalRequest: null, arbitration: null }),
          executeTool: vi.fn().mockResolvedValue({ disposition: "no_pending_tool_call" }),
          submitToolResult: vi.fn().mockResolvedValue({ run: null, approvalRequest: null, arbitration: null }),
          respondToApproval: vi.fn().mockResolvedValue({ run: null, approvalRequest: null, arbitration: null })
        },
        repairService: {
          repair: vi.fn().mockResolvedValue({
            message: "BurnBar daemon restart requested."
          })
        },
        workspaceClient: {
          capabilities: vi.fn().mockResolvedValue({
            hasWorkspace: true,
            localWorkspace: true,
            remoteWorkspace: false,
            readonlyWorkspace: false,
            virtualWorkspace: false,
            untrustedWorkspace: false,
            workspaceHost: "ui",
            availableTools: ["read_file", "search_workspace", "apply_patch", "run_terminal"],
            gatedTools: [],
            explanation: "Workspace tools are running in the local extension host. All PR6 workspace tools are available."
          })
        }
      },
      autoRefreshIntervalMs: 0,
      extensionKind: 1,
      remoteName: undefined
    });

    expect(createdViews).toEqual(["burnbar.health", "burnbar.runs", "burnbar.runDetail"]);
    expect(registeredWebviewProviders.has("burnbar.panel")).toBe(true);
    expect(Array.from(registeredCommands.keys())).toEqual([
      "burnbar.private.workspace.rpc",
      "burnbar.reconnect",
      "burnbar.refresh",
      "burnbar.repairDaemon",
      "burnbar.startRun",
      "burnbar.cancelRun",
      "burnbar.retryRun",
      "burnbar.approveRun",
      "burnbar.rejectRun",
      "burnbar.openWorkspace",
      "burnbar.openConversationSearch"
    ]);
    expect(context.subscriptions.length).toBeGreaterThanOrEqual(7);
  });

  it("surfaces repair failures through the warning channel", async () => {
    const { activateBurnBarExtension } = await import("../src/extension");

    const context = {
      subscriptions: [] as Array<{ dispose(): void }>,
      globalState: {
        get: () => undefined,
        update: () => Promise.resolve()
      }
    };
    await activateBurnBarExtension(context as never, {
      controllerDependencies: {
        client: {
          health: vi.fn().mockResolvedValue({
            ok: true,
            daemonVersion: "0.1.0",
            protocolVersion: 1,
            socketPath: "/tmp/burnbar.sock"
          }),
          catalog: vi.fn().mockResolvedValue({
            schemaVersion: 1,
            providers: []
          }),
          config: vi.fn().mockResolvedValue({ providers: [] }),
          recentUsage: vi.fn().mockResolvedValue([]),
          attach: vi.fn().mockResolvedValue({
            attachedClientID: "test-client",
            negotiatedProtocolVersion: 1
          }),
          detach: vi.fn().mockResolvedValue({
            activeClientID: "test-client",
            attachedClientIDs: ["test-client"]
          }),
          createRun: vi.fn(),
          listRuns: vi.fn().mockResolvedValue([]),
          pollRuns: vi.fn().mockResolvedValue({
            runs: [],
            approvals: [],
            pendingToolCalls: [],
            arbitration: {
              activeClientID: "test-client",
              attachedClientIDs: ["test-client"]
            },
            emittedAt: "2026-03-22T10:00:00.000Z"
          }),
          getRun: vi.fn().mockResolvedValue({ run: null, approvalRequest: null, arbitration: null }),
          cancelRun: vi.fn().mockResolvedValue({ run: null, approvalRequest: null, arbitration: null }),
          retryRun: vi.fn().mockResolvedValue({ run: null, approvalRequest: null, arbitration: null }),
          executeTool: vi.fn().mockResolvedValue({ disposition: "no_pending_tool_call" }),
          submitToolResult: vi.fn().mockResolvedValue({ run: null, approvalRequest: null, arbitration: null }),
          respondToApproval: vi.fn().mockResolvedValue({ run: null, approvalRequest: null, arbitration: null })
        },
        repairService: {
          repair: vi.fn().mockRejectedValue(new Error("launchctl failed"))
        },
        workspaceClient: {
          capabilities: vi.fn().mockResolvedValue({
            hasWorkspace: true,
            localWorkspace: true,
            remoteWorkspace: false,
            readonlyWorkspace: false,
            virtualWorkspace: false,
            untrustedWorkspace: false,
            workspaceHost: "ui",
            availableTools: ["read_file", "search_workspace", "apply_patch", "run_terminal"],
            gatedTools: [],
            explanation: "Workspace tools are running in the local extension host. All PR6 workspace tools are available."
          })
        }
      },
      autoRefreshIntervalMs: 0,
      extensionKind: 1,
      remoteName: undefined
    });

    await registeredCommands.get("burnbar.repairDaemon")?.();
    expect(warningMessages).toContain("launchctl failed");
  });

  it("skips local companion registration on the remote UI host", async () => {
    const { activateBurnBarExtension } = await import("../src/extension");

    const context = {
      subscriptions: [] as Array<{ dispose(): void }>,
      globalState: {
        get: () => undefined,
        update: () => Promise.resolve()
      }
    };
    await activateBurnBarExtension(context as never, {
      controllerDependencies: {
        client: {
          health: vi.fn().mockResolvedValue({
            ok: true,
            daemonVersion: "0.1.0",
            protocolVersion: 1,
            socketPath: "/tmp/burnbar.sock"
          }),
          catalog: vi.fn().mockResolvedValue({
            schemaVersion: 1,
            providers: []
          }),
          config: vi.fn().mockResolvedValue({ providers: [] }),
          recentUsage: vi.fn().mockResolvedValue([]),
          attach: vi.fn().mockResolvedValue({
            attachedClientID: "test-client",
            negotiatedProtocolVersion: 1
          }),
          detach: vi.fn().mockResolvedValue({
            activeClientID: "test-client",
            attachedClientIDs: ["test-client"]
          }),
          createRun: vi.fn(),
          listRuns: vi.fn().mockResolvedValue([]),
          pollRuns: vi.fn().mockResolvedValue({
            runs: [],
            approvals: [],
            pendingToolCalls: [],
            arbitration: {
              activeClientID: "test-client",
              attachedClientIDs: ["test-client"]
            },
            emittedAt: "2026-03-22T10:00:00.000Z"
          }),
          getRun: vi.fn().mockResolvedValue({ run: null, approvalRequest: null, arbitration: null }),
          cancelRun: vi.fn().mockResolvedValue({ run: null, approvalRequest: null, arbitration: null }),
          retryRun: vi.fn().mockResolvedValue({ run: null, approvalRequest: null, arbitration: null }),
          executeTool: vi.fn().mockResolvedValue({ disposition: "no_pending_tool_call" }),
          submitToolResult: vi.fn().mockResolvedValue({ run: null, approvalRequest: null, arbitration: null }),
          respondToApproval: vi.fn().mockResolvedValue({ run: null, approvalRequest: null, arbitration: null })
        },
        repairService: {
          repair: vi.fn().mockResolvedValue({
            message: "BurnBar daemon restart requested."
          })
        },
        workspaceClient: {
          capabilities: vi.fn().mockResolvedValue({
            hasWorkspace: true,
            localWorkspace: false,
            remoteWorkspace: true,
            readonlyWorkspace: false,
            virtualWorkspace: false,
            untrustedWorkspace: false,
            workspaceHost: "workspace",
            availableTools: ["read_file", "search_workspace", "apply_patch", "run_terminal"],
            gatedTools: [],
            explanation: "Workspace tools are running on the remote workspace host. All PR6 workspace tools are available."
          })
        }
      },
      autoRefreshIntervalMs: 0,
      extensionKind: 1,
      remoteName: "ssh-remote"
    });

    expect(createdViews).toEqual(["burnbar.health", "burnbar.runs", "burnbar.runDetail"]);
    expect(registeredWebviewProviders.has("burnbar.panel")).toBe(true);
    expect(Array.from(registeredCommands.keys())).toEqual([
      "burnbar.reconnect",
      "burnbar.refresh",
      "burnbar.repairDaemon",
      "burnbar.startRun",
      "burnbar.cancelRun",
      "burnbar.retryRun",
      "burnbar.approveRun",
      "burnbar.rejectRun",
      "burnbar.openWorkspace",
      "burnbar.openConversationSearch"
    ]);
  });

  it("registers only the workspace companion on the workspace host", async () => {
    const { activateBurnBarExtension } = await import("../src/extension");

    const context = {
      extension: {
        extensionKind: 2
      },
      globalState: {
        get: () => undefined,
        update: () => Promise.resolve()
      },
      subscriptions: [] as Array<{ dispose(): void }>
    };
    const result = await activateBurnBarExtension(context as never, {
      extensionKind: 2,
      remoteName: "ssh-remote"
    });

    expect(result).toBeUndefined();
    expect(createdViews).toEqual([]);
    expect(Array.from(registeredCommands.keys())).toEqual(["burnbar.private.workspace.rpc"]);
  });
});
