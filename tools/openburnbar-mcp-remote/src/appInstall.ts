import { createHash, createPublicKey, verify } from "node:crypto";
import { createWriteStream, existsSync, mkdirSync, mkdtempSync, readFileSync, readdirSync, renameSync, rmSync } from "node:fs";
import { homedir, tmpdir as osTmpdir } from "node:os";
import { dirname, join } from "node:path";
import { Readable } from "node:stream";
import { finished } from "node:stream/promises";
import { fileURLToPath } from "node:url";
import { spawn } from "node:child_process";

/**
 * Same public feed the notarized Mac app fetches
 * (`OpenBurnBarDirectUpdateFeedURL` / `DirectDownloadUpdateChecker.defaultFeedURL`).
 * Never pin a marketing version here — when the feed moves to 1.0.35 (or newer),
 * `app install` / `app update` follow it.
 */
export const DEFAULT_MACOS_FEED_URL = "https://downloads.burnbar.ai/latest-macos.json";
export const DEFAULT_APPLICATIONS_DIR = "/Applications";
export const APP_BUNDLE_NAME = "OpenBurnBar.app";
export const APP_BUNDLE_ID = "com.openburnbar.app";
export const HOMEBREW_CASK_RECEIPT_DIRS = [
  "/opt/homebrew/Caskroom/openburnbar",
  "/usr/local/Caskroom/openburnbar",
  join(homedir(), ".homebrew", "Caskroom", "openburnbar")
];
/** Sparkle `SUPublicEDKey` pinned in `AgentLens/Resources/OpenBurnBar-Info.plist`. */
export const SU_PUBLIC_ED_KEY_BASE64 = "613YSraDEJ54LKsfpqbYhyzYnfYRg7z4QwiEJfoy0TI="; // gitleaks:allow

const SHA256_HEX = /^[a-f0-9]{64}$/u;
const NUMERIC_VERSION = /^\d+(?:\.\d+){0,3}$/u;
const ED25519_SPKI_PREFIX = Buffer.from("302a300506032b6570032100", "hex");
const MAX_DMG_BYTES = 4 * 1024 * 1024 * 1024;
const FIRST_PARTY_HOSTS = new Set(["downloads.burnbar.ai", "dl.openburnbar.app"]);
const GITHUB_RELEASE_CDN_HOSTS = new Set([
  "objects.githubusercontent.com",
  "release-assets.githubusercontent.com",
  "github-releases.githubusercontent.com"
]);
const GITHUB_RELEASE_ASSET = /^\/Imagine-That-Ai\/BurnBar\/releases\/(?:latest\/download|download\/[^/%]+)\/[^/]+$/u;
const GITHUB_FEED_ASSET = /^\/Imagine-That-Ai\/BurnBar\/releases\/(?:latest\/download|download\/[^/%]+)\/latest-macos\.json$/u;

export type AppCommand = "install" | "update";

export type MacOSReleaseFeed = {
  version: string;
  build: string;
  downloadUrl: string;
  sha256: string;
  length: number;
  sparkleEdSignature: string;
  minimumSystemVersion: string;
  dmg?: string;
  critical: boolean;
};

export type InstalledBundle = {
  version: string;
  build: string;
  bundleId: string;
};

export type CommandResult = {
  status: number;
  stdout: string;
  stderr: string;
};

export type AppCliOptions = {
  dryRun: boolean;
  feedUrl?: string;
  applicationsDir?: string;
};

export type AppInstallDeps = {
  fetch: typeof fetch;
  platform: NodeJS.Platform;
  applicationsDir: string;
  feedUrl: string;
  tmpdir: string;
  publicKeyBase64: string;
  homebrewReceiptDirs: string[];
  write: (text: string) => void;
  writeErr: (text: string) => void;
  exists: (path: string) => boolean;
  mkdir: (path: string) => void;
  mkdtemp: (prefix: string) => string;
  rm: (path: string) => void;
  readFile: (path: string) => Buffer;
  readdir: (path: string) => string[];
  rename: (from: string, to: string) => void;
  run: (command: string, args: string[]) => Promise<CommandResult>;
};

export class AppInstallError extends Error {
  readonly exitCode: number;
  constructor(message: string, exitCode = 1) {
    super(message);
    this.name = "AppInstallError";
    this.exitCode = exitCode;
  }
}

