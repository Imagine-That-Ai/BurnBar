import { decryptSearchResultJson } from "./decrypt.js";
import { readAccessToken } from "./oauth.js";

const DEFAULT_ENDPOINT = "https://mcp.openburnbar.com/mcp";
const PROTOCOL_VERSION = "2025-11-25";

export async function forwardMcpMessage(message: unknown, endpoint = process.env.OPENBURNBAR_MCP_ENDPOINT ?? DEFAULT_ENDPOINT): Promise<unknown> {
  const token = readAccessToken();
  if (!token) {
    return {
      jsonrpc: "2.0",
      id: (message as { id?: unknown })?.id ?? null,
      error: {
        code: -32001,
        message: "OpenBurnBar MCP is not authenticated. Run `openburnbar mcp doctor` or connect from the OpenBurnBar app."
      }
    };
  }
  const res = await fetch(endpoint, {
    method: "POST",
    headers: {
      "accept": "application/json, text/event-stream",
      "content-type": "application/json",
      "authorization": `Bearer ${token}`,
      "MCP-Protocol-Version": PROTOCOL_VERSION
    },
    body: JSON.stringify(message)
  });
  const json = await res.json() as Record<string, unknown>;
  const result = json.result as { content?: Array<{ type: string; text: string }> } | undefined;
  if (result?.content) {
    result.content = result.content.map((item) => item.type === "text"
      ? { ...item, text: decryptSearchResultJson(item.text) }
      : item);
  }
  return json;
}

export async function runStdioShim(): Promise<void> {
  process.stdin.setEncoding("utf8");
  let buffer = "";
  process.stdin.on("data", (chunk) => {
    buffer += chunk;
    const lines = buffer.split(/\n/u);
    buffer = lines.pop() ?? "";
    for (const line of lines) {
      if (!line.trim()) continue;
      void handleLine(line);
    }
  });
}

async function handleLine(line: string): Promise<void> {
  try {
    const message = JSON.parse(line);
    const response = await forwardMcpMessage(message);
    process.stdout.write(`${JSON.stringify(response)}\n`);
  } catch (err) {
    process.stdout.write(JSON.stringify({
      jsonrpc: "2.0",
      id: null,
      error: { code: -32700, message: err instanceof Error ? err.message : "Invalid MCP stdio input." }
    }) + "\n");
  }
}
