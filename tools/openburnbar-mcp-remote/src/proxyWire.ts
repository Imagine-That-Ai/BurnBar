import { randomBytes } from "node:crypto";
import { copyFileSync, existsSync, mkdirSync, readFileSync, renameSync, writeFileSync } from "node:fs";
import { homedir as osHomedir } from "node:os";
import { basename, dirname, join } from "node:path";
import { LOCAL_CLIPROXY_KEY } from "./proxyAuth.js";
import { proxySnippets, type ProxySnippet } from "./proxySnippets.js";

export const WIRE_CLIENTS = ["grok", "droid", "forge", "opencode", "codex", "claude", "pi"] as const;
export type WireClient = (typeof WIRE_CLIENTS)[number];

export const GATEWAY_SENTINEL_START = "# openburnbar:gateway-8320 — start";
export const GATEWAY_SENTINEL_END = "# openburnbar:gateway-8320 — end";
export const MAC_ROUTING_SENTINEL = "# openburnbar:routing — start";

export const WIRE_USAGE =
  "Usage: openburnbar proxy wire <grok|droid|forge|opencode|codex|claude|pi> [--port 8320] [--token <token>] [--write]\n       openburnbar proxy unwire <client> [--write]\n\nWithout --write, prints the snippet. --write updates that client's config under $HOME.\nThis points at :8320 + local-cliproxy. It uses a different sentinel than BurnBar Mac Connect (:8317) so the two do not clobber each other. Cursor BYOK cannot be wired.\n";

export interface WireResult {
  client: WireClient;
  path: string;
  body: string;
  removed?: boolean;
  warning?: string;
  wrote: boolean;
}

function snippetFor(client: WireClient, port: number): ProxySnippet {
  const id =
    client === "claude"
      ? "claude-code"
      : client === "droid"
        ? "droid-generic"
        : client;
  const snippet = proxySnippets(port).find((row) => row.id === id);
  if (!snippet) {
    throw new Error(`error: no snippet for ${client}`);
  }
  return snippet;
}

export function wirePath(client: WireClient, home: string): string {
  switch (client) {
    case "grok":
      return join(home, ".grok", "config.toml");
    case "codex":
      return join(home, ".codex", "config.toml");
    case "forge":
      return join(home, "forge", ".forge.toml");
    case "claude":
      return join(home, ".claude", "settings.json");
    case "opencode":
      return join(home, ".config", "opencode", "opencode.json");
    case "droid":
      return join(home, ".factory", "settings.local.json");
    case "pi":
      return join(home, ".pi", "agent", "models.json");
  }
}

function fenced(body: string): string {
  const trimmed = body.trimEnd();
  return `${GATEWAY_SENTINEL_START}\n${trimmed}\n${GATEWAY_SENTINEL_END}\n`;
}

function replaceToml(existing: string, block: string): string {
  const start = existing.indexOf(GATEWAY_SENTINEL_START);
  if (start === -1) {
    const prefix = existing.length > 0 && !existing.endsWith("\n") ? `${existing}\n\n` : existing.length > 0 ? `${existing}\n` : "";
    return `${prefix}${block}`;
  }
  const end = existing.indexOf(GATEWAY_SENTINEL_END, start);
  if (end === -1) {
    throw new Error("error: configuration file contains an unclosed OpenBurnBar sentinel block");
  }
  return `${existing.slice(0, start)}${block}${existing.slice(end + GATEWAY_SENTINEL_END.length)}`;
}

function stripToml(existing: string): string {
  const start = existing.indexOf(GATEWAY_SENTINEL_START);
  if (start === -1) {
    return existing;
  }
  const end = existing.indexOf(GATEWAY_SENTINEL_END, start);
  if (end === -1) {
    throw new Error("error: configuration file contains an unclosed OpenBurnBar sentinel block");
  }
  if (end <= start) {
    throw new Error("error: configuration file contains an unclosed OpenBurnBar sentinel block");
  }
  return `${existing.slice(0, start)}${existing.slice(end + GATEWAY_SENTINEL_END.length)}`.trimStart();
}

function stripJsonComments(input: string): string {
  return input
    .replace(/\/\*[\s\S]*?\*\//gu, "")
    .replace(/(^|[^\\:])\/\/.*$/gmu, "$1")
    .replace(/,\s*([\]}])/gu, "$1");
}

function readJsonObject(path: string): Record<string, unknown> {
  if (!existsSync(path)) {
    return {};
  }
  const raw = readFileSync(path, "utf8");
  const stripped = stripJsonComments(raw);
  const parsed = JSON.parse(stripped) as unknown;
  if (!parsed || typeof parsed !== "object" || Array.isArray(parsed)) {
    throw new Error(`error: ${path} is not a JSON object`);
  }
  return parsed as Record<string, unknown>;
}

