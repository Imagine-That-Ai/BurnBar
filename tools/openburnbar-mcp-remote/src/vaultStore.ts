import { execFileSync } from "node:child_process";
import { mkdirSync, readFileSync, writeFileSync, chmodSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";

const SERVICE = "com.openburnbar.mcp-remote";
const ACCOUNT = "vault-key";

function fallbackPath(): string {
  const dir = join(homedir(), ".openburnbar");
  mkdirSync(dir, { recursive: true });
  return join(dir, "vault-key");
}

export function readVaultKey(): string | undefined {
  if (process.env.OPENBURNBAR_CLOUD_VAULT_KEY_BASE64) {
    return process.env.OPENBURNBAR_CLOUD_VAULT_KEY_BASE64;
  }
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

export function writeVaultKey(base64Key: string): void {
  if (process.platform === "darwin") {
    try {
      execFileSync("security", ["add-generic-password", "-U", "-s", SERVICE, "-a", ACCOUNT, "-w", base64Key], { stdio: "ignore" });
      return;
    } catch {
      // Use the fallback path only when Keychain is unavailable.
    }
  }
  const path = fallbackPath();
  writeFileSync(path, `${base64Key}\n`, { mode: 0o600 });
  chmodSync(path, 0o600);
}
