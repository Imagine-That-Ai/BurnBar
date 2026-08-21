import { execFileSync, type ChildProcess } from "node:child_process";
import { randomBytes } from "node:crypto";
import {
  chmodSync,
  closeSync,
  existsSync,
  fstatSync,
  lstatSync,
  mkdirSync,
  openSync,
  readSync,
  renameSync,
  unlinkSync,
  writeFileSync,
} from "node:fs";
import http from "node:http";
import { homedir, tmpdir } from "node:os";
import { join } from "node:path";
import { fileURLToPath } from "node:url";
import {
  DEFAULT_PROXY_HOST,
  DEFAULT_PROXY_PORT,
  LOCAL_CLIPROXY_KEY,
  PROXY_CONTROL_HEADER,
  anthropicGatewayUrl,
  containsUnsafeDisplayText,
  isAuthorized,
  isLoopbackHttpUrl,
  isLoopbackIp,
  normalizeLoopbackUpstream,
  normalizeProxyHost,
  openaiGatewayUrl,
  type ProxyOptions,
  type StandaloneProvider,
} from "./proxyAuth.js";
import {
  MAX_PROXY_BODY_BYTES,
  NON_STREAM_FETCH_TIMEOUT_MS,
  REQUEST_TOO_LARGE_MESSAGE,
} from "./proxyRelay.js";
import { createProxyServer } from "./proxyRoutes.js";
import { allProxySnippetText, proxySnippets } from "./proxySnippets.js";
import {
  PROXY_SERVICE,
  buildProxyStatusPayload,
  isProxyConfigured,
  type ProxyHealth,
} from "./proxyStatus.js";
import { openLoopbackPanel } from "./proxyPanel.js";
import { runProxyWireCli } from "./proxyWire.js";
import { ensureGatewayTrayApp, spawnGatewayTray } from "./proxyTray.js";

export const PROXY_USAGE = `Usage:
  openburnbar proxy [--port <8320>] [--host <127.0.0.1>] [--token <token>] [--require-token] [--tray]
  openburnbar proxy status [--port <8320>]
  openburnbar proxy stop [--port <8320>]
  openburnbar proxy wire <grok|droid|forge|opencode|codex|claude|pi> [--port 8320] [--write]
  openburnbar proxy unwire <client> [--write]

Options:
  --port, -p <port>     Port to bind or inspect (default: 8320)
  --host <host>         Loopback host to bind (default: 127.0.0.1)
  --token, -t <token>   Accept one additional Bearer / x-api-key token
  --token-file <path>   Read the accept token from a file (keeps it out of argv/ps)
  --require-token       Disable the default local-cliproxy key (requires --token)
  --tray                macOS: menu-bar helper. Elsewhere: open the loopback HTML panel.

Loopback accepts Bearer / x-api-key \`local-cliproxy\` unless --require-token is passed.

Environment:
  XAI_API_KEY                         Standalone xAI provider (chat + responses)
  OPENBURNBAR_PROVIDER_BASE_URL       Standalone OpenAI-compatible provider base URL
  OPENBURNBAR_PROVIDER_API_KEY        Credential for that standalone provider
  OPENBURNBAR_UPSTREAM                Loopback OpenBurnBar-compatible gateway to forward to
  OPENBURNBAR_GATEWAY_TOKEN           Extra local token and forward-upstream token
  OPENBURNBAR_REQUIRE_TOKEN           Set to 1 to require a private token and disable local-cliproxy

This npm gateway is a loopback relay on :8320 (chat, messages, responses, Responses
WebSocket, GET/DELETE /v1/responses/:id). It does not translate dialects or count burn.
Bodies are capped at 8 MiB until a real client 413 proves we should raise it.
Bind is 127.0.0.1 only — never use localhost (macOS often resolves it to ::1).

Forward to BurnBar on :8317 only with a matching token:
  export OPENBURNBAR_UPSTREAM=http://127.0.0.1:8317
  export OPENBURNBAR_GATEWAY_TOKEN='<same token BurnBar's gateway expects>'

app install puts OpenBurnBar.app on disk; proxy starts the local OpenAI/Anthropic gateway; npm i never starts either.
`;

export type ProxyCommand = "start" | "status" | "stop";