function macWarning(existing: string): string | undefined {
  if (existing.includes(MAC_ROUTING_SENTINEL) || existing.includes("127.0.0.1:8317")) {
    return "BurnBar Mac Connect (:8317) wiring is present. This writes a separate :8320 block and will not remove it.";
  }
  return undefined;
}

function writeFile(path: string, body: string): void {
  const dir = dirname(path);
  mkdirSync(dir, { recursive: true, mode: 0o700 });
  if (existsSync(path)) {
    try {
      copyFileSync(path, `${path}.openburnbar.bak`);
    } catch {
      // Ignore backup creation failure
    }
  }
  const content = body.endsWith("\n") ? body : `${body}\n`;
  const temporaryPath = join(
    dir,
    `.${basename(path)}.${process.pid}.${randomBytes(6).toString("hex")}.tmp`
  );
  writeFileSync(temporaryPath, content, { encoding: "utf8", mode: 0o600, flag: "wx" });
  renameSync(temporaryPath, path);
}

function mergeClaude(
  existing: Record<string, unknown>,
  port: number,
  token = LOCAL_CLIPROXY_KEY
): Record<string, unknown> {
  const env = { ...((existing["env"] as Record<string, unknown> | undefined) ?? {}) };
  env["ANTHROPIC_BASE_URL"] = `http://127.0.0.1:${port}`;
  env["ANTHROPIC_AUTH_TOKEN"] = token;
  env["ANTHROPIC_MODEL"] = "claude-opus-5";
  env["OPENBURNBAR_GATEWAY_8320"] = "1";
  return { ...existing, env };
}

function unmergeClaude(existing: Record<string, unknown>): Record<string, unknown> {
  const env = { ...((existing["env"] as Record<string, unknown> | undefined) ?? {}) };
  if (env["OPENBURNBAR_GATEWAY_8320"] !== "1") {
    return existing;
  }
  delete env["ANTHROPIC_BASE_URL"];
  delete env["ANTHROPIC_AUTH_TOKEN"];
  delete env["ANTHROPIC_MODEL"];
  delete env["OPENBURNBAR_GATEWAY_8320"];
  const next = { ...existing };
  if (Object.keys(env).length === 0) {
    delete next["env"];
  } else {
    next["env"] = env;
  }
  return next;
}

function mergeOpenCode(existing: Record<string, unknown>, port: number): Record<string, unknown> {
  const snippet = JSON.parse(snippetFor("opencode", port).body) as {
    provider: Record<string, unknown>;
  };
  const provider = { ...((existing["provider"] as Record<string, unknown> | undefined) ?? {}) };
  provider["openburnbar"] = snippet.provider["openburnbar"];
  return { ...existing, provider };
}

function mergeDroid(existing: Record<string, unknown>, port: number): Record<string, unknown> {
  const incoming = JSON.parse(snippetFor("droid", port).body) as {
    customModels: Array<Record<string, unknown>>;
  };
  const current = Array.isArray(existing["customModels"])
    ? (existing["customModels"] as Array<Record<string, unknown>>)
    : [];
  const filtered = current.filter((row) => row["id"] !== incoming.customModels[0]?.["id"]);
  return { ...existing, customModels: [...filtered, ...incoming.customModels] };
}

function mergePi(existing: Record<string, unknown>, port: number): Record<string, unknown> {
  const incoming = JSON.parse(snippetFor("pi", port).body) as Record<string, unknown>;
  const providers = { ...((existing["providers"] as Record<string, unknown> | undefined) ?? {}) };
  providers["openburnbar"] = incoming["openburnbar"];
  return { ...existing, providers };
}

