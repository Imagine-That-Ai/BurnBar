#!/usr/bin/env node
import { createHash } from "node:crypto";
import { existsSync, lstatSync, readFileSync, realpathSync, statSync, writeFileSync } from "node:fs";
import path from "node:path";

function readArgs(argv) {
  const args = new Map();
  for (let index = 2; index < argv.length; index += 1) {
    const name = argv[index];
    if (!name.startsWith("--")) {
      throw new Error(`Unexpected argument: ${name}`);
    }
    const value = argv[index + 1];
    if (!value || value.startsWith("--")) {
      throw new Error(`Missing value for ${name}`);
    }
    args.set(name.slice(2), value);
    index += 1;
  }
  return args;
}

function required(args, name) {
  const value = args.get(name);
  if (!value) {
    throw new Error(`Missing required argument --${name}`);
  }
  return value;
}

function xmlEscape(value) {
  return String(value)
    .replaceAll("&", "&amp;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;")
    .replaceAll("\"", "&quot;")
    .replaceAll("'", "&apos;");
}

function sha256(filePath) {
  return createHash("sha256").update(readFileSync(filePath)).digest("hex");
}

function joinUrl(baseUrl, name) {
  return `${baseUrl.replace(/\/+$/, "")}/${encodeURIComponent(name)}`;
}

function safeReleaseFileName(value, optionName) {
  if (!/^[A-Za-z0-9][A-Za-z0-9._+-]*$/u.test(value)) {
    throw new Error(`${optionName} must be a plain artifact file name`);
  }
  if (
    value.includes("/") ||
    value.includes("\\") ||
    value.includes("\0") ||
    value === "." ||
    value === ".." ||
    path.basename(value) !== value
  ) {
    throw new Error(`${optionName} must not contain path separators or traversal`);
  }
  return value;
}

function resolveReleaseFile(releaseRoot, fileName, optionName) {
  const safeName = safeReleaseFileName(fileName, optionName);
  const candidate = path.resolve(releaseRoot, safeName);
  if (path.dirname(candidate) !== releaseRoot) {
    throw new Error(`${optionName} resolved outside --release-dir`);
  }
  const fileStat = lstatSync(candidate);
  if (fileStat.isSymbolicLink() || !fileStat.isFile()) {
    throw new Error(`${optionName} must reference a regular file inside --release-dir`);
  }
  return candidate;
}

function resolveOutputFile(releaseRoot, fileName, optionName) {
  const safeName = safeReleaseFileName(fileName, optionName);
  const candidate = path.resolve(releaseRoot, safeName);
  if (path.dirname(candidate) !== releaseRoot) {
    throw new Error(`${optionName} resolved outside --release-dir`);
  }
  if (existsSync(candidate)) {
    const fileStat = lstatSync(candidate);
    if (fileStat.isSymbolicLink() || !fileStat.isFile()) {
      throw new Error(`${optionName} output path must be a regular file inside --release-dir`);
    }
  }
  return candidate;
}

try {
  const args = readArgs(process.argv);
  const version = required(args, "version");
  const build = required(args, "build");
  const bundleId = required(args, "bundle-id");
  const releaseDir = realpathSync(required(args, "release-dir"));
  const dmgName = safeReleaseFileName(required(args, "dmg-name"), "--dmg-name");
  const zipName = safeReleaseFileName(required(args, "zip-name"), "--zip-name");
  const sourceArchiveName = safeReleaseFileName(
    required(args, "source-archive-name"),
    "--source-archive-name",
  );
  const baseUrl = required(args, "base-url").replace(/\/+$/, "");
  const commit = required(args, "commit");
  const minimumSystemVersion = args.get("minimum-system-version") ?? "14.0";
  const edSignature = args.get("ed-signature") ?? "";
  // Security-critical release flag: the in-app updater re-prompts for critical
  // releases even after the user picked "Later".
  const criticalRaw = (args.get("critical") ?? "false").toLowerCase();
  const critical = criticalRaw === "1" || criticalRaw === "true" || criticalRaw === "yes";
  const createdAt = new Date().toISOString().replace(/\.\d{3}Z$/, "Z");
  const pubDate = new Date().toUTCString();
  const dmgPath = resolveReleaseFile(releaseDir, dmgName, "--dmg-name");
  resolveReleaseFile(releaseDir, zipName, "--zip-name");
  resolveReleaseFile(releaseDir, sourceArchiveName, "--source-archive-name");
  const dmgSize = statSync(dmgPath).size;
  const dmgSha256 = sha256(dmgPath);
  const appcastName = safeReleaseFileName(args.get("appcast-name") ?? "appcast.xml", "--appcast-name");
  const latestName = safeReleaseFileName(args.get("latest-name") ?? "latest-macos.json", "--latest-name");
  const appcastPath = resolveOutputFile(releaseDir, appcastName, "--appcast-name");
  const latestPath = resolveOutputFile(releaseDir, latestName, "--latest-name");
  const releaseNotesUrl = joinUrl(baseUrl, "release-metadata.json");
  const downloadUrl = joinUrl(baseUrl, dmgName);
  const appcastUrl = joinUrl(baseUrl, appcastName);

  const enclosureAttrs = [
    `url="${xmlEscape(downloadUrl)}"`,
    `length="${dmgSize}"`,
    `type="application/x-apple-diskimage"`,
  ];
  if (edSignature) {
    enclosureAttrs.push(`sparkle:edSignature="${xmlEscape(edSignature)}"`);
  }

  const appcast = `<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>OpenBurnBar macOS Updates</title>
    <link>${xmlEscape(appcastUrl)}</link>
    <description>OpenBurnBar direct-download macOS releases.</description>
    <language>en</language>
    <item>
      <title>OpenBurnBar ${xmlEscape(version)}</title>
      <pubDate>${xmlEscape(pubDate)}</pubDate>
      <sparkle:version>${xmlEscape(build)}</sparkle:version>
      <sparkle:shortVersionString>${xmlEscape(version)}</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>${xmlEscape(minimumSystemVersion)}</sparkle:minimumSystemVersion>
      <sparkle:releaseNotesLink>${xmlEscape(releaseNotesUrl)}</sparkle:releaseNotesLink>${
        critical
          ? `
      <sparkle:tags>
        <sparkle:criticalUpdate></sparkle:criticalUpdate>
      </sparkle:tags>`
          : ""
      }
      <enclosure ${enclosureAttrs.join(" ")} />
    </item>
  </channel>
</rss>
`;

  const latest = {
    appcastUrl,
    build,
    bundleId,
    channel: "direct-download",
    commit,
    correspondingSource: sourceArchiveName,
    createdAt,
    critical,
    dmg: dmgName,
    downloadUrl,
    length: dmgSize,
    minimumSystemVersion,
    releaseNotesUrl,
    sha256: dmgSha256,
    sparkleEdSignature: edSignature || null,
    version,
    zip: zipName,
  };

  writeFileSync(appcastPath, appcast);
  writeFileSync(latestPath, `${JSON.stringify(latest, null, 2)}\n`);
} catch (error) {
  console.error(`generate-macos-appcast: ${error.message}`);
  process.exit(1);
}