export interface ProxyCliOptions extends ProxyOptions {
  command: ProxyCommand;
}

export interface ProcessPortInfo {
  pid: number;
  command: string;
}

export interface ProxyCliRuntime {
  platform?: NodeJS.Platform;
  env?: NodeJS.ProcessEnv;
  writeStderr?: (text: string) => void;
}

interface ProxyPidFile {
  version: typeof PID_FILE_VERSION;
  pid: number;
  port: number;
  host: string;
  token: string;
  startedAt: string;
}

const PID_FILE_VERSION = 1;
const HEALTH_TIMEOUT_MS = 1_000;

function strictPort(value: string): number {
  if (!/^\d{1,5}$/u.test(value)) {
    throw new Error(`error: invalid port number "${value}"`);
  }
  const port = Number(value);
  if (!Number.isInteger(port) || port < 1 || port > 65535) {
    throw new Error(`error: invalid port number "${value}" (must be 1-65535)`);
  }
  return port;
}

function requiredOptionValue(argv: string[], index: number, optionName: string): string {
  const value = argv[index + 1];
  if (!value || value.startsWith("-")) {
    throw new Error(`error: ${optionName} requires a value`);
  }
  return value;
}

function normalizeProviderBaseUrl(value: string): string {
  let parsed: URL;
  try {
    parsed = new URL(value);
  } catch {
    throw new Error(`error: OPENBURNBAR_PROVIDER_BASE_URL is invalid: "${value}"`);
  }
  const loopback = parsed.hostname === "127.0.0.1" || parsed.hostname === "[::1]";
  if (
    (parsed.protocol !== "https:" && !(parsed.protocol === "http:" && loopback)) ||
    parsed.username ||
    parsed.password ||
    parsed.search ||
    parsed.hash
  ) {
    throw new Error(
      "error: standalone provider URL must be HTTPS, or loopback HTTP for local development"
    );
  }
  return parsed.toString().replace(/\/+$/u, "");
}

function resolveStandaloneProvider(env: NodeJS.ProcessEnv): StandaloneProvider | undefined {
  const customBaseUrl = env["OPENBURNBAR_PROVIDER_BASE_URL"]?.trim();
  const customApiKey = env["OPENBURNBAR_PROVIDER_API_KEY"]?.trim();
  if (customBaseUrl || customApiKey) {
    if (!customBaseUrl || !customApiKey) {
      throw new Error(
        "error: OPENBURNBAR_PROVIDER_BASE_URL and OPENBURNBAR_PROVIDER_API_KEY must be set together"
      );
    }
    return {
      name: "custom",
      baseUrl: normalizeProviderBaseUrl(customBaseUrl),
      apiKey: customApiKey,
    };
  }

  const xaiApiKey = env["XAI_API_KEY"]?.trim();
  if (xaiApiKey) {
    return {
      name: "xai",
      baseUrl: "https://api.x.ai/v1",
      apiKey: xaiApiKey,
    };
  }
  return undefined;
}