export function applyWire(
  client: WireClient,
  options: { port: number; home?: string; write: boolean; unwire?: boolean; token?: string }
): WireResult {
  const home = options.home ?? osHomedir();
  const path = wirePath(client, home);
  const existing = existsSync(path) ? readFileSync(path, "utf8") : "";
  const warning = macWarning(existing);
  const snippet = snippetFor(client, options.port);

  if (client === "grok" || client === "codex" || client === "forge") {
    const next = options.unwire ? stripToml(existing) : replaceToml(existing, fenced(snippet.body));
    const removed = Boolean(options.unwire && existing !== next && existing.includes(GATEWAY_SENTINEL_START));
    const wrote = Boolean(options.write && (options.unwire ? removed : true));
    if (wrote) {
      writeFile(path, next);
    }
    return {
      client,
      path,
      body: options.unwire ? "" : snippet.body,
      removed,
      warning,
      wrote,
    };
  }

  const root = existsSync(path) ? readJsonObject(path) : {};
  let next: Record<string, unknown>;
  let removed = false;
  if (options.unwire) {
    if (client === "claude") {
      next = unmergeClaude(root);
      removed = (root["env"] as Record<string, unknown> | undefined)?.[
        "OPENBURNBAR_GATEWAY_8320"
      ] === "1";
    } else if (client === "opencode") {
      const provider = { ...((root["provider"] as Record<string, unknown> | undefined) ?? {}) };
      removed = "openburnbar" in provider;
      delete provider["openburnbar"];
      next = { ...root };
      if (Object.keys(provider).length === 0) {
        delete next["provider"];
      } else {
        next["provider"] = provider;
      }
    } else if (client === "droid") {
      const currentModels = Array.isArray(root["customModels"])
        ? (root["customModels"] as Array<Record<string, unknown>>)
        : [];
      const models = currentModels.filter(
        (row) =>
          typeof row["id"] !== "string" ||
          !String(row["id"]).startsWith("custom:OpenBurnBar-")
      );
      removed = models.length !== currentModels.length;
      next = { ...root, customModels: models };
    } else {
      const providers = { ...((root["providers"] as Record<string, unknown> | undefined) ?? {}) };
      removed = "openburnbar" in providers;
      delete providers["openburnbar"];
      next = { ...root };
      if (Object.keys(providers).length === 0) {
        delete next["providers"];
      } else {
        next["providers"] = providers;
      }
    }
  } else if (client === "claude") {
    next = mergeClaude(root, options.port, options.token);
  } else if (client === "opencode") {
    next = mergeOpenCode(root, options.port);
  } else if (client === "droid") {
    next = mergeDroid(root, options.port);
  } else {
    next = mergePi(root, options.port);
  }
  const body = `${JSON.stringify(next, null, 2)}\n`;
  const wrote = Boolean(options.write && (options.unwire ? removed : true));
  if (wrote) {
    writeFile(path, body);
  }
  return {
    client,
    path,
    body: options.unwire ? "" : snippet.body,
    removed,
    warning,
    wrote,
  };
}

export function parseWireClient(value: string | undefined): WireClient {
  if (value === "cursor") {
    throw new Error("error: Cursor BYOK cannot use a loopback gateway (requests originate at api2.cursor.sh)");
  }
  if (!value || !(WIRE_CLIENTS as readonly string[]).includes(value)) {
    throw new Error(WIRE_USAGE.trim());
  }
  return value as WireClient;
}

export async function runProxyWireCli(argv: string[], home = osHomedir()): Promise<number> {
  const args = argv[0] === "wire" || argv[0] === "unwire" ? argv : ["wire", ...argv];
  if (args[1] === "--help" || args[1] === "-h" || args[1] === "help") {
    process.stdout.write(WIRE_USAGE);
    return 0;
  }
  const unwire = args[0] === "unwire";
  const clientArg = args[1];
  let port = 8320;
  let write = false;
  let token: string | undefined;
  const rest = args.slice(2);
  for (let i = 0; i < rest.length; i += 1) {
    const arg = rest[i];
    if (arg === "--write") {
      write = true;
      continue;
    }
    if (arg === "--port" || arg === "-p") {
      const value = rest[i + 1];
      if (!value || !/^\d{1,5}$/u.test(value) || Number(value) < 1 || Number(value) > 65535) {
        throw new Error("error: --port requires a valid port number (1-65535)");
      }
      port = Number(value);
      i += 1;
      continue;
    }
    if (arg === "--token") {
      const value = rest[i + 1];
      if (!value) {
        throw new Error("error: --token requires a value");
      }
      token = value;
      i += 1;
      continue;
    }
    throw new Error(`error: unknown wire argument "${arg ?? ""}"`);
  }
  const client = parseWireClient(clientArg);
  const result = applyWire(client, {
    port,
    home,
    write,
    unwire,
    token: token ?? process.env["OPENBURNBAR_GATEWAY_TOKEN"],
  });
  if (result.warning) {
    process.stderr.write(`${result.warning}\n`);
  }
  if (write) {
    if (unwire && !result.removed) {
      process.stdout.write(`No openburnbar :${port} block found in ${result.path}\n`);
    } else {
      process.stdout.write(`${unwire ? "Removed" : "Wrote"} ${result.path}\n`);
    }
  } else if (unwire) {
    process.stdout.write(
      result.removed
        ? `# Dry run. --write would remove the openburnbar :${port} block from ${result.path}\n`
        : `# Dry run. No openburnbar :${port} block found in ${result.path}\n`
    );
  } else {
    process.stdout.write(`${result.body}\n`);
    process.stdout.write(`# Dry run. Pass --write to update ${result.path}\n`);
  }
  return 0;
}
