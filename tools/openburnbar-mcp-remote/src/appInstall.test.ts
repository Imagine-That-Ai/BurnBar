import assert from "node:assert/strict";
import { createHash, generateKeyPairSync, sign } from "node:crypto";
import { existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { spawn } from "node:child_process";
import test from "node:test";
import { fileURLToPath } from "node:url";
import {
  APP_BUNDLE_NAME,
  APP_BUNDLE_ID,
  DEFAULT_APPLICATIONS_DIR,
  DEFAULT_MACOS_FEED_URL,
  HOMEBREW_CASK_RECEIPT_DIRS,
  SU_PUBLIC_ED_KEY_BASE64,
  compareNumericVersion,
  isAllowedDownloadUrl,
  isAllowedFeedUrl,
  isAllowedFeedResponseUrl,
  isNewerRelease,
  parseAppCliOptions,
  parseMacOSReleaseFeed,
  parseMountPoint,
  plistString,
  readInstalledBundle,
  runAppCommand,
  verifyArtifactBytes,
  type AppInstallDeps,
  type CommandResult,
  type MacOSReleaseFeed
} from "./appInstall.js";

const HERE = dirname(fileURLToPath(import.meta.url));
const PKG_ROOT = join(HERE, "..");
const CLI = join(HERE, "index.js");
const LIVE_FEED_TEST = process.env.OPENBURNBAR_LIVE_FEED_TEST === "1";

type TestKey = {
  publicKeyBase64: string;
  sign: (data: Buffer) => string;
};

function testKey(): TestKey {
  const { publicKey, privateKey } = generateKeyPairSync("ed25519");
  const spki = publicKey.export({ type: "spki", format: "der" });
  const raw = spki.subarray(spki.length - 32);
  return {
    publicKeyBase64: raw.toString("base64"),
    sign: (data) => sign(null, data, privateKey).toString("base64")
  };
}

function sha256(data: Buffer): string {
  return createHash("sha256").update(data).digest("hex");
}

function infoPlist(version: string, build: string, bundleId = APP_BUNDLE_ID): string {
  return [
    "<?xml version=\"1.0\" encoding=\"UTF-8\"?>",
    "<plist version=\"1.0\"><dict>",
    "<key>CFBundleShortVersionString</key>",
    `<string>${version}</string>`,
    "<key>CFBundleVersion</key>",
    `<string>${build}</string>`,
    "<key>CFBundleIdentifier</key>",
    `<string>${bundleId}</string>`,
    "</dict></plist>",
    ""
  ].join("\n");
}

function writeBundle(root: string, version: string, build: string, bundleId = APP_BUNDLE_ID): string {
  const app = join(root, APP_BUNDLE_NAME);
  mkdirSync(join(app, "Contents"), { recursive: true });
  writeFileSync(join(app, "Contents", "Info.plist"), infoPlist(version, build, bundleId));
  writeFileSync(join(app, "Contents", "MacOS-placeholder"), "app");
  return app;
}

function mountPlist(mountPoint: string): string {
  return [
    "<?xml version=\"1.0\" encoding=\"UTF-8\"?>",
    "<plist version=\"1.0\"><dict>",
    "<key>system-entities</key><array>",
    "<dict><key>dev-entry</key><string>/dev/disk2</string></dict>",
    `<dict><key>mount-point</key><string>${mountPoint}</string></dict>`,
    "</array></dict></plist>",
    ""
  ].join("\n");
}

function makeRelease(bytes: Buffer, key: TestKey, overrides: Partial<MacOSReleaseFeed> = {}): MacOSReleaseFeed {
  return {
    version: "1.0.35",
    build: "135",
    downloadUrl: "https://downloads.burnbar.ai/OpenBurnBar-1.0.35-macOS.dmg",
    sha256: sha256(bytes),
    length: bytes.length,
    sparkleEdSignature: key.sign(bytes),
    minimumSystemVersion: "14.0",
    dmg: "OpenBurnBar-1.0.35-macOS.dmg",
    critical: false,
    ...overrides
  };
}

function feedJson(release: MacOSReleaseFeed): string {
  return JSON.stringify({
    appcastUrl: "https://downloads.burnbar.ai/appcast.xml",
    build: release.build,
    downloadUrl: release.downloadUrl,
    length: release.length,
    minimumSystemVersion: release.minimumSystemVersion,
    sha256: release.sha256,
    sparkleEdSignature: release.sparkleEdSignature,
    version: release.version,
    dmg: release.dmg,
    critical: release.critical
  });
}

function spawnCli(args: string[]): Promise<{ status: number; stdout: string; stderr: string }> {
  return new Promise((resolve) => {
    const child = spawn(process.execPath, [CLI, ...args], {
      cwd: PKG_ROOT,
      stdio: ["ignore", "pipe", "pipe"]
    });
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
    child.on("close", (code) => {
      resolve({ status: code ?? -1, stdout, stderr });
    });
  });
}

function harness(
  bytes: Buffer,
  release: MacOSReleaseFeed,
  key: TestKey,
  installed?: { version: string; build: string; bundleId?: string },
  mounted: { version: string; build: string; bundleId: string } = {
    version: release.version,
    build: release.build,
    bundleId: APP_BUNDLE_ID
  }
) {
  const root = mkdtempSync(join(tmpdir(), "obb-app-install-"));
  const applicationsDir = join(root, "Applications");
  const mountPoint = join(root, "Volumes", "OpenBurnBar");
  const tmp = join(root, "tmp");
  mkdirSync(applicationsDir, { recursive: true });
  mkdirSync(tmp, { recursive: true });
  if (installed) {
    writeBundle(applicationsDir, installed.version, installed.build, installed.bundleId);
  }
  const commands: Array<{ command: string; args: string[] }> = [];
  const logs: string[] = [];
  const errors: string[] = [];
  let downloads = 0;
  const homebrewReceiptDir = join(root, "homebrew", "Caskroom", "openburnbar");

  const deps: Partial<AppInstallDeps> = {
    platform: "darwin",
    applicationsDir,
    feedUrl: DEFAULT_MACOS_FEED_URL,
    tmpdir: tmp,
    publicKeyBase64: key.publicKeyBase64,
    homebrewReceiptDirs: [homebrewReceiptDir],
    write: (text) => {
      logs.push(text);
    },
    writeErr: (text) => {
      errors.push(text);
    },
    fetch: async (input) => {
      const url = String(input);
      if (url === DEFAULT_MACOS_FEED_URL || url.endsWith("latest-macos.json")) {
        return new Response(feedJson(release), {
          status: 200,
          headers: { "content-type": "application/json" }
        });
      }
      if (url === release.downloadUrl) {
        downloads += 1;
        return new Response(new Uint8Array(bytes), { status: 200 });
      }
      return new Response("not found", { status: 404 });
    },
    run: async (command, args): Promise<CommandResult> => {
      commands.push({ command, args });
      if (command === "/usr/bin/hdiutil" && args[0] === "attach") {
        writeBundle(mountPoint, mounted.version, mounted.build, mounted.bundleId);
        return { status: 0, stdout: mountPlist(mountPoint), stderr: "" };
      }
      if (command === "/usr/bin/hdiutil" && args[0] === "detach") {
        return { status: 0, stdout: "", stderr: "" };
      }
      if (command === "/usr/bin/codesign") {
        return { status: 0, stdout: "", stderr: "" };
      }
      if (command === "/usr/bin/ditto") {
        const src = args[0];
        const dest = args[1];
        if (!src || !dest) {
          return { status: 1, stdout: "", stderr: "ditto missing paths" };
        }
        mkdirSync(dirname(dest), { recursive: true });
        const plist = readFileSync(join(src, "Contents", "Info.plist"));
        mkdirSync(join(dest, "Contents"), { recursive: true });
        writeFileSync(join(dest, "Contents", "Info.plist"), plist);
        return { status: 0, stdout: "", stderr: "" };
      }
      if (command === "/usr/bin/xattr") {
        return { status: 0, stdout: "", stderr: "" };
      }
      if (command === "/usr/bin/pgrep") {
        return { status: 1, stdout: "", stderr: "" };
      }
      if (command === "/usr/bin/sw_vers") {
        return { status: 0, stdout: "14.7.6\n", stderr: "" };
      }
      return { status: 1, stdout: "", stderr: `unexpected ${command}` };
    }
  };

  return {
    root,
    applicationsDir,
    commands,
    logs,
    errors,
    deps,
    homebrewReceiptDir,
    downloads: () => downloads,
    cleanup: () => {
      rmSync(root, { recursive: true, force: true });
    }
  };
}

test("default feed URL is the desktop updater URL and is not a pinned old version", () => {
  assert.equal(DEFAULT_MACOS_FEED_URL, "https://downloads.burnbar.ai/latest-macos.json");
  assert.equal(DEFAULT_APPLICATIONS_DIR, "/Applications");
  assert.equal(APP_BUNDLE_NAME, "OpenBurnBar.app");
  assert.equal(APP_BUNDLE_ID, "com.openburnbar.app");
  assert.ok(HOMEBREW_CASK_RECEIPT_DIRS.some((path) => path.endsWith("/Caskroom/openburnbar")));
  assert.equal(SU_PUBLIC_ED_KEY_BASE64, "613YSraDEJ54LKsfpqbYhyzYnfYRg7z4QwiEJfoy0TI="); // gitleaks:allow
  const source = readFileSync(join(PKG_ROOT, "src/appInstall.ts"), "utf8");
  assert.doesNotMatch(source, /1\.0\.29/);
  assert.doesNotMatch(source, /[a-f0-9]{64}/i);
  assert.match(source, /downloads\.burnbar\.ai\/latest-macos\.json/);
});

test("package is 0.2.1 and never downloads the Mac app during npm install", () => {
  const pkg = JSON.parse(readFileSync(join(PKG_ROOT, "package.json"), "utf8")) as {
    name: string;
    version: string;
    scripts?: Record<string, string>;
  };
  assert.equal(pkg.name, "openburnbar");
  assert.equal(pkg.version, "0.2.1");
  assert.equal(pkg.scripts?.postinstall, undefined);
  assert.equal(pkg.scripts?.install, undefined);
  assert.equal(pkg.scripts?.prepare, undefined);
});

test("feed and download URL allowlists match the public Mac door", () => {
  assert.equal(isAllowedFeedUrl(DEFAULT_MACOS_FEED_URL), true);
  assert.equal(isAllowedFeedUrl("https://github.com/Imagine-That-Ai/BurnBar/releases/latest/download/latest-macos.json"), true);
  assert.equal(isAllowedFeedUrl("http://downloads.burnbar.ai/latest-macos.json"), false);
  assert.equal(isAllowedFeedUrl("https://evil.example/latest-macos.json"), false);
  assert.equal(isAllowedFeedUrl("https://github.com/evil/BurnBar/releases/latest/download/latest-macos.json"), false);
  assert.equal(
    isAllowedFeedResponseUrl(
      "https://github.com/Imagine-That-Ai/BurnBar/releases/latest/download/latest-macos.json",
      "https://release-assets.githubusercontent.com/github-production-release-asset/123/latest-macos.json?token=public"
    ),
    true
  );
  assert.equal(
    isAllowedFeedResponseUrl(
      "https://github.com/evil/BurnBar/releases/latest/download/latest-macos.json",
      "https://release-assets.githubusercontent.com/github-production-release-asset/123/latest-macos.json"
    ),
    false
  );
  assert.equal(isAllowedDownloadUrl("https://downloads.burnbar.ai/OpenBurnBar-1.0.35-macOS.dmg"), true);
  assert.equal(
    isAllowedDownloadUrl("https://github.com/Imagine-That-Ai/BurnBar/releases/latest/download/OpenBurnBar-1.0.35-macOS.dmg"),
    true
  );
  assert.equal(
    isAllowedDownloadUrl("https://github.com/Imagine-That-Ai/BurnBar/releases/download/v1.0.35/OpenBurnBar-1.0.35-macOS.dmg"),
    true
  );
  assert.equal(
    isAllowedFeedUrl("https://github.com/Imagine-That-Ai/BurnBar/releases/download/v1%2F../latest-macos.json"),
    false
  );
  assert.equal(
    isAllowedFeedUrl("https://github.com/Imagine-That-Ai/BurnBar/releases/download/v1%5Cassets/latest-macos.json"),
    false
  );
  assert.equal(
    isAllowedDownloadUrl("https://github.com/Imagine-That-Ai/BurnBar/releases/download/v1%2F../OpenBurnBar-1.0.35-macOS.dmg"),
    false
  );
  assert.equal(
    isAllowedDownloadUrl("https://github.com/Imagine-That-Ai/BurnBar/releases/download/v1%5Cassets/OpenBurnBar-1.0.35-macOS.dmg"),
    false
  );
  assert.equal(isAllowedDownloadUrl("https://github.com/evil/repo/releases/latest/download/OpenBurnBar.dmg"), false);
  assert.equal(isAllowedDownloadUrl("https://evil.example/OpenBurnBar.dmg"), false);
  assert.equal(isAllowedDownloadUrl("http://downloads.burnbar.ai/OpenBurnBar.dmg"), false);
});

test("parseMacOSReleaseFeed accepts generator JSON and refuses a missing signature", () => {
  const parsed = parseMacOSReleaseFeed({
    version: "1.0.35",
    build: "135",
    downloadUrl: "https://downloads.burnbar.ai/OpenBurnBar-1.0.35-macOS.dmg",
    length: 4096,
    sha256: "ab".repeat(32),
    sparkleEdSignature: "c2lnbmF0dXJl",
    minimumSystemVersion: "14.0",
    critical: true
  });
  assert.equal(parsed.version, "1.0.35");
  assert.equal(parsed.build, "135");
  assert.equal(parsed.minimumSystemVersion, "14.0");
  assert.equal(parsed.critical, true);
  assert.throws(() => parseMacOSReleaseFeed({
    version: "1.0.35",
    build: "135",
    downloadUrl: "https://downloads.burnbar.ai/OpenBurnBar-1.0.35-macOS.dmg",
    length: 4096,
    sha256: "ab".repeat(32),
    minimumSystemVersion: "14.0"
  }), /sparkleEdSignature/);
  assert.throws(() => parseMacOSReleaseFeed({
    version: "0.0.1",
    build: "1",
    downloadUrl: "https://downloads.burnbar.ai/x.dmg",
    length: 0,
    sha256: "ab".repeat(32),
    sparkleEdSignature: "c2ln",
    minimumSystemVersion: "14.0"
  }), /positive integer/);
  assert.throws(() => parseMacOSReleaseFeed({
    version: "1.0.35",
    build: "135",
    downloadUrl: "https://downloads.burnbar.ai/OpenBurnBar-1.0.35-macOS.dmg",
    length: 4096,
    sha256: "ab".repeat(32),
    sparkleEdSignature: "c2ln",
    minimumSystemVersion: "Sonoma"
  }), /minimumSystemVersion/);
});

test("version comparison matches the desktop updater", () => {
  assert.equal(compareNumericVersion("1.10.0", "1.9.0"), 1);
  assert.equal(compareNumericVersion("1.0.35", "1.0.20"), 1);
  assert.equal(isNewerRelease({ version: "1.0.0", build: "201" }, { version: "1.0.0", build: "200" }), true);
  assert.equal(isNewerRelease({ version: "1.0.0", build: "200" }, { version: "1.0.0", build: "201" }), false);
  assert.equal(isNewerRelease({ version: "1.10.0", build: "200" }, { version: "1.9.0", build: "200" }), true);
});

test("mount-point and Info.plist parsers prefer the volume root", () => {
  const plist = mountPlist("/Volumes/OpenBurnBar");
  assert.equal(parseMountPoint(plist), "/Volumes/OpenBurnBar");
  assert.equal(plistString(infoPlist("1.0.35", "135"), "CFBundleShortVersionString"), "1.0.35");
  assert.equal(plistString(infoPlist("1.0.35", "135"), "CFBundleVersion"), "135");
});

test("verifyArtifactBytes checks length, sha256, and Ed25519", () => {
  const key = testKey();
  const bytes = Buffer.from("notarized-dmg-bytes");
  const release = makeRelease(bytes, key);
  verifyArtifactBytes(bytes, release, key.publicKeyBase64);
  assert.throws(() => verifyArtifactBytes(Buffer.from("tampered"), release, key.publicKeyBase64), /SHA-256|bytes/);
  assert.throws(
    () => verifyArtifactBytes(bytes, { ...release, sparkleEdSignature: key.sign(Buffer.from("other")) }, key.publicKeyBase64),
    /Ed25519/
  );
  assert.throws(
    () => verifyArtifactBytes(bytes, { ...release, length: bytes.length + 8 }, key.publicKeyBase64),
    /bytes/
  );
});

test("app install fetches the feed version and copies to Applications", async () => {
  const key = testKey();
  const bytes = Buffer.from("OpenBurnBar-1.0.35-dmg");
  const release = makeRelease(bytes, key);
  const env = harness(bytes, release, key);
  try {
    const code = await runAppCommand("install", { dryRun: false }, env.deps);
    assert.equal(code, 0);
    assert.equal(env.downloads(), 1);
    const installed = readInstalledBundle(env.applicationsDir, {
      exists: (path) => {
        try {
          readFileSync(path);
          return true;
        } catch {
          return false;
        }
      },
      readFile: (path) => readFileSync(path)
    });
    assert.deepEqual(installed, { version: "1.0.35", build: "135", bundleId: APP_BUNDLE_ID });
    assert.match(env.logs.join(""), /Installed OpenBurnBar 1\.0\.35/);
    assert.ok(env.commands.some((item) => item.command === "/usr/bin/hdiutil" && item.args[0] === "attach"));
    assert.ok(env.commands.some((item) => item.command === "/usr/bin/ditto"));
    assert.ok(env.commands.some((item) => item.command === "/usr/bin/xattr"));
    assert.equal(join(env.applicationsDir, APP_BUNDLE_NAME).startsWith(env.applicationsDir), true);
  } finally {
    env.cleanup();
  }
});

test("app install follows a newer public feed build such as 1.0.40", async () => {
  const key = testKey();
  const bytes = Buffer.from("OpenBurnBar-1.0.40-dmg");
  const release = makeRelease(bytes, key, {
    version: "1.0.40",
    build: "140",
    downloadUrl: "https://downloads.burnbar.ai/OpenBurnBar-1.0.40-macOS.dmg",
    dmg: "OpenBurnBar-1.0.40-macOS.dmg"
  });
  const env = harness(bytes, release, key);
  try {
    const code = await runAppCommand("install", { dryRun: false }, env.deps);
    assert.equal(code, 0);
    assert.match(env.logs.join(""), /1\.0\.40/);
    assert.doesNotMatch(env.logs.join(""), /1\.0\.20/);
  } finally {
    env.cleanup();
  }
});

test("app install accepts the live GitHub Releases download host used by today's feed", async () => {
  const key = testKey();
  const bytes = Buffer.from("github-release-dmg");
  const release = makeRelease(bytes, key, {
    downloadUrl: "https://github.com/Imagine-That-Ai/BurnBar/releases/latest/download/OpenBurnBar-1.0.35-macOS.dmg"
  });
  const env = harness(bytes, release, key);
  try {
    const code = await runAppCommand("install", { dryRun: false }, env.deps);
    assert.equal(code, 0);
  } finally {
    env.cleanup();
  }
});

test("app install accepts the official GitHub feed redirect to its release CDN", async () => {
  const key = testKey();
  const bytes = Buffer.from("github-release-feed-and-dmg");
  const release = makeRelease(bytes, key);
  const env = harness(bytes, release, key);
  const officialFeed = "https://github.com/Imagine-That-Ai/BurnBar/releases/latest/download/latest-macos.json";
  env.deps.fetch = async (input) => {
    const url = String(input);
    if (url === officialFeed) {
      const response = new Response(feedJson(release), {
        status: 200,
        headers: { "content-type": "application/json" }
      });
      Object.defineProperty(response, "url", {
        value: "https://release-assets.githubusercontent.com/github-production-release-asset/123/latest-macos.json?token=public"
      });
      return response;
    }
    if (url === release.downloadUrl) {
      return new Response(new Uint8Array(bytes), { status: 200 });
    }
    return new Response("not found", { status: 404 });
  };
  try {
    const code = await runAppCommand("install", { dryRun: false, feedUrl: officialFeed }, env.deps);
    assert.equal(code, 0);
  } finally {
    env.cleanup();
  }
});

test("app install refuses a feed that points at a foreign host before downloading", async () => {
  const key = testKey();
  const bytes = Buffer.from("evil");
  const release = makeRelease(bytes, key, {
    downloadUrl: "https://evil.example/OpenBurnBar.dmg"
  });
  const env = harness(bytes, release, key);
  try {
    const code = await runAppCommand("install", { dryRun: false }, env.deps);
    assert.equal(code, 1);
    assert.equal(env.downloads(), 0);
    assert.match(env.errors.join(""), /Refusing download URL/);
  } finally {
    env.cleanup();
  }
});

test("app install refuses a mounted app whose bundle identity does not match the feed", async () => {
  const key = testKey();
  const bytes = Buffer.from("signed-but-wrong-bundle");
  const release = makeRelease(bytes, key);
  const env = harness(bytes, release, key, undefined, {
    version: release.version,
    build: release.build,
    bundleId: "com.example.not-openburnbar"
  });
  try {
    const code = await runAppCommand("install", { dryRun: false }, env.deps);
    assert.equal(code, 1);
    assert.match(env.errors.join(""), /bundle identifier/);
    assert.equal(existsSync(join(env.applicationsDir, APP_BUNDLE_NAME)), false);
  } finally {
    env.cleanup();
  }
});

test("app install refuses a mounted app whose version or build differs from the feed", async () => {
  const key = testKey();
  const bytes = Buffer.from("signed-but-wrong-version");
  const release = makeRelease(bytes, key);
  const env = harness(bytes, release, key, undefined, {
    version: "1.0.99",
    build: "199",
    bundleId: APP_BUNDLE_ID
  });
  try {
    const code = await runAppCommand("install", { dryRun: false }, env.deps);
    assert.equal(code, 1);
    assert.match(env.errors.join(""), /feed advertised/);
    assert.equal(existsSync(join(env.applicationsDir, APP_BUNDLE_NAME)), false);
  } finally {
    env.cleanup();
  }
});

test("app install refuses to replace an existing bundle with the wrong identifier", async () => {
  const key = testKey();
  const bytes = Buffer.from("signed-openburnbar-dmg");
  const release = makeRelease(bytes, key);
  const env = harness(bytes, release, key, {
    version: "1.0.20",
    build: "20",
    bundleId: "com.example.not-openburnbar"
  });
  try {
    const code = await runAppCommand("install", { dryRun: false }, env.deps);
    assert.equal(code, 1);
    assert.equal(env.downloads(), 0);
    assert.match(env.errors.join(""), /Refusing to replace/);
  } finally {
    env.cleanup();
  }
});

test("app install fails closed when codesign rejects the mounted app", async () => {
  const key = testKey();
  const bytes = Buffer.from("bad-codesign-dmg");
  const release = makeRelease(bytes, key);
  const env = harness(bytes, release, key);
  const run = env.deps.run;
  assert.ok(run);
  env.deps.run = async (command, args) => {
    if (command === "/usr/bin/codesign") {
      return { status: 1, stdout: "", stderr: "code object is not signed at all" };
    }
    return run(command, args);
  };
  try {
    const code = await runAppCommand("install", { dryRun: false }, env.deps);
    assert.equal(code, 1);
    assert.match(env.errors.join(""), /code signature did not validate/);
    assert.equal(existsSync(join(env.applicationsDir, APP_BUNDLE_NAME)), false);
  } finally {
    env.cleanup();
  }
});

test("checksum failure never mounts or copies into Applications", async () => {
  const key = testKey();
  const bytes = Buffer.from("good-bytes");
  const release = makeRelease(bytes, key);
  const env = harness(Buffer.from("bad!-bytes"), release, key);
  try {
    const code = await runAppCommand("install", { dryRun: false }, env.deps);
    assert.equal(code, 1);
    assert.match(env.errors.join(""), /SHA-256/);
    assert.equal(env.commands.some((item) => item.command === "/usr/bin/hdiutil"), false);
    assert.equal(env.commands.some((item) => item.command === "/usr/bin/ditto"), false);
    assert.equal(readInstalledBundle(env.applicationsDir, {
      exists: () => false,
      readFile: () => Buffer.alloc(0)
    }), null);
  } finally {
    env.cleanup();
  }
});

test("app update refuses when the app is not installed", async () => {
  const key = testKey();
  const bytes = Buffer.from("dmg");
  const release = makeRelease(bytes, key);
  const env = harness(bytes, release, key);
  try {
    const code = await runAppCommand("update", { dryRun: false }, env.deps);
    assert.equal(code, 2);
    assert.equal(env.downloads(), 0);
    assert.match(env.errors.join(""), /app install/);
  } finally {
    env.cleanup();
  }
});

test("app update is a no-op when the installed build is current", async () => {
  const key = testKey();
  const bytes = Buffer.from("dmg");
  const release = makeRelease(bytes, key);
  const env = harness(bytes, release, key, { version: "1.0.35", build: "135" });
  try {
    const code = await runAppCommand("update", { dryRun: false }, env.deps);
    assert.equal(code, 0);
    assert.equal(env.downloads(), 0);
    assert.match(env.logs.join(""), /already installed/);
  } finally {
    env.cleanup();
  }
});

test("app update replaces an older /Applications copy", async () => {
  const key = testKey();
  const bytes = Buffer.from("newer-dmg");
  const release = makeRelease(bytes, key);
  const env = harness(bytes, release, key, { version: "1.0.20", build: "20" });
  try {
    const code = await runAppCommand("update", { dryRun: false }, env.deps);
    assert.equal(code, 0);
    assert.equal(env.downloads(), 1);
    const installed = readFileSync(join(env.applicationsDir, APP_BUNDLE_NAME, "Contents", "Info.plist"), "utf8");
    assert.match(installed, /1\.0\.35/);
  } finally {
    env.cleanup();
  }
});

test("app update refuses to replace a running app bundle", async () => {
  const key = testKey();
  const bytes = Buffer.from("newer-dmg-running-app");
  const release = makeRelease(bytes, key);
  const env = harness(bytes, release, key, { version: "1.0.20", build: "20" });
  const run = env.deps.run;
  assert.ok(run);
  env.deps.run = async (command, args) => {
    if (command === "/usr/bin/pgrep" && args[0] === "-x") {
      return { status: 0, stdout: "1234\n", stderr: "" };
    }
    return run(command, args);
  };
  try {
    const code = await runAppCommand("update", { dryRun: false }, env.deps);
    assert.equal(code, 2);
    assert.equal(env.downloads(), 0);
    assert.match(env.errors.join(""), /is running.*Quit OpenBurnBar/s);
  } finally {
    env.cleanup();
  }
});

test("app update refuses to replace a running bundled daemon", async () => {
  const key = testKey();
  const bytes = Buffer.from("newer-dmg-running-daemon");
  const release = makeRelease(bytes, key);
  const env = harness(bytes, release, key, { version: "1.0.20", build: "20" });
  const run = env.deps.run;
  assert.ok(run);
  env.deps.run = async (command, args) => {
    if (command === "/usr/bin/pgrep" && args[0] === "-f") {
      return { status: 0, stdout: "5678\n", stderr: "" };
    }
    return run(command, args);
  };
  try {
    const code = await runAppCommand("update", { dryRun: false }, env.deps);
    assert.equal(code, 2);
    assert.equal(env.downloads(), 0);
    assert.match(env.errors.join(""), /bundled OpenBurnBar daemon is running/);
  } finally {
    env.cleanup();
  }
});

test("app update refuses to replace a Mac App Store installation", async () => {
  const key = testKey();
  const bytes = Buffer.from("newer-dmg-mas");
  const release = makeRelease(bytes, key);
  const env = harness(bytes, release, key, { version: "1.0.20", build: "20" });
  mkdirSync(join(env.applicationsDir, APP_BUNDLE_NAME, "Contents", "_MASReceipt"), { recursive: true });
  writeFileSync(join(env.applicationsDir, APP_BUNDLE_NAME, "Contents", "_MASReceipt", "receipt"), "receipt");
  try {
    const code = await runAppCommand("update", { dryRun: false }, env.deps);
    assert.equal(code, 2);
    assert.equal(env.downloads(), 0);
    assert.match(env.errors.join(""), /Mac App Store installation/);
  } finally {
    env.cleanup();
  }
});

test("app update refuses to replace a Homebrew-managed installation", async () => {
  const key = testKey();
  const bytes = Buffer.from("newer-dmg-homebrew");
  const release = makeRelease(bytes, key);
  const env = harness(bytes, release, key, { version: "1.0.20", build: "20" });
  mkdirSync(env.homebrewReceiptDir, { recursive: true });
  try {
    const code = await runAppCommand("update", { dryRun: false }, env.deps);
    assert.equal(code, 2);
    assert.equal(env.downloads(), 0);
    assert.match(env.errors.join(""), /managed by Homebrew/);
  } finally {
    env.cleanup();
  }
});

test("app install refuses a release that requires a newer macOS version", async () => {
  const key = testKey();
  const bytes = Buffer.from("newer-macos-required");
  const release = makeRelease(bytes, key, { minimumSystemVersion: "15.0" });
  const env = harness(bytes, release, key);
  const run = env.deps.run;
  assert.ok(run);
  env.deps.run = async (command, args) => {
    if (command === "/usr/bin/sw_vers") {
      return { status: 0, stdout: "14.7.6\n", stderr: "" };
    }
    return run(command, args);
  };
  try {
    const code = await runAppCommand("install", { dryRun: false }, env.deps);
    assert.equal(code, 2);
    assert.equal(env.downloads(), 0);
    assert.match(env.errors.join(""), /requires macOS 15\.0 or newer/);
  } finally {
    env.cleanup();
  }
});

test("dry-run prints the live feed plan and does not download", async () => {
  const key = testKey();
  const bytes = Buffer.from("dmg");
  const release = makeRelease(bytes, key);
  const env = harness(bytes, release, key);
  try {
    const code = await runAppCommand("install", { dryRun: true }, { ...env.deps, platform: "linux" });
    assert.equal(code, 0);
    assert.equal(env.downloads(), 0);
    assert.match(env.logs.join(""), /version: 1\.0\.35/);
    assert.match(env.logs.join(""), /destination: /);
    assert.match(env.logs.join(""), /sha256: /);
  } finally {
    env.cleanup();
  }
});

test("non-macOS install fails closed before any download", async () => {
  const key = testKey();
  const bytes = Buffer.from("dmg");
  const release = makeRelease(bytes, key);
  const env = harness(bytes, release, key);
  try {
    const code = await runAppCommand("install", { dryRun: false }, { ...env.deps, platform: "linux" });
    assert.equal(code, 2);
    assert.equal(env.downloads(), 0);
    assert.match(env.errors.join(""), /only supports macOS/);
  } finally {
    env.cleanup();
  }
});

test("parseAppCliOptions accepts dry-run and feed override", () => {
  assert.deepEqual(parseAppCliOptions(["--dry-run"]), { dryRun: true });
  assert.deepEqual(
    parseAppCliOptions(["--feed-url", DEFAULT_MACOS_FEED_URL, "--applications-dir", "/tmp/Apps"]),
    { dryRun: false, feedUrl: DEFAULT_MACOS_FEED_URL, applicationsDir: "/tmp/Apps" }
  );
  assert.throws(() => parseAppCliOptions(["--feed-url"]), /requires a value/);
  assert.throws(() => parseAppCliOptions(["--nope"]), /unknown option/);
});

test("CLI help and app usage mention install and update", async () => {
  const help = await spawnCli(["--help"]);
  assert.equal(help.status, 0);
  assert.match(help.stdout, /app <install\|update>/);
  const usage = await spawnCli([]);
  assert.equal(usage.status, 0);
  assert.match(usage.stdout, /app <install\|update>/);
  const app = await spawnCli(["app"]);
  assert.equal(app.status, 2);
  assert.match(app.stderr, /openburnbar app <install\|update>/);
  assert.match(app.stderr, /--applications-dir <path>/);
});

test("live integration: CLI app install dry-run follows the public feed without downloading a DMG", {
  skip: !LIVE_FEED_TEST
}, async () => {
  const result = await spawnCli(["app", "install", "--dry-run"]);
  assert.equal(result.status, 0, result.stderr);
  assert.match(result.stdout, new RegExp(`feed: ${DEFAULT_MACOS_FEED_URL}`));
  assert.match(result.stdout, /version: \S+/);
  assert.match(result.stdout, /sha256: [a-f0-9]{64}/);
  assert.doesNotMatch(result.stderr, /Downloading OpenBurnBar/);
});

test("artifact verification uses the feed sha256, not a baked digest", () => {
  const key = testKey();
  const first = Buffer.from("payload-aaaaaaaa");
  const second = Buffer.from("payload-bbbbbbbb");
  const feedFirst = makeRelease(first, key);
  const feedSecond = makeRelease(second, key, {
    sha256: sha256(second),
    sparkleEdSignature: key.sign(second)
  });
  verifyArtifactBytes(first, feedFirst, key.publicKeyBase64);
  verifyArtifactBytes(second, feedSecond, key.publicKeyBase64);
  assert.throws(() => verifyArtifactBytes(first, feedSecond, key.publicKeyBase64), /SHA-256/);
  assert.notEqual(feedFirst.sha256, feedSecond.sha256);
  const source = readFileSync(join(PKG_ROOT, "src/appInstall.ts"), "utf8");
  assert.doesNotMatch(source, new RegExp(feedFirst.sha256, "i"));
  assert.doesNotMatch(source, new RegExp(feedSecond.sha256, "i"));
});

test("live integration: public latest-macos.json supplies the checksum used for verify", {
  skip: !LIVE_FEED_TEST
}, async () => {
  const response = await fetch(DEFAULT_MACOS_FEED_URL, {
    headers: { Accept: "application/json", "User-Agent": "OpenBurnBar-CLI-test" }
  });
  assert.equal(response.ok, true, `public feed HTTP ${response.status}`);
  const release = parseMacOSReleaseFeed(await response.json());
  assert.match(release.sha256, /^[a-f0-9]{64}$/u);
  assert.ok(release.length > 0);
  assert.ok(isAllowedDownloadUrl(release.downloadUrl));
  assert.ok(release.version.length > 0);
  const source = readFileSync(join(PKG_ROOT, "src/appInstall.ts"), "utf8");
  const readme = readFileSync(join(PKG_ROOT, "README.md"), "utf8");
  const pkg = readFileSync(join(PKG_ROOT, "package.json"), "utf8");
  for (const text of [source, readme, pkg]) {
    assert.doesNotMatch(text, new RegExp(release.sha256, "i"));
    assert.doesNotMatch(text, /1\.0\.29/);
  }
});

test("npm pack stays small and never includes a Mac DMG", async () => {
  const result = await new Promise<{ status: number; stdout: string; stderr: string }>((resolve) => {
    const child = spawn("npm", ["pack", "--dry-run", "--ignore-scripts", "--json"], {
      cwd: PKG_ROOT,
      stdio: ["ignore", "pipe", "pipe"]
    });
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
    child.on("close", (code) => {
      resolve({ status: code ?? -1, stdout, stderr });
    });
  });
  assert.equal(result.status, 0, result.stderr);
  const parsed = JSON.parse(result.stdout) as Array<{
    unpackedSize?: number;
    size?: number;
    filename?: string;
    files?: Array<{ path: string; size: number }>;
  }> | {
    unpackedSize?: number;
    size?: number;
    filename?: string;
    files?: Array<{ path: string; size: number }>;
  };
  const entry = Array.isArray(parsed) ? parsed[0] : parsed;
  assert.ok(entry, "npm pack --json returned no entry");
  const unpacked = entry.unpackedSize ?? 0;
  const packed = entry.size ?? 0;
  assert.ok(unpacked > 0 && unpacked < 2_000_000, `unpackedSize ${unpacked} must stay well under a 386MB DMG`);
  assert.ok(packed < 1_000_000, `packed size ${packed} must stay small`);
  const files = entry.files ?? [];
  assert.ok(files.length > 0);
  const packedPaths = new Set(files.map((file) => file.path));
  assert.ok(packedPaths.has("macos-tray/Info.plist"), "pack must include macos-tray/Info.plist");
  assert.ok(packedPaths.has("macos-tray/Package.swift"), "pack must include macos-tray/Package.swift");
  assert.ok(
    packedPaths.has("macos-tray/Sources/OpenBurnBarGatewayTray/main.swift"),
    "pack must include macos-tray Swift sources"
  );
  for (const file of files) {
    assert.doesNotMatch(file.path, /\.dmg$/i);
    assert.doesNotMatch(file.path, /\.app(\/|$)/i);
    assert.doesNotMatch(file.path, /(^|\/)\.build(\/|$)/u);
    assert.doesNotMatch(file.path, /\.test\.(js|d\.ts)$/u);
    assert.ok(file.size < 2_000_000, `${file.path} is ${file.size} bytes`);
  }
});