export function parseProxyCliOptions(
  argv: string[],
  env: NodeJS.ProcessEnv = process.env
): ProxyCliOptions {
  let command: ProxyCommand = "start";
  let port = DEFAULT_PROXY_PORT;
  let host = DEFAULT_PROXY_HOST;
  const allowLocalKey = true;
  let requireToken = env["OPENBURNBAR_REQUIRE_TOKEN"] === "1";
  let token = env["OPENBURNBAR_GATEWAY_TOKEN"]?.trim() || undefined;
  let tray = false;

  let index = 0;
  if (argv[0] === "status" || argv[0] === "stop") {
    command = argv[0];
    index = 1;
  }

  for (; index < argv.length; index += 1) {
    const arg = argv[index];
    if (arg === "--port" || arg === "-p") {
      port = strictPort(requiredOptionValue(argv, index, arg));
      index += 1;
      continue;
    }
    if (arg === "--host") {
      if (command !== "start") {
        throw new Error(`error: ${command} only accepts --port`);
      }
      host = normalizeProxyHost(requiredOptionValue(argv, index, arg));
      index += 1;
      continue;
    }
    if (arg === "--require-token") {
      if (command !== "start") {
        throw new Error(`error: ${command} only accepts --port`);
      }
      requireToken = true;
      continue;
    }
    if (arg === "--token" || arg === "-t") {
      if (command !== "start") {
        throw new Error(`error: ${command} only accepts --port`);
      }
      token = requiredOptionValue(argv, index, arg);
      index += 1;
      continue;
    }
    if (arg === "--token-file") {
      if (command !== "start") {
        throw new Error(`error: ${command} only accepts --port`);
      }
      const tokenFilePath = requiredOptionValue(argv, index, arg);
      try {
        token = readSecureTokenFile(tokenFilePath);
      } catch (error) {
        throw new Error(
          `error: could not read token file "${tokenFilePath}": ${error instanceof Error ? error.message : String(error)}`
        );
      }
      index += 1;
      continue;
    }
    if (arg === "--tray") {
      if (command !== "start") {
        throw new Error(`error: ${command} only accepts --port`);
      }
      tray = true;
      continue;
    }
    if (arg === "--allow-local-key") {
      if (command !== "start") {
        throw new Error(`error: ${command} only accepts --port`);
      }
      // Allowed by default on loopback; flag accepted for backward compatibility.
      continue;
    }
    throw new Error(`error: unknown proxy argument "${arg ?? ""}"`);
  }

  if (command !== "start") {
    return { command, port, host, allowLocalKey, requireToken };
  }

  if (requireToken && !token) {
    throw new Error("error: --require-token requires a private token via --token, --token-file, or OPENBURNBAR_GATEWAY_TOKEN");
  }

  const upstreamValue = env["OPENBURNBAR_UPSTREAM"]?.trim();
  const upstreamToken = env["OPENBURNBAR_GATEWAY_TOKEN"]?.trim() || undefined;
  if (upstreamValue && !upstreamToken) {
    throw new Error(
      "error: OPENBURNBAR_UPSTREAM requires OPENBURNBAR_GATEWAY_TOKEN (the token BurnBar's gateway expects)"
    );
  }
  return {
    command,
    port,
    host,
    allowLocalKey,
    requireToken,
    token,
    tray,
    upstream: upstreamValue ? normalizeLoopbackUpstream(upstreamValue) : undefined,
    upstreamToken,
    provider: resolveStandaloneProvider(env),
  };
}

export function sanitizeProcessCommand(command: string): string {
  return command
    .replace(new RegExp(`${String.fromCharCode(27)}\\[[0-9;]*[a-zA-Z]`, "gu"), "")
    .replace(/[\p{Cc}\p{Cf}\p{Zl}\p{Zp}]/gu, " ")
    .replace(/\s+/gu, " ")
    .replace(
      /(?<![\w-])(--[\w-]*(?:token|key|secret|password|bearer|auth|credential)[\w-]*|-t|-k)(\s*[=\s]\s*)(\S+)/gi,
      "$1 [REDACTED]"
    )
    .replace(
      /\b([A-Z0-9_]*(?:TOKEN|KEY|SECRET|PASSWORD|CREDENTIAL))=(\S+)/gi,
      "$1=[REDACTED]"
    )
    .replace(/\b(Bearer|Basic)\s+[A-Za-z0-9._~+/=-]{8,}/gi, "$1 [REDACTED]")
    .replace(/\b(sk|xai|gsk|ghp|pat)-[A-Za-z0-9._-]{8,}/gi, "[REDACTED]")
    .replace(
      /(?<![\w-])(--?[\w-]*(?:pass|pwd)[\w-]*)(\s*[=\s]\s*)(\S+)/gi,
      "$1 [REDACTED]"
    )
    .replace(/\b([a-z][a-z0-9+.-]*:\/\/)([^/\s:@]+):([^/\s@]+)@/gi, "$1$2:[REDACTED]@")
    .trim()
    .slice(0, 512);
}

function resolveBin(defaults: string[]): string | null {
  for (const candidate of defaults) {
    if (existsSync(candidate)) {
      return candidate;
    }
  }
  return null;
}

export function getProcessCommand(pid: number): string | null {
  try {
    const psBin = resolveBin(["/bin/ps", "/usr/bin/ps"]);
    if (!psBin) {
      return null;
    }
    const fullCommand = execFileSync(psBin, ["-p", String(pid), "-o", "command="], {
      encoding: "utf8",
      stdio: ["ignore", "pipe", "ignore"],
      timeout: 1_500,
    }).trim();
    return fullCommand ? sanitizeProcessCommand(fullCommand) : null;
  } catch {
    return null;
  }
}

