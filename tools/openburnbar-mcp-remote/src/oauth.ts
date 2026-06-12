import { execFileSync } from "node:child_process";
import { mkdirSync, readFileSync, writeFileSync, chmodSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";

const SERVICE = "com.openburnbar.mcp-remote";
const ACCOUNT = "default";
const REFRESH_ACCOUNT = "refresh";
const MAX_TOKEN_LENGTH = 8192;

function validatedTokenForStorage(token: string): string {
  const trimmed = token.trim();
  if (!trimmed || trimmed.length > MAX_TOKEN_LENGTH || /[\r\n\0]/u.test(trimmed)) {
    throw new Error("OpenBurnBar MCP access token is empty, too large, or contains control characters.");
  }
  return trimmed;
}

function fallbackPath(suffix = ""): string {
  const dir = join(homedir(), ".openburnbar");
  mkdirSync(dir, { recursive: true });
  return join(dir, `mcp-remote-token${suffix}`);
}

function readSecret(account: string, suffix: string, envOverride?: string): string | undefined {
  if (envOverride) return envOverride;
  if (process.platform === "darwin") {
    try {
      return execFileSync("security", ["find-generic-password", "-s", SERVICE, "-a", account, "-w"], { encoding: "utf8" }).trim();
    } catch {
      // Fall through to the local 0600 fallback for CI and non-interactive installs.
    }
  }
  try {
    const value = readFileSync(fallbackPath(suffix), "utf8").trim();
    return value || undefined;
  } catch {
    return undefined;
  }
}

function writeSecret(account: string, suffix: string, token: string): void {
  const safeToken = validatedTokenForStorage(token);
  if (process.platform === "darwin") {
    try {
      execFileSync("security", ["add-generic-password", "-U", "-s", SERVICE, "-a", account, "-w", safeToken], { stdio: "ignore" });
      return;
    } catch {
      // Use the fallback path only when Keychain is unavailable.
    }
  }
  const path = fallbackPath(suffix);
  writeFileSync(path, `${safeToken}\n`, { mode: 0o600 });
  chmodSync(path, 0o600);
}

export function readAccessToken(): string | undefined {
  return readSecret(ACCOUNT, "", process.env.OPENBURNBAR_MCP_ACCESS_TOKEN);
}

export function writeAccessToken(token: string): void {
  writeSecret(ACCOUNT, "", token);
}

export function readRefreshToken(): string | undefined {
  return readSecret(REFRESH_ACCOUNT, "-refresh", process.env.OPENBURNBAR_MCP_REFRESH_TOKEN);
}

export function writeRefreshToken(token: string): void {
  writeSecret(REFRESH_ACCOUNT, "-refresh", token);
}