export function packageVersion(): string {
  const pkgPath = join(dirname(fileURLToPath(import.meta.url)), "../package.json");
  const pkg = JSON.parse(readFileSync(pkgPath, "utf8")) as { version?: string };
  return typeof pkg.version === "string" && pkg.version.length > 0 ? pkg.version : "0.0.0";
}

export function userAgent(): string {
  return `OpenBurnBar-CLI/${packageVersion()}`;
}

export function parseAppCliOptions(argv: string[]): AppCliOptions {
  const options: AppCliOptions = { dryRun: false };
  for (let i = 0; i < argv.length; i += 1) {
    const arg = argv[i];
    if (arg === "--dry-run") {
      options.dryRun = true;
      continue;
    }
    if (arg === "--feed-url" || arg === "--applications-dir") {
      const value = argv[i + 1];
      if (!value || value.startsWith("--")) {
        throw new AppInstallError(`${arg} requires a value`, 2);
      }
      i += 1;
      if (arg === "--feed-url") {
        options.feedUrl = value;
      } else {
        options.applicationsDir = value;
      }
      continue;
    }
    throw new AppInstallError(`unknown option: ${arg}`, 2);
  }
  return options;
}

export function resolveFeedUrl(explicit?: string): string {
  const raw = explicit ?? process.env.OPENBURNBAR_APP_FEED_URL ?? DEFAULT_MACOS_FEED_URL;
  if (!isAllowedFeedUrl(raw)) {
    throw new AppInstallError(
      `Refusing feed URL ${raw}. Use the desktop HTTPS feed (https://downloads.burnbar.ai/latest-macos.json) or another first-party / official GitHub Releases latest-macos.json.`,
      2
    );
  }
  return raw;
}

export function resolveApplicationsDir(explicit?: string): string {
  return explicit ?? process.env.OPENBURNBAR_APPLICATIONS_DIR ?? DEFAULT_APPLICATIONS_DIR;
}

export function isAllowedFeedUrl(raw: string): boolean {
  return isAllowedHttpsUrl(raw, "feed");
}

export function isAllowedDownloadUrl(raw: string): boolean {
  return isAllowedHttpsUrl(raw, "download");
}

export function isAllowedFeedResponseUrl(originalUrl: string, finalUrl: string): boolean {
  if (isAllowedFeedUrl(finalUrl)) {
    return true;
  }
  if (!isAllowedFeedUrl(originalUrl)) {
    return false;
  }
  let original: URL;
  let final: URL;
  try {
    original = new URL(originalUrl);
    final = new URL(finalUrl);
  } catch {
    return false;
  }
  return original.hostname.toLowerCase() === "github.com"
    && GITHUB_FEED_ASSET.test(original.pathname)
    && GITHUB_RELEASE_CDN_HOSTS.has(final.hostname.toLowerCase())
    && final.pathname.endsWith("/latest-macos.json");
}

function isAllowedHttpsUrl(raw: string, kind: "feed" | "download"): boolean {
  let url: URL;
  try {
    url = new URL(raw);
  } catch {
    return false;
  }
  if (url.protocol !== "https:") {
    return false;
  }
  if (url.username || url.password) {
    return false;
  }
  const host = url.hostname.toLowerCase();
  if (FIRST_PARTY_HOSTS.has(host)) {
    return true;
  }
  if (host === "github.com") {
    return kind === "feed" ? GITHUB_FEED_ASSET.test(url.pathname) : GITHUB_RELEASE_ASSET.test(url.pathname);
  }
  return kind === "download" && GITHUB_RELEASE_CDN_HOSTS.has(host);
}

export function parseMacOSReleaseFeed(json: unknown): MacOSReleaseFeed {
  if (!json || typeof json !== "object") {
    throw new AppInstallError("Update feed is not a JSON object.");
  }
  const record = json as Record<string, unknown>;
  const version = requiredString(record, "version");
  const build = requiredString(record, "build");
  const downloadUrl = requiredString(record, "downloadUrl");
  // Digest always comes from the fetched feed JSON — never a baked DMG hash.
  const sha256 = requiredString(record, "sha256").toLowerCase();
  const length = requiredPositiveInt(record, "length");
  const signature = optionalString(record, "sparkleEdSignature");
  const minimumSystemVersion = requiredString(record, "minimumSystemVersion");
  if (!signature) {
    throw new AppInstallError("Update feed is missing sparkleEdSignature; refusing to download.");
  }
  if (!SHA256_HEX.test(sha256)) {
    throw new AppInstallError("Update feed sha256 is not a 64-character hex digest.");
  }
  if (length > MAX_DMG_BYTES) {
    throw new AppInstallError(`Update feed length ${length} exceeds the ${MAX_DMG_BYTES} byte safety cap.`);
  }
  if (!NUMERIC_VERSION.test(minimumSystemVersion)) {
    throw new AppInstallError("Update feed minimumSystemVersion must be a numeric macOS version.");
  }
  const dmg = optionalString(record, "dmg");
  return {
    version,
    build,
    downloadUrl,
    sha256,
    length,
    sparkleEdSignature: signature,
    minimumSystemVersion,
    dmg: dmg || undefined,
    critical: record.critical === true
  };
}

