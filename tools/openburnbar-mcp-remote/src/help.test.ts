import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import { readFileSync } from "node:fs";
import test from "node:test";

const ENTRY = "lib/index.js";
const USAGE_TOKENS = ["mcp", "memory", "resume", "proxy"];

interface CliResult {
  code: number | null;
  stdout: string;
  stderr: string;
  elapsedMs: number;
}

function runCli(args: string[], env: NodeJS.ProcessEnv = {}): Promise<CliResult> {
  return new Promise((resolve, reject) => {
    const started = Date.now();
    const child = spawn(process.execPath, [ENTRY, ...args], {
      cwd: process.cwd(),
      env: { ...process.env, ...env },
      stdio: ["ignore", "pipe", "pipe"]
    });
    let stdout = "";
    let stderr = "";
    child.stdout.setEncoding("utf8");
    child.stderr.setEncoding("utf8");
    child.stdout.on("data", (chunk) => {
      stdout += chunk;
    });
    child.stderr.on("data", (chunk) => {
      stderr += chunk;
    });
    child.on("error", reject);
    child.on("close", (code) => {
      resolve({ code, stdout, stderr, elapsedMs: Date.now() - started });
    });
  });
}

for (const [label, args] of [
  ["no args", []],
  ["--help", ["--help"]],
  ["-h", ["-h"]],
  ["unknown command", ["frobnicate-nonexistent"]]
] as const) {
  test(`usage fall-through: ${label} prints usage to stdout and exits 0`, async () => {
    const result = await runCli([...args]);
    assert.equal(result.code, 0, `expected exit 0 for ${label}`);
    assert.match(result.stdout, /Usage:/u);
    for (const token of USAGE_TOKENS) {
      assert.ok(result.stdout.includes(token), `stdout must mention ${token} for ${label}`);
    }
    assert.equal(result.stderr, "", `stderr must stay empty for ${label}`);
  });
}

test("help shapes complete fast and offline with network blocked", async () => {
  const blockedNetwork = {
    https_proxy: "http://127.0.0.1:9",
    HTTPS_PROXY: "http://127.0.0.1:9",
    http_proxy: "http://127.0.0.1:9",
    HTTP_PROXY: "http://127.0.0.1:9"
  };
  for (const args of [[], ["--help"], ["-h"], ["frobnicate-nonexistent"]]) {
    const result = await runCli(args, blockedNetwork);
    assert.equal(result.code, 0, `expected exit 0 with network blocked for ${JSON.stringify(args)}`);
    assert.ok(result.elapsedMs < 5000, `must complete fast (took ${result.elapsedMs}ms)`);
    assert.doesNotMatch(
      result.stdout + result.stderr,
      /ENOTFOUND|ECONN|mcp\.burnbar\.ai/iu,
      `no network access allowed for ${JSON.stringify(args)}`
    );
  }
});

test("src/index.ts dispatches --help/-h explicitly instead of falling through", () => {
  const source = readFileSync(new URL("../src/index.ts", import.meta.url), "utf8");
  const branchLine = source
    .split("\n")
    .find((line) => line.includes("--help") && line.includes("-h") && line.trimStart().startsWith("if"));
  assert.ok(branchLine, "expected an explicit if branch handling --help/-h in src/index.ts");
});
