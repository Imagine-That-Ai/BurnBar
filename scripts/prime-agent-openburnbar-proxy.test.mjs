#!/usr/bin/env node
/**
 * Self-test for prime-agent-openburnbar-proxy.mjs.
 *
 * Locks down the non-interactive gateway auth contract: the emitted apiKey
 * must be the env-var-first shell resolver, --token/--api-key must embed a
 * static token without ever printing it, and --status must stay redacted.
 * The resolver string is additionally executed under a real POSIX sh so the
 * env → plist → placeholder fallback chain is proven, not assumed.
 */
import { test } from "node:test";
import assert from "node:assert/strict";
import { execFileSync, spawnSync } from "node:child_process";
import { mkdtempSync, readFileSync, writeFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, dirname } from "node:path";
import { fileURLToPath } from "node:url";

const SCRIPT = join(dirname(fileURLToPath(import.meta.url)), "prime-agent-openburnbar-proxy.mjs");
const roots = [];

process.on("exit", () => {
  for (const root of roots) rmSync(root, { recursive: true, force: true });
});

function tempDir() {
  const root = mkdtempSync(join(tmpdir(), "openburnbar-prime-proxy-"));
  roots.push(root);
  return root;
}

function run(args, env = {}) {
  const result = spawnSync("node", [SCRIPT, ...args], {
    encoding: "utf8",
    env: { ...process.env, ...env },
    stdio: ["ignore", "pipe", "pipe"],
  });
  if (result.error) throw result.error;
  return { status: result.status ?? 1, stdout: result.stdout ?? "", stderr: result.stderr ?? "" };
}

function printFragment(args, env = {}) {
  const result = run(["--print", ...args], env);
  assert.equal(result.status, 0, `--print ${args.join(" ")} failed: ${result.stderr}`);
  const fragment = JSON.parse(result.stdout);
  assert.ok(fragment.providers?.openburnbar, "fragment must carry the openburnbar provider");
  return { fragment, raw: result.stdout, stderr: result.stderr };
}

/** Rung 1 of the resolver, spelled exactly as the script must emit it. */
const ENV_RUNG = String.raw`![ -n "$OPENBURNBAR_GATEWAY_AUTH_TOKEN" ] && printf '%s\n' "$OPENBURNBAR_GATEWAY_AUTH_TOKEN"`;
const PLIST_RUNG = "plutil -extract EnvironmentVariables.OPENBURNBAR_GATEWAY_AUTH_TOKEN";
const PLACEHOLDER_RUNG = String.raw`printf '%s\n' openburnbar-local`;

/**
 * Runs the emitted apiKey shell command through a real POSIX sh and returns
 * its stdout, mirroring prime-agent's resolveConfigValue(): a stored apiKey
 * starting with `!` is treated as a command — the marker is stripped
 * (`config.slice(1)`) and the remainder runs through execSync at request
 * time. It must work in interactive, SSH/CI, and stripped-env shells.
 * execFileSync throws on a non-zero exit, which also asserts the chain always
 * terminates in a successful rung.
 */
function resolveViaShell(apiKey, env = {}) {
  assert.ok(apiKey.startsWith("!"), "stored apiKey must carry the prime-agent !command marker");
  const { HOME, PATH } = process.env;
  return execFileSync("sh", ["-c", apiKey.slice(1)], {
    encoding: "utf8",
    env: { HOME, PATH, ...env },
    stdio: ["ignore", "pipe", "pipe"],
  }).trim();
}