export function getProcessOnPort(port: number): ProcessPortInfo | null {
  try {
    const lsofBin = resolveBin(["/usr/sbin/lsof", "/usr/bin/lsof", "/bin/lsof"]);
    if (!lsofBin) {
      return null;
    }
    const psBin = resolveBin(["/bin/ps", "/usr/bin/ps"]);
    const stdout = execFileSync(
      lsofBin,
      ["-nP", `-iTCP@${DEFAULT_PROXY_HOST}:${port}`, "-sTCP:LISTEN", "-F", "pcn"],
      {
        encoding: "utf8",
        stdio: ["ignore", "pipe", "ignore"],
        timeout: 1_500,
      }
    );
    const pids: number[] = [];
    const commands: string[] = [];
    let currentPid: number | null = null;
    let currentCommand = "unknown";

    const flushCurrent = (): void => {
      if (currentPid !== null && !pids.includes(currentPid)) {
        pids.push(currentPid);
        let command = currentCommand;
        if (psBin) {
          try {
            const fullCommand = execFileSync(psBin, ["-p", String(currentPid), "-o", "command="], {
              encoding: "utf8",
              stdio: ["ignore", "pipe", "ignore"],
              timeout: 1_500,
            }).trim();
            if (fullCommand) {
              command = sanitizeProcessCommand(fullCommand);
            }
          } catch {
            // Keep lsof command
          }
        }
        commands.push(`PID ${currentPid} (${command})`);
      }
      currentPid = null;
      currentCommand = "unknown";
    };

    for (const line of stdout.split("\n")) {
      const tag = line[0];
      const value = line.slice(1);
      if (tag === "p") {
        flushCurrent();
        const pid = Number(value);
        if (Number.isInteger(pid) && pid > 0) {
          currentPid = pid;
        }
      } else if (tag === "c" && currentPid !== null) {
        currentCommand = sanitizeProcessCommand(value);
      }
    }
    flushCurrent();

    const firstPid = pids[0];
    if (firstPid === undefined) {
      return null;
    }
    return { pid: firstPid, command: commands.join(", ") };
  } catch {
    return null;
  }
}

function readSecureTokenFile(filePath: string): string {
  let fd: number | null = null;
  try {
    const stat = lstatSync(filePath);
    if (stat.isSymbolicLink() || !stat.isFile()) {
      throw new Error("token file must be a regular file, not a symlink");
    }
    if (typeof process.getuid === "function" && stat.uid !== process.getuid()) {
      throw new Error("token file must be owned by the current user");
    }
    if ((stat.mode & 0o077) !== 0) {
      throw new Error("token file permissions are too open (must not be group/world accessible)");
    }
    fd = openSync(filePath, "r");
    const fstat = fstatSync(fd);
    if (typeof process.getuid === "function" && fstat.uid !== process.getuid()) {
      throw new Error("token file must be owned by the current user");
    }
    if ((fstat.mode & 0o077) !== 0 || !fstat.isFile() || fstat.size > 8192) {
      throw new Error("token file must be a non-empty regular file <= 8 KiB with mode 0600");
    }
    const buffer = Buffer.alloc(fstat.size);
    readSync(fd, buffer, 0, fstat.size, 0);
    const content = buffer.toString("utf8").trim();
    if (!content) {
      throw new Error("token file is empty");
    }
    return content;
  } finally {
    if (fd !== null) {
      try {
        closeSync(fd);
      } catch {
        // Ignore
      }
    }
  }
}

function securePidDirectory(dir: string): string {
  mkdirSync(dir, { recursive: true, mode: 0o700 });
  let st: ReturnType<typeof lstatSync>;
  try {
    st = lstatSync(dir);
  } catch {
    return dir;
  }
  if (st.isSymbolicLink()) {
    throw new Error(`error: ${dir} is a symlink; refusing to store proxy ownership state there`);
  }
  if (typeof process.getuid === "function" && st.uid !== process.getuid()) {
    throw new Error(`error: ${dir} is not owned by the current user`);
  }
  if ((st.mode & 0o077) !== 0) {
    try {
      chmodSync(dir, 0o700);
    } catch {
      throw new Error(`error: ${dir} is group/world accessible and could not be tightened`);
    }
  }
  return dir;
}

