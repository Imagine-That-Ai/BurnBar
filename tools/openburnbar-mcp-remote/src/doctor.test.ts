import assert from "node:assert/strict";
import { test } from "node:test";
import { doctor } from "./doctor.js";

interface CapturedRun {
  code: number;
  stdout: string;
}

async function captureDoctor(): Promise<CapturedRun> {
  let stdout = "";
  const originalWrite = process.stdout.write.bind(process.stdout);
  process.stdout.write = ((chunk: string | Uint8Array) => {
    stdout += chunk.toString();
    return true;
  }) as typeof process.stdout.write;
  try {
    const code = await doctor();
    return { code, stdout };
  } finally {
    process.stdout.write = originalWrite;
  }
}

test("doctor keeps structured output and exits 1 when the endpoint is unreachable", async () => {
  // Unroutable TEST-NET loopback-class address: /readyz fails, so tools/list
  // is the interesting path only when a token exists — which requires the
  // insecure env-token opt-in.
  process.env.OPENBURNBAR_MCP_ENDPOINT = "http://127.0.0.1:1/mcp";
  process.env.OPENBURNBAR_MCP_ACCESS_TOKEN = "doctor-test-token";
  process.env.OPENBURNBAR_ALLOW_INSECURE_MCP_TOKEN_SOURCE = "true";
  try {
    const { code, stdout } = await captureDoctor();
    assert.equal(code, 1);
    assert.match(stdout, /^PASS token:/m);
    assert.match(stdout, /^FAIL endpoint:/m);
    // tools/list must be reported as a structured FAIL line, never thrown.
    assert.match(stdout, /^FAIL tools\/list:/m);
    assert.equal(stdout.trim().split("\n").length, 3);
  } finally {
    delete process.env.OPENBURNBAR_MCP_ENDPOINT;
    delete process.env.OPENBURNBAR_MCP_ACCESS_TOKEN;
    delete process.env.OPENBURNBAR_ALLOW_INSECURE_MCP_TOKEN_SOURCE;
  }
});
