import { execFileSync } from "node:child_process";
import { existsSync, mkdirSync, readFileSync, writeFileSync, chmodSync, rmSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";

const SERVICE = "com.openburnbar.mcp-remote";
const ACCOUNT = "default";
const REFRESH_ACCOUNT = "refresh";
const MAX_TOKEN_LENGTH = 8192;
const ALLOW_INSECURE_TOKEN_SOURCE_ENV = "OPENBURNBAR_ALLOW_INSECURE_MCP_TOKEN_SOURCE";

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

function insecureTokenSourcesAllowed(): boolean {
  return process.env[ALLOW_INSECURE_TOKEN_SOURCE_ENV] === "true";
}

export function legacyTokenPath(suffix = ""): string {
  return join(homedir(), ".openburnbar", `mcp-remote-token${suffix}`);
}

export function removeLegacyTokenFile(suffix = ""): boolean {
  const path = legacyTokenPath(suffix);
  if (!existsSync(path)) return false;
  rmSync(path, { force: true });
  return true;
}

function readSecret(account: string, suffix: string, envOverride?: string): string | undefined {
  if (envOverride && insecureTokenSourcesAllowed()) return validatedTokenForStorage(envOverride);
  if (process.platform === "darwin") {
    try {
      const value = execFileSync("security", ["find-generic-password", "-s", SERVICE, "-a", account, "-w"], { encoding: "utf8" }).trim();
      removeLegacyTokenFile(suffix);
      return value;
    } catch {
      // Production is Keychain-only. Insecure sources below are test/dev opt-ins.
    }
  }
  if (!insecureTokenSourcesAllowed()) return undefined;
  try {
    const value = readFileSync(fallbackPath(suffix), "utf8").trim();
    return value ? validatedTokenForStorage(value) : undefined;
  } catch {
    return undefined;
  }
}

function writeSecret(account: string, suffix: string, token: string): void {
  const safeToken = validatedTokenForStorage(token);
  if (process.platform === "darwin") {
    try {
      execFileSync("security", ["add-generic-password", "-U", "-s", SERVICE, "-a", account, "-w", safeToken], { stdio: "ignore" });
      removeLegacyTokenFile(suffix);
      return;
    } catch {
      if (!insecureTokenSourcesAllowed()) {
        throw new Error("OpenBurnBar MCP token linking requires macOS Keychain. Refusing to write a plaintext fallback token.");
      }
    }
  }
  if (!insecureTokenSourcesAllowed()) {
    throw new Error("OpenBurnBar MCP token linking requires a secure key store. Set OPENBURNBAR_ALLOW_INSECURE_MCP_TOKEN_SOURCE=true only in tests or disposable CI.");
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
