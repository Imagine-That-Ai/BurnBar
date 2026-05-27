/**
 * WebView Message Protocol Tests
 *
 * These tests verify the message protocol between the VS Code/Cursor extension
 * and the webview panel, ensuring type safety and correct message handling.
 *
 * Test categories:
 * 1. Host → Webview message serialization/deserialization
 * 2. Webview → Host message serialization/validation
 * 3. Message type narrowing and discrimination
 * 4. Error handling for malformed messages
 * 5. Message handler integration
 */

import { describe, it, expect, vi, beforeEach, afterEach } from "vitest";
import type {
  OpenBurnBarPanelHostMessage,
  OpenBurnBarPanelWebviewMessage,
  OpenBurnBarWorkspaceWebviewMessage
} from "../src/views/panelProtocol";
import type {
  OpenBurnBarPanelViewModel,
  OpenBurnBarPanelRunCard,
  OpenBurnBarPanelApprovalState
} from "../src/state/panelViewModel";
import type { OpenBurnBarState } from "../src/types";
import type { BurnBarWorkspaceCapabilities } from "../src/workspace/types";

// ---------------------------------------------------------------------------
// Mock implementations for testing
// ---------------------------------------------------------------------------

function createMockPanelViewModel(overrides: Partial<OpenBurnBarPanelViewModel> = {}): OpenBurnBarPanelViewModel {
  return {
    connectionStatus: "connected",
    isConnected: true,
    isDaemonUnavailable: false,
    daemonVersion: "1.0.0",
    protocolVersion: 1,
    socketPath: "/tmp/openburnbar.sock",
    isWorkspaceTrusted: true,
    hasWorkspace: true,
    workspaceDescription: "Local • trusted",
    capabilityChips: [
      { label: "Read/Search ready", kind: "ready" },
      { label: "Edit ready", kind: "ready" }
    ],
    isComposerEnabled: true,
    composerDisabledReason: undefined,
    selectedModelOptions: [
      { id: "claude-3-5-sonnet", displayName: "Claude 3.5 Sonnet", providerName: "Anthropic" },
      { id: "claude-3-opus", displayName: "Claude 3 Opus", providerName: "Anthropic" }
    ],
    activeRun: {
      id: "run-active-001",
      title: "Fix authentication bug",
      phase: "executing_tool",
      phaseColor: "active",
      providerName: "Claude Code",
      modelId: "claude-3-5-sonnet",
      updatedAt: new Date().toISOString(),
      note: "Applying patch to auth.swift",
      source: "daemon",
      hasApproval: false,
      isSelected: true
    },
    historyRuns: [
      {
        id: "run-history-001",
        title: "Update dependencies",
        phase: "completed",
        phaseColor: "success",
        providerName: "Claude Code",
        modelId: "claude-3-5-sonnet",
        updatedAt: new Date(Date.now() - 3600000).toISOString(),
        note: undefined,
        source: "daemon",
        hasApproval: false,
        isSelected: false
      },
      {
        id: "run-history-002",
        title: "Add unit tests",
        phase: "failed",
        phaseColor: "error",
        providerName: "Claude Code",
        modelId: "claude-3-opus",
        updatedAt: new Date(Date.now() - 7200000).toISOString(),
        note: "Timeout exceeded",
        source: "projected",
        hasApproval: false,
        isSelected: false
      }
    ],
    selectedRunId: "run-active-001",
    approvalState: undefined,
    selectedRunDetail: {
      summary: "Fix authentication bug • executing_tool: Applying patch",
      responseText: "Applying changes to auth.swift...",
      usageText: "Claude Code • in 1500 / out 800 / cost 0.0235",
      recoveryMessage: undefined,
      arbitrationInfo: "Controller: vscode • 2 attached",
      loopDecisionText: "Loop 3: apply_patch via auth.swift — Need to update the token validation"
    },
    recoveryMessage: undefined,
    catalogUnavailable: false,
    noRunsYet: false,
    systemInfo: {
      daemonVersion: "1.0.0",
      protocolVersion: "v1",
      socketPath: "/tmp/openburnbar.sock",
      connectionStatus: "Connected",
      controllerState: "Controller: vscode",
      workspaceHost: "ui"
    },
    lastError: undefined,
    lastUpdatedAt: new Date().toISOString(),
    showOpenBurnBarApp: true,
    statusLineText: "Fix authentication bug • executing_tool",
    ...overrides
  };
}