test("default --print emits the env-var-first shell resolver", () => {
  const { fragment, raw } = printFragment([]);
  const apiKey = fragment.providers.openburnbar.apiKey;
  assert.equal(typeof apiKey, "string");
  assert.ok(apiKey.startsWith(ENV_RUNG), `resolver must check $OPENBURNBAR_GATEWAY_AUTH_TOKEN first, got: ${apiKey}`);
  const envIdx = apiKey.indexOf("$OPENBURNBAR_GATEWAY_AUTH_TOKEN");
  const plistIdx = apiKey.indexOf(PLIST_RUNG);
  const fallbackIdx = apiKey.indexOf(PLACEHOLDER_RUNG);
  assert.ok(envIdx < plistIdx && plistIdx < fallbackIdx,
    `resolution order must be env → plist → placeholder, got: ${apiKey}`);
  assert.ok(apiKey.includes("2>/dev/null"), "noisy tools must have stderr suppressed for headless shells");
  assert.ok(!raw.includes("undefined"), "fragment must not leak undefined placeholders");

  // Every rung must be non-interactive. `security find-generic-password -w`
  // is not: the app writes the token under service
  // com.openburnbar.chat-gateway-secrets / account settings.gateway.http.authToken
  // with an app-scoped ACL, so a foreign binary either blocks on a GUI
  // authorization prompt or fails with errSecInteractionNotAllowed.
  assert.ok(!apiKey.includes("security find-generic-password"),
    `the resolver must not query the Keychain, got: ${apiKey}`);
  // POSIX echo expands backslash escapes and corrupts tokens containing them.
  assert.ok(!/\becho\b/.test(apiKey), `use printf '%s\\n' instead of echo, got: ${apiKey}`);
});

test("resolver string is POSIX-safe across shell environments", () => {
  const { fragment } = printFragment([]);
  const apiKey = fragment.providers.openburnbar.apiKey;

  // Non-interactive shell with the env var exported wins over every other source.
  assert.equal(resolveViaShell(apiKey, { OPENBURNBAR_GATEWAY_AUTH_TOKEN: "env-token" }), "env-token");

  // Tokens are passed through verbatim. `echo "$VAR"` expands the \b here and
  // silently hands the gateway `ac-token` under both /bin/sh and dash.
  const escaped = String.raw`a\bc-token`;
  assert.equal(resolveViaShell(apiKey, { OPENBURNBAR_GATEWAY_AUTH_TOKEN: escaped }), escaped);

  // Stripped headless shell (SSH/CI-style): no env var, no plist — must land on
  // the harmless placeholder with no stderr noise.
  const isolated = tempDir();
  assert.equal(
    resolveViaShell(apiKey, {
      HOME: isolated,
      USER: "nobody",
      OPENBURNBAR_GATEWAY_AUTH_TOKEN: "",
    }),
    "openburnbar-local",
  );
});

test("--token and --api-key embed a static token without echoing it", () => {
  for (const args of [
    ["--token", "test-secret-token"],
    ["--token=equals-form-token"],
    ["--api-key", "alt-flag-token"],
    ["--api-key=alt-equals-token"],
  ]) {
    const literal = args[args.length - 1].replace(/^--(token|api-key)=?/, "");
    const { fragment, raw, stderr } = printFragment(args);
    const entry = fragment.providers.openburnbar;
    assert.equal(entry.apiKey, "<redacted: static gateway token>",
      `--print must redact the static token for ${args.join(" ")}`);
    assert.ok(!raw.includes(literal), `the literal token must never reach stdout (${args.join(" ")})`);
    assert.ok(!stderr.includes(literal), `the literal token must never reach stderr (${args.join(" ")})`);
    // A redacted preview is not a usable config, so piping it must not look safe.
    assert.match(stderr, /NOT a usable config/,
      `--print --token must warn that the preview is unusable (${args.join(" ")})`);
  }
});

test("plain --print stays pipeable and warns about nothing", () => {
  const { fragment, stderr } = printFragment([]);
  assert.ok(fragment.providers.openburnbar.apiKey.startsWith("!["),
    "plain --print must emit the resolver so `--print > models.json` works");
  assert.equal(stderr, "", "plain --print is a working config and needs no warning");
});

test("a flag-shaped --token value is not swallowed as a credential", () => {
  // `--token --print` used to set the token to the literal string "--print".
  const { fragment } = printFragment(["--token"]);
  assert.ok(fragment.providers.openburnbar.apiKey.startsWith("!["),
    "a missing --token value must leave the shell resolver in place");
  const chained = run(["--token", "--print"]);
  assert.equal(chained.status, 0, chained.stderr);
  const apiKey = JSON.parse(chained.stdout).providers.openburnbar.apiKey;
  assert.ok(apiKey.startsWith("!["), `--token must not consume the following flag, got: ${apiKey}`);
});