export function assertWellFormedRelease(release: MacOSReleaseFeed): void {
  if (!isAllowedDownloadUrl(release.downloadUrl)) {
    throw new AppInstallError(
      `Refusing download URL ${release.downloadUrl}. The public DMG must be HTTPS on downloads.burnbar.ai, dl.openburnbar.app, or Imagine-That-Ai/BurnBar GitHub Releases.`,
      1
    );
  }
}

export function compareNumericVersion(left: string, right: string): number {
  const leftParts = left.split(".").map((part) => Number.parseInt(part, 10));
  const rightParts = right.split(".").map((part) => Number.parseInt(part, 10));
  const n = Math.max(leftParts.length, rightParts.length);
  for (let i = 0; i < n; i += 1) {
    const a = Number.isFinite(leftParts[i]) ? leftParts[i] as number : 0;
    const b = Number.isFinite(rightParts[i]) ? rightParts[i] as number : 0;
    if (a !== b) {
      return a > b ? 1 : -1;
    }
  }
  return 0;
}

export function isNewerRelease(
  remote: Pick<MacOSReleaseFeed, "build" | "version">,
  local: Pick<InstalledBundle, "build" | "version">
): boolean {
  const remoteBuild = Number.parseInt(remote.build, 10);
  const localBuild = Number.parseInt(local.build, 10);
  if (Number.isFinite(remoteBuild) && Number.isFinite(localBuild) && remoteBuild !== localBuild) {
    return remoteBuild > localBuild;
  }
  return compareNumericVersion(remote.version, local.version) > 0;
}

export function parseMountPoint(plistText: string): string | undefined {
  const matches = [...plistText.matchAll(/<key>mount-point<\/key>\s*<string>([^<]+)<\/string>/gu)];
  const points = matches.map((match) => match[1]).filter((point): point is string => Boolean(point && point.length > 0));
  if (points.length === 0) {
    return undefined;
  }
  return points.reduce((longest, point) => (point.length > longest.length ? point : longest));
}

export function plistString(xml: string, key: string): string | undefined {
  const escaped = key.replace(/[.*+?^${}()|[\]\\]/gu, "\\$&");
  const match = new RegExp(`<key>${escaped}</key>\\s*<string>([^<]*)</string>`, "u").exec(xml);
  const value = match?.[1]?.trim();
  return value && value.length > 0 ? value : undefined;
}

export function readInstalledBundle(applicationsDir: string, deps: Pick<AppInstallDeps, "exists" | "readFile">): InstalledBundle | null {
  const plistPath = join(applicationsDir, APP_BUNDLE_NAME, "Contents", "Info.plist");
  if (!deps.exists(plistPath)) {
    return null;
  }
  const xml = deps.readFile(plistPath).toString("utf8");
  const version = plistString(xml, "CFBundleShortVersionString");
  const build = plistString(xml, "CFBundleVersion");
  const bundleId = plistString(xml, "CFBundleIdentifier");
  if (!version || !build || !bundleId) {
    return null;
  }
  return { version, build, bundleId };
}

