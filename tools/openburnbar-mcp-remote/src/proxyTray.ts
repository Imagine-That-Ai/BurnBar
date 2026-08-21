import { execFile, execFileSync, spawn, type ChildProcess } from "node:child_process";
import { createHash } from "node:crypto";
import {
  chmodSync,
  existsSync,
  mkdirSync,
  readdirSync,
  readFileSync,
  writeFileSync,
} from "node:fs";
import { homedir as osHomedir } from "node:os";
import { dirname, join, relative } from "node:path";
import { fileURLToPath } from "node:url";
import { promisify } from "node:util";
import { LOCAL_CLIPROXY_KEY } from "./proxyAuth.js";

const execFileAsync = promisify(execFile);

export const TRAY_BUNDLE_ID = "ai.imaginethat.openburnbar.gateway-tray";
export const TRAY_APP_NAME = "OpenBurnBarGatewayTray.app";
export const TRAY_EXECUTABLE_NAME = "OpenBurnBarGatewayTray";
export const TRAY_SF_SYMBOL = "point.3.connected.trianglepath";
export const TRAY_ACCESSIBILITY_TITLE = "OpenBurnBar Gateway";

export const TRAY_MISSING_SWIFTC_HINT = `error: --tray needs the Xcode Command Line Tools to compile the menu-bar helper (swiftc not found).
Install them with: xcode-select --install
The gateway will keep running headless. Re-run \`openburnbar proxy --tray\` after the tools are installed.
`;

export const TRAY_MACOS_ONLY = "error: --tray is macOS-only";

export interface TrayCompileInput {
  swiftc: string;
  sources: string[];
  output: string;
}

export interface StartGatewayTrayOptions {
  port: number;
  parentPid: number;
  nodePath: string;
  cliPath: string;
  token?: string;
  platform?: NodeJS.Platform;
  homedir?: () => string;
  sourceDir?: string;
  findSwiftc?: () => string | null;
  compile?: (input: TrayCompileInput) => void | Promise<void>;
  spawnImpl?: typeof spawn;
  log?: (message: string) => void;
  isStopping?: () => boolean;
}

export function defaultTraySourceDir(): string {
  return join(dirname(fileURLToPath(import.meta.url)), "..", "macos-tray");
}

export function defaultTrayInstallDir(home = osHomedir()): string {
  return join(home, "Library", "Application Support", "OpenBurnBar", "gateway-tray", TRAY_APP_NAME);
}

export function findSwiftc(): string | null {
  try {
    const found = execFileSync("xcrun", ["--find", "swiftc"], {
      encoding: "utf8",
      stdio: ["ignore", "pipe", "ignore"],
      timeout: 5_000,
    }).trim();
    return found.length > 0 && existsSync(found) ? found : null;
  } catch {
    return null;
  }
}

export function posixRelative(from: string, to: string): string {
  return relative(from, to).split("\\").join("/");
}

export function listSourceFiles(sourceDir: string): string[] {
  const files: string[] = [];
  const walk = (dir: string): void => {
    for (const entry of readdirSync(dir, { withFileTypes: true })) {
      if (entry.name === ".build" || entry.name === ".DS_Store" || entry.name.endsWith(".app")) {
        continue;
      }
      const full = join(dir, entry.name);
      if (entry.isDirectory()) {
        walk(full);
        continue;
      }
      files.push(full);
    }
  };
  walk(sourceDir);
  return files.sort();
}

export function listSwiftCompileSources(sourceDir: string): string[] {
  return listSourceFiles(sourceDir).filter((file) => {
    const rel = posixRelative(sourceDir, file);
    return rel.startsWith("Sources/") && rel.endsWith(".swift");
  });
}

export function hostTriple(): string {
  const arch = process.arch === "arm64" ? "arm64" : "x86_64";
  return `${arch}-apple-macos13`;
}

export function hashTraySources(sourceDir: string, triple = hostTriple()): string {
  const hash = createHash("sha256");
  hash.update(triple);
  hash.update("\0");
  for (const file of listSourceFiles(sourceDir)) {
    hash.update(posixRelative(sourceDir, file));
    hash.update("\0");
    hash.update(readFileSync(file));
    hash.update("\0");
  }
  return hash.digest("hex");
}

async function defaultCompile(input: TrayCompileInput): Promise<void> {
  let sdk = "";
  try {
    const { stdout } = await execFileAsync("xcrun", ["--sdk", "macosx", "--show-sdk-path"], {
      encoding: "utf8",
      timeout: 5_000,
    });
    sdk = stdout.trim();
  } catch {
    sdk = "";
  }
  const args = [
    "-parse-as-library",
    "-O",
    "-target",
    hostTriple(),
    "-framework",
    "AppKit",
    "-framework",
    "Foundation",
    "-o",
    input.output,
    ...input.sources,
  ];
  if (sdk) {
    args.splice(4, 0, "-sdk", sdk);
  }
  await execFileAsync(input.swiftc, args, {
    timeout: 60_000,
    encoding: "utf8",
  });
}