export function proxyPidDirectory(): string {
  const runtimeDir = process.env["XDG_RUNTIME_DIR"];
  if (runtimeDir) {
    return securePidDirectory(join(runtimeDir, "openburnbar", "proxy"));
  }
  const home = homedir();
  if (home) {
    return securePidDirectory(join(home, ".openburnbar", "proxy"));
  }
  const uid = typeof process.getuid === "function" ? process.getuid() : "user";
  return securePidDirectory(join(tmpdir(), `openburnbar-${uid}-proxy`));
}

export function proxyPidFilePath(port: number): string {
  return join(proxyPidDirectory(), `openburnbar-proxy-${port}.json`);
}

function readPidFile(port: number): ProxyPidFile | null {
  let fd: number | null = null;
  try {
    const filePath = proxyPidFilePath(port);
    const stat = lstatSync(filePath);
    if (stat.isSymbolicLink() || !stat.isFile()) {
      return null;
    }
    if (typeof process.getuid === "function" && stat.uid !== process.getuid()) {
      return null;
    }
    if ((stat.mode & 0o022) !== 0) {
      // Refuse group- or world-writable PID files
      return null;
    }
    fd = openSync(filePath, "r");
    const fstat = fstatSync(fd);
    if (typeof process.getuid === "function" && fstat.uid !== process.getuid()) {
      return null;
    }
    if ((fstat.mode & 0o022) !== 0 || !fstat.isFile() || fstat.size > 8192) {
      return null;
    }
    const buffer = Buffer.alloc(fstat.size);
    readSync(fd, buffer, 0, fstat.size, 0);
    const parsed = JSON.parse(buffer.toString("utf8")) as Partial<ProxyPidFile>;
    if (
      parsed.version !== PID_FILE_VERSION ||
      parsed.port !== port ||
      !Number.isInteger(parsed.pid) ||
      (parsed.pid ?? 0) <= 0 ||
      typeof parsed.host !== "string" ||
      typeof parsed.token !== "string" ||
      parsed.token.length < 32 ||
      typeof parsed.startedAt !== "string"
    ) {
      return null;
    }
    return parsed as ProxyPidFile;
  } catch {
    return null;
  } finally {
    if (fd !== null) {
      try {
        closeSync(fd);
      } catch {
        // Ignore close errors
      }
    }
  }
}

function writePidFile(record: ProxyPidFile): void {
  const path = proxyPidFilePath(record.port);
  const temporaryPath = `${path}.${process.pid}.${randomBytes(6).toString("hex")}`;
  writeFileSync(temporaryPath, `${JSON.stringify(record)}\n`, {
    encoding: "utf8",
    flag: "wx",
    mode: 0o600,
  });
  renameSync(temporaryPath, path);
}

function removePidFile(record: ProxyPidFile): void {
  try {
    const existing = readPidFile(record.port);
    if (existing && existing.pid === record.pid) {
      unlinkSync(proxyPidFilePath(record.port));
    }
  } catch {
    // Ignore cleanup errors
  }
}

function processExists(pid: number): boolean {
  try {
    process.kill(pid, 0);
    return true;
  } catch {
    return false;
  }
}

async function getHealth(
  port: number,
  headers: Record<string, string> = {}
): Promise<Partial<ProxyHealth> | null> {
  const MAX_HEALTH_BYTES = 64 * 1024;
  return new Promise((resolve) => {
    let finished = false;
    const finish = (result: Partial<ProxyHealth> | null): void => {
      if (!finished) {
        finished = true;
        resolve(result);
      }
    };

    const hardStop = setTimeout(() => {
      finish(null);
    }, HEALTH_TIMEOUT_MS);
    hardStop.unref();

    const request = http.get(
      {
        host: DEFAULT_PROXY_HOST,
        port,
        path: "/health",
        headers,
        timeout: HEALTH_TIMEOUT_MS,
      },
      (res) => {
        const chunks: Buffer[] = [];
        let bytes = 0;
        res.on("data", (chunk: Buffer) => {
          bytes += chunk.length;
          if (bytes > MAX_HEALTH_BYTES) {
            clearTimeout(hardStop);
            res.destroy();
            finish(null);
            return;
          }
          chunks.push(chunk);
        });
        res.on("end", () => {
          clearTimeout(hardStop);
          if (res.statusCode !== 200) {
            finish(null);
            return;
          }
          try {
            const raw = Buffer.concat(chunks).toString("utf8");
            finish(JSON.parse(raw) as Partial<ProxyHealth>);
          } catch {
            finish(null);
          }
        });
      }
    );
    request.on("error", () => {
      clearTimeout(hardStop);
      finish(null);
    });
    request.on("timeout", () => {
      clearTimeout(hardStop);
      request.destroy();
      finish(null);
    });
  });
}