test("whitespace-only --token falls back to the shell resolver", () => {
  const { fragment } = printFragment(["--token", "   "]);
  assert.ok(
    fragment.providers.openburnbar.apiKey.startsWith("!["),
    "empty token must not be embedded; the resolver must remain",
  );
});

test("static token is written into models.json and never logged", () => {
  const dir = tempDir();
  const modelsPath = join(dir, "models.json");
  const env = { PRIME_MODELS_PATH: modelsPath };
  const result = run(["--token", "persist-me-token"], env);
  assert.equal(result.status, 0, `sync failed: ${result.stderr}`);
  const written = JSON.parse(readFileSync(modelsPath, "utf8"));
  assert.equal(written.providers.openburnbar.apiKey, "persist-me-token");
  assert.ok(!result.stdout.includes("persist-me-token"), "sync summary must not echo the token");
  assert.ok(result.stdout.includes("static token (passed via CLI)"), "summary must name the static-token mode");
});

test("sync preserves foreign providers and stays idempotent", () => {
  const dir = tempDir();
  const modelsPath = join(dir, "models.json");
  writeFileSync(modelsPath, JSON.stringify({
    providers: { meta: { name: "Meta", baseUrl: "https://api.meta.example/v1", models: [] } },
  }), "utf8");
  const env = { PRIME_MODELS_PATH: modelsPath };

  const first = run([], env);
  assert.equal(first.status, 0, first.stderr);
  const afterFirst = JSON.parse(readFileSync(modelsPath, "utf8"));
  assert.equal(afterFirst.providers.meta.name, "Meta", "foreign providers must survive the merge");
  const firstCount = afterFirst.providers.openburnbar.models.length;
  assert.ok(firstCount > 100, `catalog should produce 150+ models, got ${firstCount}`);

  const second = run([], env);
  assert.equal(second.status, 0, second.stderr);
  const afterSecond = JSON.parse(readFileSync(modelsPath, "utf8"));
  assert.equal(afterSecond.providers.openburnbar.models.length, firstCount, "re-run must be idempotent");
  assert.ok(second.stdout.includes(`models: ${firstCount} (was ${firstCount})`));
});

test("--status redacts the stored apiKey", () => {
  const dir = tempDir();
  const modelsPath = join(dir, "models.json");
  writeFileSync(modelsPath, JSON.stringify({
    providers: {
      openburnbar: {
        name: "OpenBurnBar Gateway",
        baseUrl: "http://127.0.0.1:8317/v1",
        api: "openai-completions",
        apiKey: "stored-secret-token",
        models: [{ id: "claude-sonnet-4-6" }],
      },
    },
  }), "utf8");
  const result = run(["--status"], { PRIME_MODELS_PATH: modelsPath });
  assert.equal(result.status, 0, result.stderr);
  assert.ok(!result.stdout.includes("stored-secret-token"), "status output must never contain apiKey material");
  assert.ok(!result.stdout.toLowerCase().includes("apikey"), "status output must not mention the credential field");
  assert.ok(result.stdout.includes("models: 1"));
});

test("--gateway-host and --gateway-port overrides reach baseUrl", () => {
  const { fragment } = printFragment(["--gateway-host", "10.0.0.5", "--gateway-port", "9421"]);
  assert.equal(fragment.providers.openburnbar.baseUrl, "http://10.0.0.5:9421/v1");
});

test("--remove deletes only the openburnbar provider", () => {
  const dir = tempDir();
  const modelsPath = join(dir, "models.json");
  writeFileSync(modelsPath, JSON.stringify({
    providers: {
      openburnbar: { apiKey: "gone", models: [] },
      meta: { name: "Meta" },
    },
  }), "utf8");
  const result = run(["--remove"], { PRIME_MODELS_PATH: modelsPath });
  assert.equal(result.status, 0, result.stderr);
  const after = JSON.parse(readFileSync(modelsPath, "utf8"));
  assert.equal(after.providers.openburnbar, undefined);
  assert.equal(after.providers.meta.name, "Meta");
});