export function verifyArtifactBytes(
  data: Buffer,
  release: Pick<MacOSReleaseFeed, "length" | "sha256" | "sparkleEdSignature">,
  publicKeyBase64: string = SU_PUBLIC_ED_KEY_BASE64
): void {
  if (release.length > 0 && data.length !== release.length) {
    throw new AppInstallError(
      `Downloaded file is ${data.length} bytes but the feed advertised ${release.length} bytes.`
    );
  }
  const digest = createHash("sha256").update(data).digest("hex");
  if (digest !== release.sha256.toLowerCase()) {
    throw new AppInstallError(
      `SHA-256 mismatch: got ${digest}, feed advertised ${release.sha256.toLowerCase()}.`
    );
  }
  const signature = Buffer.from(release.sparkleEdSignature, "base64");
  if (signature.length !== 64) {
    throw new AppInstallError("Update Ed25519 signature is not valid base64 or has the wrong size.");
  }
  const keyBytes = Buffer.from(publicKeyBase64, "base64");
  if (keyBytes.length !== 32) {
    throw new AppInstallError("Bundled SUPublicEDKey is not a 32-byte Ed25519 public key.");
  }
  const key = createPublicKey({
    key: Buffer.concat([ED25519_SPKI_PREFIX, keyBytes]),
    format: "der",
    type: "spki"
  });
  if (!verify(null, data, key, signature)) {
    throw new AppInstallError("Ed25519 signature does not verify against the pinned SUPublicEDKey.");
  }
}

export function createDefaultDeps(overrides: Partial<AppInstallDeps> = {}): AppInstallDeps {
  return {
    fetch,
    platform: process.platform,
    applicationsDir: DEFAULT_APPLICATIONS_DIR,
    feedUrl: DEFAULT_MACOS_FEED_URL,
    tmpdir: osTmpdir(),
    publicKeyBase64: SU_PUBLIC_ED_KEY_BASE64,
    homebrewReceiptDirs: HOMEBREW_CASK_RECEIPT_DIRS,
    write: (text) => {
      process.stdout.write(text);
    },
    writeErr: (text) => {
      process.stderr.write(text);
    },
    exists: existsSync,
    mkdir: (path) => {
      mkdirSync(path, { recursive: true });
    },
    mkdtemp: (prefix) => mkdtempSync(prefix),
    rm: (path) => {
      rmSync(path, { recursive: true, force: true });
    },
    readFile: (path) => readFileSync(path),
    readdir: (path) => readdirSync(path),
    rename: renameSync,
    run: runProcess,
    ...overrides
  };
}

export async function runAppCommand(
  command: AppCommand,
  options: AppCliOptions = { dryRun: false },
  depOverrides: Partial<AppInstallDeps> = {}
): Promise<number> {
  const deps = createDefaultDeps(depOverrides);
  try {
    deps.feedUrl = resolveFeedUrl(options.feedUrl ?? deps.feedUrl);
    deps.applicationsDir = resolveApplicationsDir(options.applicationsDir ?? deps.applicationsDir);
    if (deps.platform !== "darwin" && !options.dryRun) {
      throw new AppInstallError(
        `openburnbar app ${command} only supports macOS. It fetches the public notarized DMG from the desktop update feed and copies OpenBurnBar.app to ${join(deps.applicationsDir, APP_BUNDLE_NAME)}.`,
        2
      );
    }

    deps.writeErr(`Fetching update feed ${deps.feedUrl}\n`);
    const release = await fetchLatestRelease(deps);
    assertWellFormedRelease(release);
    const destination = join(deps.applicationsDir, APP_BUNDLE_NAME);
    const installed = readInstalledBundle(deps.applicationsDir, deps);
    if (deps.exists(destination) && !installed) {
      throw new AppInstallError(
        `${destination} exists but its bundle identity could not be read; refusing to replace it.`,
        1
      );
    }
    if (installed && installed.bundleId !== APP_BUNDLE_ID) {
      throw new AppInstallError(
        `${destination} has bundle identifier ${installed.bundleId}; expected ${APP_BUNDLE_ID}. Refusing to replace it.`,
        1
      );
    }

    if (options.dryRun) {
      printPlan(deps, command, release, destination, installed);
      return 0;
    }

    if (command === "update" && !installed) {
      throw new AppInstallError(
        `No ${APP_BUNDLE_NAME} in ${deps.applicationsDir}. Run \`openburnbar app install\` first.`,
        2
      );
    }
    if (installed && !isNewerRelease(release, installed)) {
      deps.write(
        `OpenBurnBar ${installed.version} (build ${installed.build}) is already installed at ${destination}. Feed has ${release.version} (build ${release.build}); nothing to ${command}.\n`
      );
      return 0;
    }

    if (installed) {
      assertReplaceableInstallChannel(destination, deps);
      await assertInstallProcessesStopped(destination, deps);
    }
    await assertSupportedMacOS(release, deps);

    const workDir = deps.mkdtemp(join(deps.tmpdir, "OpenBurnBarAppInstall-"));
    const dmgPath = join(workDir, "OpenBurnBar-update.dmg");
    try {
      deps.writeErr(`Downloading OpenBurnBar ${release.version} (build ${release.build})\n`);
      await downloadArtifact(release, dmgPath, deps);
      const bytes = deps.readFile(dmgPath);
      deps.writeErr("Verifying SHA-256 and Ed25519 signature\n");
      verifyArtifactBytes(bytes, release, deps.publicKeyBase64);
      deps.writeErr(`Installing to ${destination}\n`);
      await installVerifiedDmg(dmgPath, destination, release, installed, deps);
    } finally {
      deps.rm(workDir);
    }
    deps.write(`Installed OpenBurnBar ${release.version} (build ${release.build}) to ${destination}.\n`);
    return 0;
  } catch (error) {
    const message = error instanceof Error ? error.message : String(error);
    const exitCode = error instanceof AppInstallError ? error.exitCode : 1;
    deps.writeErr(`${message}\n`);
    return exitCode;
  }
}

