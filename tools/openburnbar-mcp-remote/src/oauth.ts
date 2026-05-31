import { execFileSync } from "node:child_process";
import { mkdirSync, readFileSync, writeFileSync, chmodSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";

const SERVICE = "com.openburnbar.mcp-remote";
const ACCOUNT = "default";
const MAX_TOKEN_LENGTH = 8192;

function validatedTokenForStorage(token: string): string {
  const trimmed = token.trim();
  if (!trimmed || trimmed.length > MAX_TOKEN_LENGTH || /[\r\n\0]/u.test(trimmed)) {
    throw new Error("OpenBurnBar MCP access token is empty, too large, or contains control characters.");
  }
  return trimmed;
}

function fallbackPath(): string {
  const dir = join(homedir(), ".openburnbar");
  mkdirSync(dir, { recursive: true });
  return join(dir, "mcp-remote-token");
}

export function readAccessToken(): string | undefined {
  if (process.env.OPENBURNBAR_MCP_ACCESS_TOKEN) return process.env.OPENBURNBAR_MCP_ACCESS_TOKEN;
  if (process.platform === "darwin") {
    try {
      return execFileSync("security", ["find-generic-password", "-s", SERVICE, "-a", ACCOUNT, "-w"], { encoding: "utf8" }).trim();
    } catch {
      // Fall through to the local 0600 fallback for CI and non-interactive installs.
    }
  }
  try {
    const value = readFileSync(fallbackPath(), "utf8").trim();
    return value || undefined;
  } catch {
    return undefined;
  }
}

export function writeAccessToken(token: string): void {
  const safeToken = validatedTokenForStorage(token);
  if (process.platform === "darwin") {
    try {
      execFileSync("security", ["add-generic-password", "-U", "-s", SERVICE, "-a", ACCOUNT, "-w", safeToken], { stdio: "ignore" });
      return;
    } catch {
      // Use the fallback path only when Keychain is unavailable.
    }
  }
  const path = fallbackPath();
  writeFileSync(path, `${safeToken}\n`, { mode: 0o600 });
  chmodSync(path, 0o600);
}
