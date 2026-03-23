import * as assert from "node:assert/strict";

import { detectWorkspaceCapabilities } from "../../../src/workspace/capabilities";
import { projectRuns } from "../../../src/state/projections";

suite("BurnBar extension host workspace modes", () => {
  test("projects remote workspace routing when the companion runs on a workspace host", () => {
    const capabilities = detectWorkspaceCapabilities({
      hostKind: "workspace",
      remoteName: "ssh-remote",
      isTrusted: true,
      workspaceFolders: [
        {
          uri: {
            scheme: "file",
            fsPath: "/remote-workspace",
            toString: () => "file:///remote-workspace"
          }
        }
      ],
      isWritableFileSystem: () => true
    });

    assert.equal(capabilities.remoteWorkspace, true);
    assert.equal(capabilities.workspaceHost, "workspace");
    assert.ok(capabilities.availableTools.includes("run_terminal"));

    const runs = projectRuns({
      connectionStatus: "connected",
      clientAttached: true,
      health: {
        ok: true,
        daemonVersion: "0.1.0",
        protocolVersion: 1,
        socketPath: "/tmp/burnbar.sock"
      },
      catalog: {
        schemaVersion: 1,
        providers: []
      },
      daemonRuns: [],
      pendingToolCalls: [],
      recentUsage: [],
      workspace: capabilities,
      workspaceError: undefined,
      lastError: undefined,
      runError: undefined
    });

    assert.equal(runs[0]?.title, "No runs yet");
    assert.equal(runs[0]?.phase, "idle");
  });

  test("projects approval gating for restricted workspaces", () => {
    const capabilities = detectWorkspaceCapabilities({
      hostKind: "workspace",
      remoteName: "ssh-remote",
      isTrusted: false,
      workspaceFolders: [
        {
          uri: {
            scheme: "file",
            fsPath: "/restricted-workspace",
            toString: () => "file:///restricted-workspace"
          }
        }
      ],
      isWritableFileSystem: () => true
    });

    assert.deepEqual(capabilities.gatedTools, ["apply_patch", "run_terminal"]);

    const runs = projectRuns({
      connectionStatus: "connected",
      clientAttached: true,
      health: {
        ok: true,
        daemonVersion: "0.1.0",
        protocolVersion: 1,
        socketPath: "/tmp/burnbar.sock"
      },
      catalog: {
        schemaVersion: 1,
        providers: []
      },
      daemonRuns: [],
      pendingToolCalls: [],
      recentUsage: [],
      workspace: capabilities,
      workspaceError: undefined,
      lastError: undefined,
      runError: undefined
    });

    assert.equal(runs[0]?.title, "No runs yet");
    assert.equal(runs[0]?.phase, "idle");
    assert.match(runs[0]?.note ?? "", /providers|Start Run/u);
  });
});