export async function probeProxy(
  port: number,
  expectedPidFile?: ProxyPidFile | null
): Promise<Partial<ProxyHealth> | null> {
  const basic = await getHealth(port);
  if (!basic || basic.service !== PROXY_SERVICE || basic.port !== port) {
    return null;
  }
  const mode = basic.mode === "standalone" || basic.mode === "forward" ? basic.mode : undefined;
  const provider =
    typeof basic.provider === "string" && basic.provider.length <= 64
      ? sanitizeProcessCommand(basic.provider)
      : undefined;
  const sanitizedBasic: Partial<ProxyHealth> = {
    ...basic,
    mode,
    provider,
    requireToken: basic.requireToken,
  };
  if (!expectedPidFile) {
    return sanitizedBasic;
  }
  if (basic.pid !== expectedPidFile.pid) {
    return null;
  }
  if (!processExists(expectedPidFile.pid)) {
    return null;
  }
  const holder = getProcessOnPort(port);
  if (holder && holder.pid !== expectedPidFile.pid) {
    return null;
  }
  const detailed = await getHealth(port, {
    [PROXY_CONTROL_HEADER]: expectedPidFile.token,
  });
  if (!detailed || detailed.instance !== true || detailed.pid !== expectedPidFile.pid) {
    return null;
  }
  return { ...detailed, mode, provider, requireToken: detailed.requireToken ?? basic.requireToken };
}

export async function runProxyStatus(port = DEFAULT_PROXY_PORT): Promise<number> {
  const pidFile = readPidFile(port);
  const health = await probeProxy(port, pidFile);
  const owned = Boolean(pidFile && health && health.instance === true);
  const processInfo = getProcessOnPort(port);
  const payload = health
    ? buildProxyStatusPayload({
        port,
        listening: true,
        pid: health.pid,
        mode: health.mode,
        provider: health.provider,
        requireToken: health.requireToken,
        configured: health.mode === "forward" || Boolean(health.provider),
      })
    : buildProxyStatusPayload({
        port,
        listening: false,
        occupied: Boolean(processInfo),
        pid: processInfo?.pid,
        command: processInfo?.command,
        configured: false,
      });
  process.stdout.write(`${JSON.stringify(payload)}\n`);
  return owned ? 0 : 1;
}

function delay(milliseconds: number): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, milliseconds));
}

function signal(pid: number, sig: NodeJS.Signals): "sent" | "gone" | "denied" {
  try {
    process.kill(pid, sig);
    return "sent";
  } catch (error) {
    const code = (error as NodeJS.ErrnoException).code;
    if (code === "ESRCH") {
      return "gone";
    }
    if (code === "EPERM") {
      return "denied";
    }
    throw error;
  }
}