async function fetchLatestRelease(deps: AppInstallDeps): Promise<MacOSReleaseFeed> {
  const response = await deps.fetch(deps.feedUrl, {
    headers: { Accept: "application/json", "User-Agent": userAgent() },
    redirect: "follow"
  });
  if (!response.ok) {
    throw new AppInstallError(`Update feed returned HTTP ${response.status}.`);
  }
  const finalUrl = response.url && response.url.length > 0 ? response.url : deps.feedUrl;
  if (!isAllowedFeedResponseUrl(deps.feedUrl, finalUrl)) {
    throw new AppInstallError(`Update feed redirected to a disallowed URL: ${finalUrl}`);
  }
  let json: unknown;
  try {
    json = await response.json();
  } catch {
    throw new AppInstallError("Update feed was not valid JSON.");
  }
  return parseMacOSReleaseFeed(json);
}

function printPlan(
  deps: AppInstallDeps,
  command: AppCommand,
  release: MacOSReleaseFeed,
  destination: string,
  installed: InstalledBundle | null
): void {
  deps.write(`openburnbar app ${command} --dry-run\n`);
  deps.write(`feed: ${deps.feedUrl}\n`);
  deps.write(`version: ${release.version}\n`);
  deps.write(`build: ${release.build}\n`);
  deps.write(`dmg: ${release.downloadUrl}\n`);
  deps.write(`sha256: ${release.sha256}\n`);
  deps.write(`length: ${release.length}\n`);
  deps.write(`minimum macOS: ${release.minimumSystemVersion}\n`);
  deps.write(`destination: ${destination}\n`);
  if (installed) {
    deps.write(`installed: ${installed.version} (build ${installed.build})\n`);
  } else {
    deps.write("installed: none\n");
  }
}

function assertReplaceableInstallChannel(destination: string, deps: AppInstallDeps): void {
  const macAppStoreReceipt = join(destination, "Contents", "_MASReceipt", "receipt");
  if (deps.exists(macAppStoreReceipt)) {
    throw new AppInstallError(
      `${destination} is a Mac App Store installation. Update it through the Mac App Store; the direct-download installer will not replace it.`,
      2
    );
  }
  const homebrewReceipt = deps.homebrewReceiptDirs.find((path) => deps.exists(path));
  if (homebrewReceipt) {
    throw new AppInstallError(
      `${destination} is managed by Homebrew (${homebrewReceipt}). Run \`brew upgrade --cask openburnbar\`; the direct-download installer will not desynchronize the Caskroom.`,
      2
    );
  }
}

async function assertInstallProcessesStopped(destination: string, deps: AppInstallDeps): Promise<void> {
  const checks = [
    {
      label: "OpenBurnBar",
      args: ["-x", "OpenBurnBar"]
    },
    {
      label: "the bundled OpenBurnBar daemon",
      args: ["-f", join(destination, "Contents", "Helpers", "OpenBurnBarDaemon")]
    }
  ];
  for (const check of checks) {
    const result = await deps.run("/usr/bin/pgrep", check.args);
    if (result.status === 0) {
      throw new AppInstallError(
        `${check.label} is running. Quit OpenBurnBar completely, then run the command again; the installer will not replace a live app bundle.`,
        2
      );
    }
    if (result.status !== 1) {
      throw new AppInstallError(
        `Could not verify that ${check.label} is stopped. pgrep exited ${result.status}: ${result.stderr || result.stdout}`,
        1
      );
    }
  }
}

