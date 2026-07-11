export type CliLinkPurpose = "remote_mcp" | "desktop_auth";

export type CliLinkPurposeCopy = {
  pageTitle: string;
  heading: string;
  description: string;
  codeHelp: string;
  confirmLabel: string;
  progressHeading: string;
  progressDescription: string;
  successHeading: string;
  successDescription: string;
  returnInstruction: string;
};

const PURPOSE_COPY: Record<CliLinkPurpose, CliLinkPurposeCopy> = {
  remote_mcp: {
    pageTitle: "Authorize Remote MCP",
    heading: "Authorize Remote MCP",
    description:
      "Approve this one-time code to connect the Remote MCP client that you just started.",
    codeHelp: "Enter the 8-character code shown by the Remote MCP client.",
    confirmLabel: "Authorize Remote MCP",
    progressHeading: "Authorizing Remote MCP",
    progressDescription: "Preparing an encrypted, device-bound credential envelope.",
    successHeading: "Remote MCP authorized",
    successDescription: "The client can now finish the encrypted credential handoff.",
    returnInstruction: "Return to the Remote MCP client to complete setup."
  },
  desktop_auth: {
    pageTitle: "Sign in to OpenBurnBar Linux",
    heading: "Sign in to OpenBurnBar Linux",
    description:
      "Approve only if you started this sign-in from the OpenBurnBar Linux desktop app. The code grants that app access to your BurnBar account.",
    codeHelp: "Confirm the 8-character code shown in the Linux app.",
    confirmLabel: "Authorize Linux app",
    progressHeading: "Authorizing Linux app",
    progressDescription: "Preparing a one-time, device-bound sign-in credential.",
    successHeading: "Linux app authorized",
    successDescription:
      "Your account credential was encrypted for the Linux app that started this flow.",
    returnInstruction: "Return to OpenBurnBar on Linux to finish signing in."
  }
};

export function parseCliLinkFlow(
  rawValues: readonly string[],
  hasDeprecatedPurposeParameter = false
): CliLinkPurpose | undefined {
  if (hasDeprecatedPurposeParameter || rawValues.length > 1) return undefined;
  if (rawValues.length === 0) return "remote_mcp";
  const raw = rawValues[0];
  return raw === "remote_mcp" || raw === "desktop_auth" ? raw : undefined;
}

export function normalizeCliLinkCode(raw: string): string {
  const compact = raw
    .toUpperCase()
    .split("")
    .filter((character) => /^[A-HJ-KM-NP-Z2-9]$/u.test(character))
    .join("")
    .slice(0, 8);
  return compact.length > 4 ? `${compact.slice(0, 4)}-${compact.slice(4)}` : compact;
}

export function isCompleteCliLinkCode(code: string): boolean {
  return /^[A-HJ-KM-NP-Z2-9]{4}-[A-HJ-KM-NP-Z2-9]{4}$/u.test(code);
}

export function cliLinkPurposeCopy(purpose: CliLinkPurpose): CliLinkPurposeCopy {
  return PURPOSE_COPY[purpose];
}