function writeInfoPlist(appDir: string, template: string): void {
  const plistDir = join(appDir, "Contents");
  mkdirSync(plistDir, { recursive: true });
  writeFileSync(join(plistDir, "Info.plist"), template, { encoding: "utf8" });
}

export async function ensureGatewayTrayApp(
  options: StartGatewayTrayOptions
): Promise<{ executable: string } | null> {
  const platform = options.platform ?? process.platform;
  const log = options.log ?? ((message: string) => process.stderr.write(message));
  if (platform !== "darwin") {
    throw Object.assign(new Error(TRAY_MACOS_ONLY), { exitCode: 2 });
  }

  const sourceDir = options.sourceDir ?? defaultTraySourceDir();
  const appDir = defaultTrayInstallDir(options.homedir?.() ?? osHomedir());
  const executable = join(appDir, "Contents", "MacOS", TRAY_EXECUTABLE_NAME);
  const stampPath = join(appDir, "Contents", "Resources", "build.json");
  const sourceHash = hashTraySources(sourceDir);
  const find = options.findSwiftc ?? findSwiftc;

  const binaryDigest = (p: string): string =>
    createHash("sha256").update(readFileSync(p)).digest("hex");

  mkdirSync(join(appDir, "Contents", "MacOS"), { recursive: true, mode: 0o700 });
  mkdirSync(join(appDir, "Contents", "Resources"), { recursive: true, mode: 0o700 });
  writeInfoPlist(appDir, readFileSync(join(sourceDir, "Info.plist"), "utf8"));

  if (existsSync(stampPath) && existsSync(executable)) {
    try {
      const stamp = JSON.parse(readFileSync(stampPath, "utf8")) as { source: string; binary: string };
      if (stamp.source === sourceHash && stamp.binary === binaryDigest(executable)) {
        return { executable };
      }
    } catch {
      // Corrupted stamp; fall through to recompile
    }
  }

  const swiftc = find();
  if (!swiftc) {
    log(TRAY_MISSING_SWIFTC_HINT);
    return null;
  }
  try {
    const compile = options.compile ?? defaultCompile;
    const sources = listSwiftCompileSources(sourceDir);
    await compile({
      swiftc,
      sources,
      output: executable,
    });
    if (existsSync(executable)) {
      chmodSync(executable, 0o755);
      try {
        execFileSync("codesign", ["--force", "--sign", "-", executable], {
          stdio: "ignore",
          timeout: 5_000,
        });
      } catch {
        // Ad-hoc signing is best-effort; an unsigned local helper still launches.
      }
      writeFileSync(
        stampPath,
        JSON.stringify({ source: sourceHash, binary: binaryDigest(executable) }),
        { encoding: "utf8", mode: 0o600 }
      );
    }
    return { executable };
  } catch (error) {
    log(
      `error: failed to compile OpenBurnBar gateway tray: ${error instanceof Error ? error.message : String(error)}\nThe gateway will keep running headless.\n`
    );
    return null;
  }
}

export function spawnGatewayTray(
  executable: string,
  options: StartGatewayTrayOptions
): ChildProcess {
  const log = options.log ?? ((message: string) => process.stderr.write(message));
  const spawnImpl = options.spawnImpl ?? spawn;
  const token = options.token ?? LOCAL_CLIPROXY_KEY;
  const child = spawnImpl(
    executable,
    [
      "--port",
      String(options.port),
      "--parent-pid",
      String(options.parentPid),
      "--node",
      options.nodePath,
      "--cli",
      options.cliPath,
    ],
    {
      detached: false,
      stdio: ["ignore", "ignore", "inherit"],
      env: {
        PATH: process.env["PATH"] ?? "/usr/bin:/bin",
        HOME: process.env["HOME"] ?? "",
        ...(process.env["TMPDIR"] ? { TMPDIR: process.env["TMPDIR"] } : {}),
        OPENBURNBAR_GATEWAY_TOKEN: token,
      },
    }
  );
  child.on("error", (error) => {
    log(
      `error: gateway tray failed to spawn: ${error instanceof Error ? error.message : String(error)}\nThe gateway will keep running headless.\n`
    );
  });
  child.on("exit", (code, signal) => {
    if (options.isStopping?.()) {
      return;
    }
    log(`OpenBurnBar gateway tray exited (${signal ?? code ?? "null"}).\n`);
  });
  return child;
}

export async function startGatewayTray(
  options: StartGatewayTrayOptions
): Promise<ChildProcess | null> {
  const prepared = await ensureGatewayTrayApp(options);
  if (!prepared) {
    return null;
  }
  return spawnGatewayTray(prepared.executable, options);
}
