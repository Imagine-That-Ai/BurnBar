import { readAccessToken } from "./oauth.js";
import { DEFAULT_ENDPOINT, forwardMcpMessage } from "./shim.js";

export async function doctor(): Promise<number> {
  const checks: Array<{ name: string; ok: boolean; detail: string }> = [];
  checks.push({
    name: "token",
    ok: Boolean(readAccessToken()),
    detail: readAccessToken()
      ? "Access token found outside client config."
      : "No access token found in macOS Keychain. Plaintext env/file token sources require OPENBURNBAR_ALLOW_INSECURE_MCP_TOKEN_SOURCE=true and are for tests or disposable CI only."
  });
  const endpoint = process.env.OPENBURNBAR_MCP_ENDPOINT ?? DEFAULT_ENDPOINT;
  try {
    const health = await fetch(endpoint.replace(/\/mcp$/u, "/readyz"));
    checks.push({ name: "endpoint", ok: health.ok, detail: `${health.status} ${health.statusText}` });
  } catch (err) {
    checks.push({ name: "endpoint", ok: false, detail: err instanceof Error ? err.message : String(err) });
  }
  if (readAccessToken()) {
    const list = await forwardMcpMessage({ jsonrpc: "2.0", id: 1, method: "tools/list", params: {} }, endpoint);
    checks.push({
      name: "tools/list",
      ok: !("error" in (list as Record<string, unknown>)),
      detail: JSON.stringify(list).slice(0, 240)
    });
  }
  for (const check of checks) {
    process.stdout.write(`${check.ok ? "PASS" : "FAIL"} ${check.name}: ${check.detail}\n`);
  }
  return checks.every((check) => check.ok) ? 0 : 1;
}