async function assertSupportedMacOS(release: MacOSReleaseFeed, deps: AppInstallDeps): Promise<void> {
  const result = await deps.run("/usr/bin/sw_vers", ["-productVersion"]);
  if (result.status !== 0) {
    throw new AppInstallError(`Could not determine the installed macOS version. ${result.stderr || result.stdout}`);
  }
  const installedVersion = result.stdout.trim();
  if (!NUMERIC_VERSION.test(installedVersion)) {
    throw new AppInstallError(`Could not parse the installed macOS version: ${installedVersion || "(empty)"}.`);
  }
  if (compareNumericVersion(installedVersion, release.minimumSystemVersion) < 0) {
    throw new AppInstallError(
      `OpenBurnBar ${release.version} requires macOS ${release.minimumSystemVersion} or newer; this Mac is running ${installedVersion}.`,
      2
    );
  }
}

async function downloadArtifact(release: MacOSReleaseFeed, destination: string, deps: AppInstallDeps): Promise<void> {
  const response = await deps.fetch(release.downloadUrl, {
    headers: { "User-Agent": userAgent() },
    redirect: "follow"
  });
  if (!response.ok) {
    throw new AppInstallError(`DMG download returned HTTP ${response.status}.`);
  }
  const finalUrl = response.url && response.url.length > 0 ? response.url : release.downloadUrl;
  if (!isAllowedDownloadUrl(finalUrl)) {
    throw new AppInstallError(`DMG download redirected to a disallowed URL: ${finalUrl}`);
  }
  if (!response.body) {
    throw new AppInstallError("DMG download had an empty body.");
  }

  deps.mkdir(dirname(destination));
  const hash = createHash("sha256");
  const out = createWriteStream(destination);
  let written = 0;
  let lastPercent = -1;
  try {
    const nodeStream = Readable.fromWeb(response.body as import("node:stream/web").ReadableStream<Uint8Array>);
    for await (const chunk of nodeStream) {
      const buf = Buffer.isBuffer(chunk) ? chunk : Buffer.from(chunk);
      written += buf.length;
      if (written > release.length) {
        throw new AppInstallError(`Download exceeded advertised length ${release.length}.`);
      }
      hash.update(buf);
      const percent = release.length > 0 ? Math.floor((written / release.length) * 100) : 0;
      if (percent !== lastPercent && percent % 10 === 0) {
        lastPercent = percent;
        deps.writeErr(`Download ${percent}%\n`);
      }
      if (!out.write(buf)) {
        await new Promise<void>((resolve) => {
          out.once("drain", resolve);
        });
      }
    }
    out.end();
    await finished(out);
  } catch (error) {
    out.destroy();
    deps.rm(destination);
    throw error;
  }

  const digest = hash.digest("hex");
  if (written !== release.length) {
    throw new AppInstallError(`Downloaded file is ${written} bytes but the feed advertised ${release.length} bytes.`);
  }
  if (digest !== release.sha256.toLowerCase()) {
    throw new AppInstallError(
      `SHA-256 mismatch: got ${digest}, feed advertised ${release.sha256.toLowerCase()}.`
    );
  }
}

async function installVerifiedDmg(
  dmgPath: string,
  destination: string,
  release: MacOSReleaseFeed,
  installed: InstalledBundle | null,
  deps: AppInstallDeps
): Promise<void> {
  const parent = dirname(destination);
  if (!deps.exists(parent)) {
    throw new AppInstallError(`${parent} does not exist, so ${APP_BUNDLE_NAME} cannot be installed there.`, 1);
  }

  const attach = await deps.run("/usr/bin/hdiutil", [
    "attach",
    "-nobrowse",
    "-noautoopen",
    "-readonly",
    "-plist",
    dmgPath
  ]);
  if (attach.status !== 0) {
    throw new AppInstallError(`The disk image could not be mounted. ${attach.stderr || attach.stdout}`);
  }
  const mountPoint = parseMountPoint(attach.stdout);
  if (!mountPoint) {
    throw new AppInstallError("The disk image could not be mounted. No mount point in hdiutil output.");
  }

  try {
    const appPath = locateApp(mountPoint, deps);
    const codesign = await deps.run("/usr/bin/codesign", ["--verify", "--deep", "--strict", appPath]);
    if (codesign.status !== 0) {
      throw new AppInstallError(`The update's code signature did not validate. ${codesign.stderr || codesign.stdout}`);
    }
    const offered = readBundleAt(appPath, deps);
    if (!offered) {
      throw new AppInstallError("The update's version could not be read from the disk image.");
    }
    if (offered.bundleId !== APP_BUNDLE_ID) {
      throw new AppInstallError(
        `The update has bundle identifier ${offered.bundleId}; expected ${APP_BUNDLE_ID}.`
      );
    }
    if (offered.version !== release.version || offered.build !== release.build) {
      throw new AppInstallError(
        `The mounted app is ${offered.version} (build ${offered.build}) but the feed advertised ${release.version} (build ${release.build}).`
      );
    }
    if (installed && !isNewerRelease(offered, installed)) {
      throw new AppInstallError(
        `Refusing to install build ${offered.build} over the newer/equal build ${installed.build} already installed.`
      );
    }
    await replaceBundle(appPath, destination, deps);
    await deps.run("/usr/bin/xattr", ["-dr", "com.apple.quarantine", destination]);
  } finally {
    await deps.run("/usr/bin/hdiutil", ["detach", mountPoint, "-quiet"]);
  }
}

