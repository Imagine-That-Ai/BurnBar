import { describe, expect, it } from "vitest";

import {
  cliLinkPurposeCopy,
  isCompleteCliLinkCode,
  normalizeCliLinkCode,
  parseCliLinkFlow
} from "../src/lib/cliLinkFlow";

describe("CLI link purpose", () => {
  it("preserves the legacy Remote MCP default", () => {
    expect(parseCliLinkFlow([])).toBe("remote_mcp");
  });

  it("accepts only known authorization purposes", () => {
    expect(parseCliLinkFlow(["remote_mcp"])).toBe("remote_mcp");
    expect(parseCliLinkFlow(["desktop_auth"])).toBe("desktop_auth");
    expect(parseCliLinkFlow(["desktop-auth"])).toBeUndefined();
    expect(parseCliLinkFlow(["REMOTE_MCP"])).toBeUndefined();
    expect(parseCliLinkFlow([""])).toBeUndefined();
  });

  it("rejects duplicate flow parameters and the deprecated purpose query key", () => {
    expect(parseCliLinkFlow(["desktop_auth", "desktop_auth"])).toBeUndefined();
    expect(parseCliLinkFlow(["desktop_auth"], true)).toBeUndefined();
    expect(parseCliLinkFlow([], true)).toBeUndefined();
  });

  it("uses explicit Linux authorization copy for desktop auth", () => {
    const copy = cliLinkPurposeCopy("desktop_auth");
    expect(copy.heading).toContain("OpenBurnBar Linux");
    expect(copy.description).toContain("Approve only if you started this sign-in");
    expect(copy.confirmLabel).toContain("Linux app");
  });
});

describe("CLI link code normalization", () => {
  it("normalizes valid codes to the server wire format", () => {
    expect(normalizeCliLinkCode("abcd-mq23")).toBe("ABCD-MQ23");
    expect(normalizeCliLinkCode("ABCDMQ23")).toBe("ABCD-MQ23");
    expect(isCompleteCliLinkCode("ABCD-MQ23")).toBe(true);
  });

  it("drops ambiguous characters and rejects incomplete codes", () => {
    expect(normalizeCliLinkCode("A1B0-CILO")).toBe("ABC");
    expect(isCompleteCliLinkCode("ABC")).toBe(false);
  });
});
