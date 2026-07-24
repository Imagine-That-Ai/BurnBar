#!/usr/bin/env bash

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
site_config="${1:-$repo_root/website/src/data/site.ts}"

if [[ ! -f "$site_config" ]]; then
  echo "::error::SITE config not found at $site_config" >&2
  exit 66
fi

read_site_metadata() {
  OPENBURNBAR_REPO_ROOT="$repo_root" node --input-type=module - "$site_config" <<'NODE'
import { createRequire } from "node:module";
import { readFileSync } from "node:fs";
import { resolve } from "node:path";

const siteConfig = process.argv[2];
const source = readFileSync(siteConfig, "utf8");
const require = createRequire(import.meta.url);
const repoRoot = process.env.OPENBURNBAR_REPO_ROOT;
if (!repoRoot) throw new Error("OPENBURNBAR_REPO_ROOT must be set by the verifier wrapper");
const ts = require(resolve(repoRoot, "website/node_modules/typescript"));
const sourceFile = ts.createSourceFile(siteConfig, source, ts.ScriptTarget.Latest, true, ts.ScriptKind.TS);

function unwrap(expression) {
  let current = expression;
  while (
    ts.isAsExpression(current) ||
    ts.isTypeAssertionExpression(current) ||
    ts.isSatisfiesExpression(current) ||
    ts.isParenthesizedExpression(current)
  ) current = current.expression;
  return current;
}

function propertyNameText(name) {
  return ts.isIdentifier(name) || ts.isStringLiteral(name) || ts.isNumericLiteral(name)
    ? name.text
    : undefined;
}

let siteObject;
for (const statement of sourceFile.statements) {
  if (!ts.isVariableStatement(statement)) continue;
  if (!statement.modifiers?.some((modifier) => modifier.kind === ts.SyntaxKind.ExportKeyword)) continue;
  for (const declaration of statement.declarationList.declarations) {
    if (declaration.name.getText(sourceFile) !== "SITE" || !declaration.initializer) continue;
    const initializer = unwrap(declaration.initializer);
    if (!ts.isObjectLiteralExpression(initializer)) {
      throw new Error("website/src/data/site.ts must export SITE as a declarative object literal");
    }
    siteObject = initializer;
  }
}
if (!siteObject) throw new Error("website/src/data/site.ts must export a declarative SITE object");

function stringField(name) {
  const property = siteObject.properties.find(
    (entry) => ts.isPropertyAssignment(entry) && propertyNameText(entry.name) === name,
  );
  if (!property) throw new Error(`SITE.${name} must be a literal string`);
  const value = unwrap(property.initializer);
  if (!ts.isStringLiteral(value) && !ts.isNoSubstitutionTemplateLiteral(value)) {
    throw new Error(`SITE.${name} must be a literal string`);
  }
  return value.text;
}

const version = stringField("linuxReleaseLatest");
const base = stringField("linuxDownloadBaseUrl").replace(/\/+$/, "");
const files = [
  stringField("linuxReleaseFile"),
  stringField("linuxDebFile"),
  stringField("linuxRpmFile"),
  stringField("linuxPubKeyFile"),
];
if (!base) throw new Error("SITE.linuxDownloadBaseUrl must be non-empty");
const baseURL = new URL(base);
if (baseURL.protocol !== "https:") throw new Error(`Public Linux downloads must use https, got ${baseURL.protocol}`);
if (baseURL.username || baseURL.password) throw new Error("Public Linux download URL must not contain credentials");
if (!/^\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?(?:\+[0-9A-Za-z.-]+)?$/.test(version)) {
  throw new Error(`SITE.linuxReleaseLatest is not a valid release version: ${version}`);
}
for (const [index, file] of files.entries()) {
  if (!/^[A-Za-z0-9][A-Za-z0-9._-]*$/.test(file)
      || file !== file.split("/").pop()
      || file.includes("\\")
      || file.includes("..")) {
    throw new Error(`Linux public asset name must be a safe basename: ${file}`);
  }
  if (index < 3 && !file.includes(version)) {
    throw new Error(`Linux public asset ${file} does not include ${version}`);
  }
}
if (!files[0].endsWith(".AppImage") || !files[1].endsWith(".deb") || !files[2].endsWith(".rpm")) {
  throw new Error("Linux public assets must include an AppImage, deb, and rpm");
}
if (!files[3].endsWith(".pem")) throw new Error("SITE.linuxPubKeyFile must be a PEM public key");

const feedURL = process.env.OPENBURNBAR_LINUX_UPDATE_FEED_URL || "https://downloads.burnbar.ai/latest-linux.json";
const parsedFeed = new URL(feedURL);
if (parsedFeed.protocol !== "https:" || parsedFeed.username || parsedFeed.password) {
  throw new Error("Linux update feed URL must be an https URL without credentials");
}

console.log(base);
console.log(version);
for (const file of files) console.log(file);
console.log(feedURL);
NODE
}