export async function runProxyStop(port = DEFAULT_PROXY_PORT): Promise<number> {
  const pidFile = readPidFile(port);
  const processInfo = getProcessOnPort(port);
  if (!pidFile) {
    if (processInfo) {
      process.stderr.write(
        `Refusing to stop PID ${processInfo.pid} (${processInfo.command}): port ${port} is not owned by an OpenBurnBar proxy pid file.\n`
      );
      return 1;
    }
    process.stdout.write(`OpenBurnBar proxy is not running on port ${port}.\n`);
    return 0;
  }
  if (processInfo && processInfo.pid !== pidFile.pid) {
    process.stderr.write(
      `Refusing to stop PID ${processInfo.pid} (${processInfo.command}): port ${port} is not owned by this OpenBurnBar proxy instance.\n`
    );
    return 1;
  }
  if (!processExists(pidFile.pid)) {
    removePidFile(pidFile);
    process.stdout.write(`OpenBurnBar proxy stopped on port ${port} (PID ${pidFile.pid}).\n`);
    return 0;
  }

  if (!processInfo) {
    const health = await getHealth(port, { [PROXY_CONTROL_HEADER]: pidFile.token });
    if (!health?.instance || health.pid !== pidFile.pid) {
      removePidFile(pidFile);
      process.stderr.write(
        `Refusing to stop PID ${pidFile.pid}: nothing is listening on port ${port} and the ` +
        `recorded PID did not answer the instance-token challenge. Removed stale PID file.\n`
      );
      return 1;
    }
  }

  const cmd = getProcessCommand(pidFile.pid);
  if (!cmd || (!cmd.includes("openburnbar") && !cmd.includes("proxy"))) {
    const health = await getHealth(port, { [PROXY_CONTROL_HEADER]: pidFile.token });
    if (!health?.instance || health.pid !== pidFile.pid) {
      removePidFile(pidFile);
      process.stderr.write(
        `Refusing to stop PID ${pidFile.pid}: could not confirm process identity. Removed stale PID file.\n`
      );
      return 1;
    }
  }

  const termResult = signal(pidFile.pid, "SIGTERM");
  if (termResult === "gone") {
    removePidFile(pidFile);
    process.stdout.write(`OpenBurnBar proxy stopped on port ${port} (PID ${pidFile.pid}).\n`);
    return 0;
  }
  if (termResult === "denied") {
    process.stderr.write(`Refusing to stop PID ${pidFile.pid}: process is owned by another user.\n`);
    return 1;
  }
  for (let attempt = 0; attempt < 40; attempt += 1) {
    await delay(50);
    if (!processExists(pidFile.pid)) {
      removePidFile(pidFile);
      process.stdout.write(`OpenBurnBar proxy stopped on port ${port} (PID ${pidFile.pid}).\n`);
      return 0;
    }
  }

  const killResult = signal(pidFile.pid, "SIGKILL");
  removePidFile(pidFile);
  if (killResult === "denied") {
    process.stderr.write(`Refusing to SIGKILL PID ${pidFile.pid}: process is owned by another user.\n`);
    return 1;
  }
  process.stdout.write(`OpenBurnBar proxy stopped on port ${port} (PID ${pidFile.pid}).\n`);
  return 0;
}

function startupMode(options: ProxyOptions): string {
  if (options.upstream) {
    return `openburnbar proxy forward :${options.port} -> ${options.upstream}`;
  }
  return `openburnbar proxy standalone :${options.port} (${options.provider?.name ?? "provider not configured"})`;
}

