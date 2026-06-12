#!/usr/bin/env node
import { createHash } from "node:crypto";
import { readFileSync, statSync, writeFileSync } from "node:fs";
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

try {
  const args = readArgs(process.argv);
  const version = required(args, "version");
  const build = required(args, "build");
  const bundleId = required(args, "bundle-id");
  const releaseDir = required(args, "release-dir");
  const dmgName = required(args, "dmg-name");
  const zipName = required(args, "zip-name");
  const sourceArchiveName = required(args, "source-archive-name");
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
  const dmgPath = path.join(releaseDir, dmgName);
  const dmgSize = statSync(dmgPath).size;
  const dmgSha256 = sha256(dmgPath);
  const appcastName = args.get("appcast-name") ?? "appcast.xml";
  const latestName = args.get("latest-name") ?? "latest-macos.json";
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

  writeFileSync(path.join(releaseDir, appcastName), appcast);
  writeFileSync(path.join(releaseDir, latestName), `${JSON.stringify(latest, null, 2)}\n`);
} catch (error) {
  console.error(`generate-macos-appcast: ${error.message}`);
  process.exit(1);
}
