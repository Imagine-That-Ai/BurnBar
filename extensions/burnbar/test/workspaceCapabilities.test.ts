import { describe, expect, it } from "vitest";

import { detectWorkspaceCapabilities } from "../src/workspace/capabilities";

describe("detectWorkspaceCapabilities", () => {
  it("reports a local trusted writable workspace", () => {
    const capabilities = detectWorkspaceCapabilities({
      hostKind: "ui",
      remoteName: undefined,
      isTrusted: true,
      workspaceFolders: [
        {
          uri: {
            scheme: "file",
            fsPath: "/workspace",
            toString: () => "file:///workspace"
          }
        }
      ],
      isWritableFileSystem: () => true
    });

    expect(capabilities).toMatchObject({
      localWorkspace: true,
      remoteWorkspace: false,
      readonlyWorkspace: false,
      virtualWorkspace: false,
      untrustedWorkspace: false,
      availableTools: ["read_file", "search_workspace", "apply_patch", "run_terminal"],
      gatedTools: []
    });
  });

  it("reports remote restricted virtual workspaces with gated tools", () => {
    const capabilities = detectWorkspaceCapabilities({
      hostKind: "workspace",
      remoteName: "ssh-remote",
      isTrusted: false,
      workspaceFolders: [
        {
          uri: {
            scheme: "memfs",
            fsPath: "/workspace",
            toString: () => "memfs:/workspace"
          }
        }
      ],
      isWritableFileSystem: () => false
    });

    expect(capabilities).toMatchObject({
      localWorkspace: false,
      remoteWorkspace: true,
      readonlyWorkspace: true,
      virtualWorkspace: true,
      untrustedWorkspace: true,
      availableTools: ["read_file", "search_workspace"],
      gatedTools: ["apply_patch", "run_terminal"]
    });
    expect(capabilities.explanation).toContain("restricted mode");
    expect(capabilities.explanation).toContain("virtual filesystem");
  });

  it("explains the empty workspace state", () => {
    const capabilities = detectWorkspaceCapabilities({
      hostKind: "ui",
      remoteName: undefined,
      isTrusted: true,
      workspaceFolders: [],
      isWritableFileSystem: () => true
    });

    expect(capabilities).toMatchObject({
      hasWorkspace: false,
      localWorkspace: false,
      remoteWorkspace: false,
      availableTools: [],
      gatedTools: []
    });
    expect(capabilities.explanation).toBe(
      "Open a workspace folder to enable BurnBar file, search, edit, and terminal tools."
    );
  });
});
