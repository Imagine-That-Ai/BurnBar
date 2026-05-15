#!/usr/bin/env node
import { request as httpRequest } from "node:http";
import { request as httpsRequest } from "node:https";

const args = Object.fromEntries(process.argv.slice(2).map((item, index, all) => {
  if (!item.startsWith("--")) return [];
  return [item.slice(2), all[index + 1]];
}).filter(Boolean));

const endpoint = args.endpoint ?? "https://mcp.openburnbar.com/mcp";
const token = process.env.OPENBURNBAR_MCP_PROOF_TOKEN;

function post(url, body, headers = {}) {
  return new Promise((resolve, reject) => {
    const request = url.startsWith("http://") ? httpRequest : httpsRequest;
    const req = request(url, {
      method: "POST",
      headers: {
        "content-type": "application/json",
        "accept": "application/json, text/event-stream",
        ...headers
      }
    }, (res) => {
      const chunks = [];
      res.on("data", (chunk) => chunks.push(chunk));
      res.on("end", () => resolve({ status: res.statusCode, body: Buffer.concat(chunks).toString("utf8") }));
    });
    req.on("error", reject);
    req.end(JSON.stringify(body));
  });
}

const missing = await post(endpoint, { jsonrpc: "2.0", id: 1, method: "tools/list", params: {} });
if (missing.status !== 401) throw new Error(`missing auth expected 401, got ${missing.status}`);

if (!token) {
  console.log(JSON.stringify({ ok: false, skippedLivePaidProof: true, reason: "OPENBURNBAR_MCP_PROOF_TOKEN not set", missingAuthStatus: missing.status }, null, 2));
  process.exit(2);
}

const tools = await post(endpoint, { jsonrpc: "2.0", id: 2, method: "tools/list", params: {} }, { authorization: `Bearer ${token}` });
if (tools.status !== 200 || !tools.body.includes("burnbar_search_conversations")) {
  throw new Error(`tools/list failed: ${tools.status} ${tools.body.slice(0, 500)}`);
}

console.log(JSON.stringify({ ok: true, endpoint, missingAuthStatus: missing.status, toolsStatus: tools.status }, null, 2));