export async function runProxyServer(options: ProxyOptions): Promise<void> {
  const host = normalizeProxyHost(options.host);
  const instanceToken = options.instanceToken ?? randomBytes(32).toString("hex");
  const serverOptions = { ...options, host, instanceToken };
  const server = createProxyServer(serverOptions);
  const pidFile: ProxyPidFile = {
    version: PID_FILE_VERSION,
    pid: process.pid,
    port: options.port,
    host,
    token: instanceToken,
    startedAt: new Date().toISOString(),
  };

  let trayChild: ChildProcess | null = null;
  let shuttingDown = false;
  let listening = false;
  let resolveClose: (() => void) | undefined;
  const closed = new Promise<void>((resolve) => {
    resolveClose = resolve;
  });

  const trayOptions = {
    port: options.port,
    parentPid: process.pid,
    nodePath: process.execPath,
    cliPath: fileURLToPath(new URL("./index.js", import.meta.url)),
    token: options.token ?? (options.requireToken ? undefined : LOCAL_CLIPROXY_KEY),
    isStopping: () => shuttingDown,
  };

  const shutdown = (): void => {
    if (shuttingDown) {
      return;
    }
    shuttingDown = true;
    if (trayChild && trayChild.exitCode === null && !trayChild.killed) {
      trayChild.kill("SIGTERM");
    }
    if (listening) {
      const forceClose = setTimeout(() => server.closeAllConnections(), 1_000);
      forceClose.unref();
      server.close(() => {
        removePidFile(pidFile);
        clearTimeout(forceClose);
        resolveClose?.();
      });
      return;
    }
    resolveClose?.();
  };

  process.once("SIGINT", shutdown);
  process.once("SIGTERM", shutdown);
  process.once("SIGHUP", shutdown);

  let preparedTray: { executable: string } | null = null;
  if (options.tray && process.platform === "darwin") {
    preparedTray = await ensureGatewayTrayApp(trayOptions);
  }
  if (shuttingDown) {
    process.off("SIGINT", shutdown);
    process.off("SIGTERM", shutdown);
    process.off("SIGHUP", shutdown);
    return;
  }

  await new Promise<void>((resolve, reject) => {
    const handleStartupError = (error: NodeJS.ErrnoException): void => {
      if (error.code === "EADDRINUSE") {
        const processInfo = getProcessOnPort(options.port);
        const holder = processInfo
          ? `PID ${processInfo.pid} (${processInfo.command})`
          : "another process";
        reject(
          Object.assign(
            new Error(
              `Port ${options.port} is already in use by ${holder}. Stop that process or pass --port; OpenBurnBar will not bind 8317.`
            ),
            { exitCode: 1 }
          )
        );
        return;
      }
      reject(error);
    };
    server.once("error", handleStartupError);
    server.listen({ port: options.port, host }, () => {
      server.off("error", handleStartupError);
      server.on("error", (err) => {
        process.stderr.write(`[OpenBurnBar Proxy] Server error: ${err.message}\n`);
      });
      if (shuttingDown) {
        server.close();
        removePidFile(pidFile);
        resolveClose?.();
        resolve();
        return;
      }
      try {
        writePidFile(pidFile);
      } catch (error) {
        server.close();
        reject(
          new Error(
            `Proxy bound port ${options.port} but could not create its ownership pid file: ${error instanceof Error ? error.message : String(error)}`
          )
        );
        return;
      }
      listening = true;
      process.stdout.write(`${startupMode(serverOptions)}\n`);
      resolve();
    });
  });

  if (preparedTray && !shuttingDown) {
    trayChild = spawnGatewayTray(preparedTray.executable, trayOptions);
  } else if (options.tray && process.platform !== "darwin" && !shuttingDown) {
    await openLoopbackPanel(options.port);
  }

  server.once("close", () => {
    removePidFile(pidFile);
    process.off("SIGINT", shutdown);
    process.off("SIGTERM", shutdown);
    process.off("SIGHUP", shutdown);
    resolveClose?.();
  });
  await closed;
}

export async function runProxyCli(
  argv: string[],
  runtime: ProxyCliRuntime = {}
): Promise<number> {
  const writeStderr = runtime.writeStderr ?? ((text: string) => process.stderr.write(text));
  if (
    argv.length === 1 &&
    (argv[0] === "--help" || argv[0] === "-h" || argv[0] === "help")
  ) {
    process.stdout.write(PROXY_USAGE);
    return 0;
  }
  try {
    if (argv[0] === "wire" || argv[0] === "unwire") {
      return await runProxyWireCli(argv);
    }
    const options = parseProxyCliOptions(argv, runtime.env ?? process.env);
    if (options.command === "status") {
      return await runProxyStatus(options.port);
    }
    if (options.command === "stop") {
      return await runProxyStop(options.port);
    }
    await runProxyServer(options);
    return 0;
  } catch (error) {
    writeStderr(`${error instanceof Error ? error.message : String(error)}\n`);
    const exitCode = (error as { exitCode?: unknown }).exitCode;
    return typeof exitCode === "number" ? exitCode : 2;
  }
}

export {
  DEFAULT_PROXY_HOST,
  DEFAULT_PROXY_PORT,
  LOCAL_CLIPROXY_KEY,
  MAX_PROXY_BODY_BYTES,
  NON_STREAM_FETCH_TIMEOUT_MS,
  REQUEST_TOO_LARGE_MESSAGE,
  anthropicGatewayUrl,
  containsUnsafeDisplayText,
  createProxyServer,
  isAuthorized,
  isLoopbackHttpUrl,
  isLoopbackIp,
  isProxyConfigured,
  normalizeLoopbackUpstream,
  openaiGatewayUrl,
  allProxySnippetText,
  proxySnippets,
};

export type { ProxyOptions, StandaloneProvider };