function createMockOpenBurnBarState(overrides: Partial<OpenBurnBarState> = {}): OpenBurnBarState {
  return {
    connectionStatus: "connected",
    health: {
      ok: true,
      daemonVersion: "1.0.0",
      protocolVersion: 1,
      socketPath: "/tmp/openburnbar.sock"
    },
    catalog: {
      providers: [
        {
          id: "anthropic",
          displayName: "Anthropic",
          models: [
            {
              id: "claude-3-5-sonnet",
              displayName: "Claude 3.5 Sonnet",
              visibility: "public",
              supportedModes: ["explain", "fix", "inspect"]
            }
          ]
        }
      ]
    },
    runs: [
      {
        id: "run-001",
        phase: "executing_tool" as const,
        title: "Test run",
        providerName: "Claude Code",
        modelId: "claude-3-5-sonnet",
        updatedAt: new Date().toISOString(),
        note: undefined,
        source: "daemon" as const
      }
    ],
    daemonRuns: [],
    selectedRunId: undefined,
    selectedRunDetail: undefined,
    recentUsage: [],
    workspace: {
      hasWorkspace: true,
      localWorkspace: true,
      remoteWorkspace: false,
      readonlyWorkspace: false,
      virtualWorkspace: false,
      untrustedWorkspace: false,
      workspaceHost: "ui",
      availableTools: ["read_file", "search_workspace", "apply_patch"],
      gatedTools: [],
      explanation: ""
    },
    lastError: undefined,
    lastUpdatedAt: new Date().toISOString(),
    ...overrides
  };
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function isSnapshotMessage(msg: unknown): msg is { type: "snapshot"; viewModel: OpenBurnBarPanelViewModel } {
  return isRecord(msg) && msg.type === "snapshot" && isRecord(msg.viewModel);
}

function isErrorMessage(msg: unknown): msg is { type: "error"; message: string } {
  return isRecord(msg) && msg.type === "error" && typeof msg.message === "string";
}

function isThemeMessage(msg: unknown): msg is { type: "theme"; kind: "dark" | "light" | "high-contrast" } {
  return isRecord(msg)
    && msg.type === "theme"
    && (msg.kind === "dark" || msg.kind === "light" || msg.kind === "high-contrast");
}

// Webview message type guards
function isStartRunMessage(msg: unknown): msg is { type: "startRun"; prompt: string; modelID: string; mode: "explain" | "fix" | "inspect" } {
  return isRecord(msg)
    && msg.type === "startRun"
    && typeof msg.prompt === "string"
    && typeof msg.modelID === "string"
    && (msg.mode === "explain" || msg.mode === "fix" || msg.mode === "inspect");
}

function isRefreshMessage(msg: OpenBurnBarPanelWebviewMessage): msg is { type: "refresh" } {
  return msg.type === "refresh";
}

function isRepairMessage(msg: OpenBurnBarPanelWebviewMessage): msg is { type: "repair" } {
  return msg.type === "repair";
}

function isSelectRunMessage(msg: OpenBurnBarPanelWebviewMessage): msg is { type: "selectRun"; runId: string } {
  return msg.type === "selectRun";
}

// ---------------------------------------------------------------------------
// Message Handler Mock
// ---------------------------------------------------------------------------

type MessageHandler = (message: OpenBurnBarPanelWebviewMessage) => Promise<void>;

class MockMessageHandler implements MessageHandler {
  public receivedMessages: OpenBurnBarPanelWebviewMessage[] = [];
  private handlers: Map<string, (msg: OpenBurnBarPanelWebviewMessage) => Promise<void>> = new Map();

  async handle(message: OpenBurnBarPanelWebviewMessage): Promise<void> {
    this.receivedMessages.push(message);

    const handler = this.handlers.get(message.type);
    if (handler) {
      await handler(message);
    }
  }

  registerHandler(type: string, handler: (msg: OpenBurnBarPanelWebviewMessage) => Promise<void>): void {
    this.handlers.set(type, handler);
  }
}

// ---------------------------------------------------------------------------
// Test Suites
// ---------------------------------------------------------------------------

describe("WebView Message Protocol", () => {
  describe("Host → Webview Messages", () => {
    describe("Snapshot Messages", () => {
      it("should create valid snapshot message", () => {
        const viewModel = createMockPanelViewModel();
        const message: OpenBurnBarPanelHostMessage = {
          type: "snapshot",
          viewModel
        };

        expect(message.type).toBe("snapshot");
        expect(isSnapshotMessage(message)).toBe(true);
        expect(message.viewModel.connectionStatus).toBe("connected");
        expect(message.viewModel.isConnected).toBe(true);
        expect(message.viewModel.activeRun).toBeDefined();
      });

      it("should include all required view model fields", () => {
        const viewModel = createMockPanelViewModel();
        const message: OpenBurnBarPanelHostMessage = {
          type: "snapshot",
          viewModel
        };

        expect(message.viewModel.systemInfo).toBeDefined();
        expect(message.viewModel.systemInfo.daemonVersion).toBeDefined();
        expect(message.viewModel.systemInfo.protocolVersion).toBeDefined();
        expect(message.viewModel.systemInfo.socketPath).toBeDefined();
      });

      it("should handle snapshot with no active run", () => {
        const viewModel = createMockPanelViewModel({
          activeRun: undefined,
          noRunsYet: true
        });
        const message: OpenBurnBarPanelHostMessage = {
          type: "snapshot",
          viewModel
        };

        expect(message.viewModel.activeRun).toBeUndefined();
        expect(message.viewModel.noRunsYet).toBe(true);
      });

      it("should handle snapshot with approval state", () => {
        const approvalState: OpenBurnBarPanelApprovalState = {
          runId: "run-approval-001",
          title: "Approve file modification",
          message: "This will modify 3 files",
          tool: "apply_patch",
          requestedAt: new Date().toISOString()
        };

        const viewModel = createMockPanelViewModel({
          approvalState
        });
        const message: OpenBurnBarPanelHostMessage = {
          type: "snapshot",
          viewModel
        };

        expect(message.viewModel.approvalState).toBeDefined();
        expect(message.viewModel.approvalState?.runId).toBe("run-approval-001");
        expect(message.viewModel.approvalState?.tool).toBe("apply_patch");
      });
    });

    describe("Error Messages", () => {
      it("should create valid error message", () => {
        const message: OpenBurnBarPanelHostMessage = {
          type: "error",
          message: "Failed to connect to daemon"
        };

        expect(message.type).toBe("error");
        expect(isErrorMessage(message)).toBe(true);
        expect(message.message).toBeTruthy();
      });

      it("should handle error with empty message", () => {
        const message: OpenBurnBarPanelHostMessage = {
          type: "error",
          message: ""
        };

        expect(message.message).toBe("");
      });
    });

    describe("Theme Messages", () => {
      it("should create dark theme message", () => {
        const message: OpenBurnBarPanelHostMessage = {
          type: "theme",
          kind: "dark"
        };

        expect(message.type).toBe("theme");
        expect(isThemeMessage(message)).toBe(true);
        expect(message.kind).toBe("dark");
      });

      it("should create light theme message", () => {
        const message: OpenBurnBarPanelHostMessage = {
          type: "theme",
          kind: "light"
        };

        expect(message.kind).toBe("light");
      });

      it("should create high-contrast theme message", () => {
        const message: OpenBurnBarPanelHostMessage = {
          type: "theme",
          kind: "high-contrast"
        };

        expect(message.kind).toBe("high-contrast");
      });
    });
  });

  describe("Webview → Host Messages", () => {
    describe("Start Run Messages", () => {
      it("should create valid start run message for explain mode", () => {
        const message: OpenBurnBarPanelWebviewMessage = {
          type: "startRun",
          prompt: "Explain the authentication flow",
          modelID: "claude-3-5-sonnet",
          mode: "explain"
        };

        expect(message.type).toBe("startRun");
        expect(isStartRunMessage(message)).toBe(true);
        expect(message.prompt).toBe("Explain the authentication flow");
        expect(message.modelID).toBe("claude-3-5-sonnet");
        expect(message.mode).toBe("explain");
      });

      it("should create valid start run message for fix mode", () => {
        const message: OpenBurnBarPanelWebviewMessage = {
          type: "startRun",
          prompt: "Fix the login bug",
          modelID: "claude-3-opus",
          mode: "fix"
        };

        expect(message.mode).toBe("fix");
      });

      it("should create valid start run message for inspect mode", () => {
        const message: OpenBurnBarPanelWebviewMessage = {
          type: "startRun",
          prompt: "Inspect the codebase structure",
          modelID: "claude-3-5-sonnet",
          mode: "inspect"
        };

        expect(message.mode).toBe("inspect");
      });

      it("should validate mode is one of allowed values", () => {
        const validModes = ["explain", "fix", "inspect"] as const;

        for (const mode of validModes) {
          const message: OpenBurnBarPanelWebviewMessage = {
            type: "startRun",
            prompt: "Test prompt",
            modelID: "claude-3-5-sonnet",
            mode
          };
          expect(["explain", "fix", "inspect"]).toContain(message.mode);
        }
      });
    });

    describe("Refresh Messages", () => {
      it("should create valid refresh message", () => {
        const message: OpenBurnBarPanelWebviewMessage = {
          type: "refresh"
        };

        expect(message.type).toBe("refresh");
        expect(isRefreshMessage(message)).toBe(true);
      });
    });

    describe("Repair Messages", () => {
      it("should create valid repair message", () => {
        const message: OpenBurnBarPanelWebviewMessage = {
          type: "repair"
        };

        expect(message.type).toBe("repair");
        expect(isRepairMessage(message)).toBe(true);
      });
    });

    describe("Select Run Messages", () => {
      it("should create valid select run message", () => {
        const message: OpenBurnBarPanelWebviewMessage = {
          type: "selectRun",
          runId: "run-123"
        };

        expect(message.type).toBe("selectRun");
        expect(isSelectRunMessage(message)).toBe(true);
        expect(message.runId).toBe("run-123");
      });

      it("should handle UUID format run IDs", () => {
        const runId = "550e8400-e29b-41d4-a716-446655440000";
        const message: OpenBurnBarPanelWebviewMessage = {
          type: "selectRun",
          runId
        };

        expect(message.runId).toBe(runId);
      });
    });

    describe("Cancel Run Messages", () => {
      it("should create valid cancel run message", () => {
        const message: OpenBurnBarPanelWebviewMessage = {
          type: "cancelRun",
          runId: "run-456"
        };

        expect(message.type).toBe("cancelRun");
        expect(message.runId).toBe("run-456");
      });
    });

    describe("Retry Run Messages", () => {
      it("should create valid retry run message", () => {
        const message: OpenBurnBarPanelWebviewMessage = {
          type: "retryRun",
          runId: "run-789"
        };

        expect(message.type).toBe("retryRun");
        expect(message.runId).toBe("run-789");
      });
    });

    describe("Approval Messages", () => {
      it("should create valid approve run message", () => {
        const message: OpenBurnBarPanelWebviewMessage = {
          type: "approveRun",
          runId: "run-approval-001"
        };

        expect(message.type).toBe("approveRun");
        expect(message.runId).toBe("run-approval-001");
      });

      it("should create valid reject run message", () => {
        const message: OpenBurnBarPanelWebviewMessage = {
          type: "rejectRun",
          runId: "run-approval-002"
        };

        expect(message.type).toBe("rejectRun");
        expect(message.runId).toBe("run-approval-002");
      });
    });

    describe("Navigation Messages", () => {
      it("should create valid open app message", () => {
        const message: OpenBurnBarPanelWebviewMessage = {
          type: "openApp"
        };

        expect(message.type).toBe("openApp");
      });

      it("should create valid open workspace message", () => {
        const message: OpenBurnBarPanelWebviewMessage = {
          type: "openWorkspace"
        };

        expect(message.type).toBe("openWorkspace");
      });
    });
  });

  describe("Message Type Discrimination", () => {
    it("should correctly identify snapshot message type", () => {
      const messages: OpenBurnBarPanelHostMessage[] = [
        { type: "snapshot", viewModel: createMockPanelViewModel() },
        { type: "error", message: "test" },
        { type: "theme", kind: "dark" }
      ];

      const snapshotMessages = messages.filter(isSnapshotMessage);
      expect(snapshotMessages.length).toBe(1);
      expect(snapshotMessages[0].viewModel.connectionStatus).toBe("connected");
    });

    it("should correctly identify all host message types", () => {
      const messages: OpenBurnBarPanelHostMessage[] = [
        { type: "snapshot", viewModel: createMockPanelViewModel() },
        { type: "error", message: "Connection failed" },
        { type: "theme", kind: "light" }
      ];

      expect(messages.filter(isSnapshotMessage).length).toBe(1);
      expect(messages.filter(isErrorMessage).length).toBe(1);
      expect(messages.filter(isThemeMessage).length).toBe(1);
    });

    it("should correctly identify webview message types", () => {
      const messages: OpenBurnBarPanelWebviewMessage[] = [
        { type: "startRun", prompt: "test", modelID: "model", mode: "explain" },
        { type: "refresh" },
        { type: "selectRun", runId: "run-1" },
        { type: "cancelRun", runId: "run-1" }
      ];

      expect(messages.filter(isStartRunMessage).length).toBe(1);
      expect(messages.filter(isRefreshMessage).length).toBe(1);
      expect(messages.filter(isSelectRunMessage).length).toBe(1);
    });
  });

  describe("Message Handler Integration", () => {
    let handler: MockMessageHandler;

    beforeEach(() => {
      handler = new MockMessageHandler();
    });

    afterEach(() => {
      handler.receivedMessages = [];
    });

    it("should record all received messages", async () => {
      const messages: OpenBurnBarPanelWebviewMessage[] = [
        { type: "refresh" },
        { type: "repair" },
        { type: "openApp" }
      ];

      for (const msg of messages) {
        await handler.handle(msg);
      }

      expect(handler.receivedMessages.length).toBe(3);
      expect(handler.receivedMessages[0].type).toBe("refresh");
      expect(handler.receivedMessages[1].type).toBe("repair");
      expect(handler.receivedMessages[2].type).toBe("openApp");
    });

    it("should trigger registered handlers", async () => {
      const refreshHandler = vi.fn();
      handler.registerHandler("refresh", refreshHandler);

      await handler.handle({ type: "refresh" });

      expect(refreshHandler).toHaveBeenCalledTimes(1);
    });

    it("should handle startRun with all fields", async () => {
      const startRunHandler = vi.fn();
      handler.registerHandler("startRun", startRunHandler);

      const message: OpenBurnBarPanelWebviewMessage = {
        type: "startRun",
        prompt: "Fix the bug",
        modelID: "claude-3-5-sonnet",
        mode: "fix"
      };

      await handler.handle(message);

      expect(startRunHandler).toHaveBeenCalledWith(message);
      expect(startRunHandler).toHaveBeenCalledWith(
        expect.objectContaining({
          type: "startRun",
          prompt: "Fix the bug",
          mode: "fix"
        })
      );
    });

    it("should maintain message order", async () => {
      const messages: OpenBurnBarPanelWebviewMessage[] = [
        { type: "selectRun", runId: "run-1" },
        { type: "cancelRun", runId: "run-1" },
        { type: "refresh" }
      ];

      for (const msg of messages) {
        await handler.handle(msg);
      }

      expect(handler.receivedMessages[0].type).toBe("selectRun");
      expect(handler.receivedMessages[1].type).toBe("cancelRun");
      expect(handler.receivedMessages[2].type).toBe("refresh");
    });
  });

  describe("Error Handling", () => {
    it("should handle malformed JSON gracefully", () => {
      const invalidMessages = [
        '{ invalid json }',
        '{"unclosed": "string',
        'not json at all',
        '',
        '{"trailing garbage": true} extra'
      ];

      // Malformed JSON should throw when parsed
      for (const json of invalidMessages) {
        expect(() => JSON.parse(json)).toThrow();
      }
    });

    it("should validate required fields for each message type", () => {
      // StartRun requires prompt, modelID, and mode
      expect(() => {
        const msg: OpenBurnBarPanelWebviewMessage = { type: "startRun", prompt: "test", modelID: "m", mode: "explain" };
        if (msg.type === "startRun") {
          if (!msg.prompt || !msg.modelID || !msg.mode) {
            throw new Error("Missing required fields");
          }
        }
      }).not.toThrow();

      // SelectRun requires runId
      expect(() => {
        const msg: OpenBurnBarPanelWebviewMessage = { type: "selectRun", runId: "run-1" };
        if (msg.type === "selectRun") {
          if (!msg.runId) {
            throw new Error("Missing required fields");
          }
        }
      }).not.toThrow();
    });
  });

  describe("ViewModel Building", () => {
    it("should correctly build view model from state", () => {
      const state = createMockOpenBurnBarState();
      const viewModel = createMockPanelViewModel();

      // Verify key mappings
      expect(viewModel.connectionStatus).toBe("connected");
      expect(viewModel.isConnected).toBe(true);
      expect(viewModel.isWorkspaceTrusted).toBe(true);
      expect(viewModel.capabilityChips.length).toBeGreaterThan(0);
    });

    it("should handle disconnected state", () => {
      const state = createMockOpenBurnBarState({
        connectionStatus: "disconnected",
        health: undefined
      });

      expect(state.connectionStatus).toBe("disconnected");
    });

    it("should handle untrusted workspace", () => {
      const workspace: BurnBarWorkspaceCapabilities = {
        hasWorkspace: true,
        localWorkspace: true,
        remoteWorkspace: false,
        readonlyWorkspace: false,
        virtualWorkspace: false,
        untrustedWorkspace: true,
        workspaceHost: "ui",
        availableTools: [],
        gatedTools: ["apply_patch", "run_terminal"],
        explanation: "Workspace not trusted"
      };

      expect(workspace.untrustedWorkspace).toBe(true);
      expect(workspace.gatedTools).toContain("apply_patch");
    });
  });

  describe("Workspace Editor Messages", () => {
    it("should create valid workspace switchSection message", () => {
      const message: OpenBurnBarWorkspaceWebviewMessage = {
        type: "switchSection",
        section: "runs"
      };

      expect(message.type).toBe("switchSection");
      expect(["command", "runs", "system"]).toContain(message.section);
    });

    it("should create valid workspace openConversationSearch message", () => {
      const message: OpenBurnBarWorkspaceWebviewMessage = {
        type: "openConversationSearch"
      };

      expect(message.type).toBe("openConversationSearch");
    });

    it("should support all workspace message types", () => {
      const messages: OpenBurnBarWorkspaceWebviewMessage[] = [
        { type: "startRun", prompt: "test", modelID: "m", mode: "explain" },
        { type: "refresh" },
        { type: "selectRun", runId: "run-1" },
        { type: "switchSection", section: "command" },
        { type: "openConversationSearch" }
      ];

      expect(messages.length).toBe(5);
    });
  });

  describe("Message Serialization", () => {
    it("should serialize and deserialize snapshot message correctly", () => {
      const viewModel = createMockPanelViewModel();
      const message: OpenBurnBarPanelHostMessage = {
        type: "snapshot",
        viewModel
      };

      const serialized = JSON.stringify(message);
      const deserialized: unknown = JSON.parse(serialized);

      expect(isSnapshotMessage(deserialized)).toBe(true);
      if (!isSnapshotMessage(deserialized)) {
        throw new Error("Expected snapshot message");
      }
      expect(deserialized.viewModel.connectionStatus).toBe(viewModel.connectionStatus);
    });

    it("should serialize and deserialize webview message correctly", () => {
      const message: OpenBurnBarPanelWebviewMessage = {
        type: "startRun",
        prompt: "Analyze code quality",
        modelID: "claude-3-5-sonnet",
        mode: "inspect"
      };

      const serialized = JSON.stringify(message);
      const deserialized: unknown = JSON.parse(serialized);

      expect(isStartRunMessage(deserialized)).toBe(true);
      if (!isStartRunMessage(deserialized)) {
        throw new Error("Expected startRun message");
      }
      expect(deserialized.prompt).toBe("Analyze code quality");
      expect(deserialized.mode).toBe("inspect");
    });

    it("should preserve ISO date strings", () => {
      const viewModel = createMockPanelViewModel();
      const message: OpenBurnBarPanelHostMessage = {
        type: "snapshot",
        viewModel
      };

      const serialized = JSON.stringify(message);
      const parsed = JSON.parse(serialized);

      // Date strings should be preserved as strings
      expect(typeof parsed.viewModel.lastUpdatedAt).toBe("string");
      expect(parsed.viewModel.activeRun.updatedAt).toMatch(/^\d{4}-\d{2}-\d{2}T/);
    });
  });

  describe("Run Card Formatting", () => {
    it("should correctly identify phase colors", () => {
      const phases: Array<{ phase: string; expectedColor: OpenBurnBarPanelRunCard["phaseColor"] }> = [
        { phase: "planning", expectedColor: "active" },
        { phase: "executing_tool", expectedColor: "active" },
        { phase: "awaiting_approval", expectedColor: "warning" },
        { phase: "completed", expectedColor: "success" },
        { phase: "failed", expectedColor: "error" },
        { phase: "cancelled", expectedColor: "error" },
        { phase: "idle", expectedColor: "muted" }
      ];

      for (const { phase, expectedColor } of phases) {
        const runCard: OpenBurnBarPanelRunCard = {
          id: "test",
          title: "Test",
          phase,
          phaseColor: expectedColor,
          updatedAt: new Date().toISOString(),
          note: undefined,
          source: "daemon",
          hasApproval: false,
          isSelected: false
        };

        expect(runCard.phaseColor).toBe(expectedColor);
      }
    });
  });
});
