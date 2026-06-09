import { execFileSync } from "node:child_process";
import { existsSync, readFileSync, rmSync, writeFileSync, chmodSync, mkdirSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";

const SERVICE = "com.openburnbar.mcp-remote";
const ACCOUNT = "vault-key";
const INSECURE_VAULT_KEY_ENV = "OPENBURNBAR_CLOUD_VAULT_KEY_BASE64";
const ALLOW_INSECURE_VAULT_KEY_SOURCE_ENV = "OPENBURNBAR_ALLOW_INSECURE_VAULT_KEY_SOURCE";

function fallbackPath(): string {
  const dir = join(homedir(), ".openburnbar");
  mkdirSync(dir, { recursive: true });
  return join(dir, "vault-key");
}

function insecureVaultKeySourcesAllowed(): boolean {
  return process.env[ALLOW_INSECURE_VAULT_KEY_SOURCE_ENV] === "true";
}

export function legacyVaultKeyPath(): string {
  return join(homedir(), ".openburnbar", "vault-key");
}

export function removeLegacyVaultKeyFile(): boolean {
  const path = legacyVaultKeyPath();
  if (!existsSync(path)) return false;
  rmSync(path, { force: true });
  return true;
}

export function readVaultKey(): string | undefined {
  if (process.platform === "darwin") {
    try {
      return execFileSync("security", ["find-generic-password", "-s", SERVICE, "-a", ACCOUNT, "-w"], { encoding: "utf8" }).trim();
    } catch {
      // Production is Keychain-only. Insecure sources below are test/dev opt-ins.
    }
  }
  if (!insecureVaultKeySourcesAllowed()) return undefined;
  if (process.env[INSECURE_VAULT_KEY_ENV]) {
    return process.env[INSECURE_VAULT_KEY_ENV];
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
      removeLegacyVaultKeyFile();
      return;
    } catch {
      throw new Error("OpenBurnBar MCP vault-key linking requires macOS Keychain. Refusing to write a plaintext fallback vault key.");
    }
  }
  if (!insecureVaultKeySourcesAllowed()) {
    throw new Error("OpenBurnBar MCP vault-key linking requires a secure key store. Set OPENBURNBAR_ALLOW_INSECURE_VAULT_KEY_SOURCE=true only in tests or disposable CI.");
  }
  const path = fallbackPath();
  writeFileSync(path, `${base64Key}\n`, { mode: 0o600 });
  chmodSync(path, 0o600);
}