function locateApp(mountPoint: string, deps: Pick<AppInstallDeps, "exists" | "readdir">): string {
  const direct = join(mountPoint, APP_BUNDLE_NAME);
  if (deps.exists(direct)) {
    return direct;
  }
  const fallback = deps.readdir(mountPoint).find((name) => name.endsWith(".app"));
  if (fallback) {
    return join(mountPoint, fallback);
  }
  throw new AppInstallError("The update disk image did not contain OpenBurnBar.app.");
}

function readBundleAt(appPath: string, deps: Pick<AppInstallDeps, "exists" | "readFile">): InstalledBundle | null {
  const plistPath = join(appPath, "Contents", "Info.plist");
  if (!deps.exists(plistPath)) {
    return null;
  }
  const xml = deps.readFile(plistPath).toString("utf8");
  const version = plistString(xml, "CFBundleShortVersionString");
  const build = plistString(xml, "CFBundleVersion");
  const bundleId = plistString(xml, "CFBundleIdentifier");
  if (!version || !build || !bundleId) {
    return null;
  }
  return { version, build, bundleId };
}

async function replaceBundle(source: string, destination: string, deps: AppInstallDeps): Promise<void> {
  const stage = `${destination}.new-${process.pid}`;
  const backup = `${destination}.bak-${process.pid}`;
  deps.rm(stage);
  deps.rm(backup);
  const ditto = await deps.run("/usr/bin/ditto", [source, stage]);
  if (ditto.status !== 0) {
    deps.rm(stage);
    throw new AppInstallError(`ditto failed: ${ditto.stderr || ditto.stdout}`);
  }
  try {
    if (deps.exists(destination)) {
      deps.rename(destination, backup);
    }
    deps.rename(stage, destination);
    deps.rm(backup);
  } catch (error) {
    if (deps.exists(backup) && !deps.exists(destination)) {
      deps.rename(backup, destination);
    }
    deps.rm(stage);
    throw error;
  }
}

function requiredString(record: Record<string, unknown>, key: string): string {
  const value = record[key];
  if (typeof value !== "string" || value.trim().length === 0) {
    throw new AppInstallError(`Update feed is missing ${key}.`);
  }
  return value.trim();
}

function optionalString(record: Record<string, unknown>, key: string): string {
  const value = record[key];
  return typeof value === "string" ? value.trim() : "";
}

function requiredPositiveInt(record: Record<string, unknown>, key: string): number {
  const value = record[key];
  if (typeof value !== "number" || !Number.isFinite(value) || !Number.isInteger(value) || value <= 0) {
    throw new AppInstallError(`Update feed ${key} must be a positive integer.`);
  }
  return value;
}

function runProcess(command: string, args: string[]): Promise<CommandResult> {
  return new Promise((resolve) => {
    const child = spawn(command, args, { stdio: ["ignore", "pipe", "pipe"] });
    let stdout = "";
    let stderr = "";
    child.stdout.setEncoding("utf8");
    child.stderr.setEncoding("utf8");
    child.stdout.on("data", (chunk: string) => {
      stdout += chunk;
    });
    child.stderr.on("data", (chunk: string) => {
      stderr += chunk;
    });
    child.on("error", (error) => {
      resolve({ status: -1, stdout, stderr: error.message });
    });
    child.on("close", (code) => {
      resolve({ status: code ?? -1, stdout, stderr });
    });
  });
}