if [[ "${OPENBURNBAR_PRINT_PUBLIC_LINUX_DOWNLOAD_METADATA:-}" == "1" ]]; then
  read_site_metadata
  exit 0
fi

site_metadata="$(read_site_metadata)"
download_base="$(printf '%s\n' "$site_metadata" | sed -n '1p')"
expected_version="$(printf '%s\n' "$site_metadata" | sed -n '2p')"
appimage_file="$(printf '%s\n' "$site_metadata" | sed -n '3p')"
deb_file="$(printf '%s\n' "$site_metadata" | sed -n '4p')"
rpm_file="$(printf '%s\n' "$site_metadata" | sed -n '5p')"
public_key_file="$(printf '%s\n' "$site_metadata" | sed -n '6p')"
feed_url="$(printf '%s\n' "$site_metadata" | sed -n '7p')"

tmpdir="$(mktemp -d "${TMPDIR:-/tmp}/openburnbar-public-linux-trust.XXXXXX")"
trap 'rm -rf "$tmpdir"' EXIT

fetch_asset() {
  local name="$1"
  local destination="$2"
  local url="${download_base}/${name}"
  echo "Downloading public Linux asset: $url"
  curl --fail --location --show-error --silent \
    --retry 3 --connect-timeout 15 --max-time 600 \
    --proto '=https' --tlsv1.2 --output "$destination" "$url"
  [[ -s "$destination" ]] || { echo "::error::Public Linux asset is empty: $url" >&2; return 1; }
}

fetch_asset "$public_key_file" "$tmpdir/public-key.pem"
openssl pkey -pubin -in "$tmpdir/public-key.pem" -noout >/dev/null

for artifact in "$appimage_file" "$deb_file" "$rpm_file"; do
  fetch_asset "$artifact" "$tmpdir/$artifact"
  fetch_asset "${artifact}.ed25519.sig" "$tmpdir/$artifact.ed25519.sig"
  openssl pkeyutl -verify \
    -pubin -inkey "$tmpdir/public-key.pem" -rawin \
    -in "$tmpdir/$artifact" -sigfile "$tmpdir/$artifact.ed25519.sig" >/dev/null
done

echo "Verifying signed Linux update feed: $feed_url"
node "$repo_root/scripts/linux-port/check-linux-update-feed.mjs" --url "$feed_url"
node --input-type=module - "$feed_url" "$expected_version" <<'NODE'
const [url, expectedVersion] = process.argv.slice(2);
const response = await fetch(url, { redirect: "follow", headers: { Accept: "application/json" } });
if (!response.ok) throw new Error(`Linux update feed returned HTTP ${response.status}`);
const document = await response.json();
if (document.version !== expectedVersion) {
  throw new Error(`SITE.linuxReleaseLatest (${expectedVersion}) does not match the public feed version (${document.version})`);
}
NODE

echo "Public Linux download trust verification passed for ${expected_version}."
