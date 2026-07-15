#!/usr/bin/env node
import { createHash } from "node:crypto";
import { lstatSync, readdirSync, writeFileSync } from "node:fs";
import { dirname, join, relative, resolve, sep } from "node:path";
import { gzipSync } from "node:zlib";

import { readRegularFileSync } from "../lib/atomic-regular-file.mjs";
import {
  firebaseHostingApiUrl,
  firebaseHostingReleaseName,
  firebaseHostingUploadUrl,
  firebaseHostingVersionName,
} from "../lib/firebase-hosting-rest-url.mjs";

const args = process.argv.slice(2);

let project = "burnbar";
let configPath = "";
let firebasercPath = "";
let message = "";
let dryRun = false;
let resultPath = "";

function usage() {
  console.error(
    [
      "Usage: node scripts/ci/deploy-firebase-hosting-rest.mjs --config <path> --firebaserc <path> [options]",
      "",
      "Options:",
      "  --project <id>      Firebase project id (default: burnbar)",
      "  --message <text>    Release message",
      "  --dry-run           Parse, convert, and hash without network calls",
    ].join("\n"),
  );
}

for (let index = 0; index < args.length; index += 1) {
  const arg = args[index];
  if (arg === "--project") {
    project = args[++index] ?? "";
  } else if (arg === "--config") {
    configPath = resolve(args[++index] ?? "");
  } else if (arg === "--firebaserc") {
    firebasercPath = resolve(args[++index] ?? "");
  } else if (arg === "--message") {
    message = args[++index] ?? "";
  } else if (arg === "--dry-run") {
    dryRun = true;
  } else if (arg === "--result") {
    resultPath = resolve(args[++index] ?? "");
  } else if (arg === "--help" || arg === "-h") {
    usage();
    process.exit(0);
  } else {
    throw new Error(`Unknown argument: ${arg}`);
  }
}

if (!project) throw new Error("--project must not be empty");
if (!configPath) throw new Error("--config is required");
if (!firebasercPath) throw new Error("--firebaserc is required");
assertFirebaseIdentifier(project, "--project");

const artifactRoot = dirname(configPath);
const accessToken = process.env.FIREBASE_HOSTING_REST_ACCESS_TOKEN ?? "";
if (!dryRun && !accessToken) {
  throw new Error(
    "FIREBASE_HOSTING_REST_ACCESS_TOKEN is required for non-dry-run Hosting REST deploys",
  );
}

function readJson(path) {
  try {
    return JSON.parse(
      readRegularFileSync(path, {
        encoding: "utf8",
        label: "Hosting configuration",
      }),
    );
  } catch (error) {
    throw new Error(`Failed to parse ${path}: ${error.message}`);
  }
}

function requirePlainObject(value, label) {
  if (!value || typeof value !== "object" || Array.isArray(value)) {
    throw new Error(`${label} must be an object`);
  }
  return value;
}

function assertFirebaseIdentifier(value, label) {
  if (!/^[a-z0-9][a-z0-9-]{0,62}$/u.test(value)) {
    throw new Error(`${label} must be a Firebase identifier`);
  }
}

function resolveSiteForTarget(firebaserc, target) {
  assertFirebaseIdentifier(target, "hosting target");
  const sites = firebaserc.targets?.[project]?.hosting?.[target];
  if (
    !Array.isArray(sites) ||
    sites.length !== 1 ||
    typeof sites[0] !== "string"
  ) {
    throw new Error(
      `Firebase hosting target ${target} must map to exactly one site in .firebaserc`,
    );
  }
  assertFirebaseIdentifier(
    sites[0],
    `Firebase hosting site for target ${target}`,
  );
  const expected = { marketing: "burnbar", console: "burnbar-console" }[target];
  if (expected === undefined || sites[0] !== expected) {
    throw new Error(
      `Firebase hosting target ${target} must map exactly to production site ${expected ?? "<unsupported>"}`,
    );
  }
  return sites[0];
}

function extractPattern(type, source) {
  const hasGlob =
    Object.hasOwn(source, "glob") || Object.hasOwn(source, "source");
  const glob = source.glob ?? source.source;
  const regex = source.regex;
  if (hasGlob && regex) {
    throw new Error(
      `Cannot specify a ${type} pattern with both a glob/source and regex`,
    );
  }
  if (hasGlob && typeof glob === "string") return { glob };
  if (typeof regex === "string") return { regex };
  throw new Error(`Cannot specify a ${type} with no source/glob/regex pattern`);
}

function convertHeaders(headers = []) {
  return headers.map((entry) => {
    const headerMap = {};
    for (const header of entry.headers ?? []) {
      if (typeof header.key !== "string" || typeof header.value !== "string") {
        throw new Error(
          "Hosting header entries must contain string key/value pairs",
        );
      }
      headerMap[header.key] = header.value;
    }
    return {
      ...extractPattern("header", entry),
      headers: headerMap,
    };
  });
}

function convertRedirects(redirects = []) {
  return redirects.map((entry) => {
    if (typeof entry.destination !== "string") {
      throw new Error("Hosting redirects must contain a string destination");
    }
    const redirect = {
      ...extractPattern("redirect", entry),
      location: entry.destination,
    };
    if (entry.type !== undefined) redirect.statusCode = entry.type;
    return redirect;
  });
}

function convertRewrites(rewrites = []) {
  return rewrites.map((entry) => {
    const target = extractPattern("rewrite", entry);
    if (typeof entry.destination === "string") {
      return { ...target, path: entry.destination };
    }
    if (typeof entry.function === "string") {
      return { ...target, function: entry.function };
    }
    if (entry.function && typeof entry.function === "object") {
      if (entry.function.pinTag) {
        throw new Error(
          "Hosting REST deploy does not support function pinTag rewrites",
        );
      }
      const functionId = entry.function.functionId;
      if (typeof functionId !== "string") {
        throw new Error(
          "Hosting function rewrites must contain function.functionId",
        );
      }
      const rewrite = { ...target, function: functionId };
      if (typeof entry.function.region === "string") {
        rewrite.functionRegion = entry.function.region;
      }
      return rewrite;
    }
    if (entry.run && typeof entry.run === "object") {
      if (entry.run.pinTag) {
        throw new Error(
          "Hosting REST deploy does not support Cloud Run pinTag rewrites",
        );
      }
      if (typeof entry.run.serviceId !== "string") {
        throw new Error("Hosting run rewrites must contain run.serviceId");
      }
      return {
        ...target,
        run: {
          serviceId: entry.run.serviceId,
          region: entry.run.region || "us-central1",
        },
      };
    }
    if (entry.dynamicLinks === true) {
      return { ...target, dynamicLinks: true };
    }
    throw new Error(
      "Hosting rewrite must specify destination, function, run, or dynamicLinks",
    );
  });
}

function convertHostingConfig(entry) {
  const config = {};
  if (entry.headers) config.headers = convertHeaders(entry.headers);
  if (entry.redirects) config.redirects = convertRedirects(entry.redirects);
  if (entry.rewrites) config.rewrites = convertRewrites(entry.rewrites);
  if (entry.cleanUrls !== undefined) config.cleanUrls = entry.cleanUrls;
  if (entry.i18n !== undefined) config.i18n = entry.i18n;
  if (entry.trailingSlash !== undefined) {
    config.trailingSlashBehavior = entry.trailingSlash ? "ADD" : "REMOVE";
  }
  return config;
}

function listFiles(root) {
  const out = [];
  const visit = (dir) => {
    for (const name of readdirSync(dir)) {
      const path = join(dir, name);
      const stat = lstatSync(path);
      if (stat.isSymbolicLink())
        throw new Error(`Refusing to deploy symlink: ${path}`);
      if (stat.isDirectory()) {
        visit(path);
      } else if (stat.isFile()) {
        out.push(path);
      } else {
        throw new Error(`Refusing to deploy special file: ${path}`);
      }
    }
  };
  visit(root);
  out.sort();
  return out;
}

function fileRecord(publicDir, path) {
  const relativePath = relative(publicDir, path).split(sep).join("/");
  if (!relativePath || relativePath.startsWith("../")) {
    throw new Error(`Invalid file path outside public dir: ${path}`);
  }
  const gzipped = gzipSync(
    readRegularFileSync(path, { label: "Hosting artifact" }),
    { level: 9 },
  );
  const hash = createHash("sha256").update(gzipped).digest("hex");
  return {
    hash,
    path: `/${relativePath}`,
    gzipped,
  };
}

async function request(method, path, body) {
  const headers = {
    Authorization: `Bearer ${accessToken}`,
  };
  let requestBody;
  if (body !== undefined) {
    headers["Content-Type"] = "application/json";
    requestBody = JSON.stringify(body);
  }
  const url = firebaseHostingApiUrl(method, path);
  const response = await fetch(url, {
    method,
    headers,
    body: requestBody,
  });
  if (!response.ok) {
    const text = await response.text();
    throw new Error(
      `${method} ${url.pathname} failed (${response.status}): ${text}`,
    );
  }
  if (response.status === 204) return {};
  return response.json();
}

async function uploadHash(uploadUrl, site, hash, gzipped) {
  const url = firebaseHostingUploadUrl(uploadUrl, site, hash);
  const response = await fetch(url, {
    method: "POST",
    headers: {
      Authorization: `Bearer ${accessToken}`,
      "Content-Type": "application/octet-stream",
    },
    body: gzipped,
  });
  if (!response.ok) {
    const text = await response.text();
    throw new Error(`upload ${hash} failed (${response.status}): ${text}`);
  }
}

async function runConcurrent(items, concurrency, fn) {
  const failures = [];
  let next = 0;
  await Promise.all(
    Array.from({ length: Math.min(concurrency, items.length) }, async () => {
      for (;;) {
        const index = next;
        next += 1;
        if (index >= items.length) return;
        try {
          await fn(items[index], index);
        } catch (error) {
          failures.push(error);
        }
      }
    }),
  );
  if (failures.length > 0) {
    throw new Error(failures.map((error) => error.message).join("\n"));
  }
}

function batch(entries, size) {
  const batches = [];
  for (let index = 0; index < entries.length; index += size) {
    batches.push(entries.slice(index, index + size));
  }
  return batches;
}

async function deployOne(entry, firebaserc) {
  const target = entry.target;
  if (typeof target !== "string")
    throw new Error("Hosting entry is missing target");
  if (typeof entry.public !== "string")
    throw new Error(`Hosting target ${target} is missing public`);

  const site = resolveSiteForTarget(firebaserc, target);
  const publicDir = resolve(artifactRoot, entry.public);
  const records = listFiles(publicDir).map((path) =>
    fileRecord(publicDir, path),
  );
  const files = Object.fromEntries(
    records.map((record) => [record.path, record.hash]),
  );
  const hashToRecord = new Map(records.map((record) => [record.hash, record]));
  const convertedConfig = convertHostingConfig(entry);

  console.log(`hosting[${site}] target=${target} files=${records.length}`);

  if (dryRun) {
    return {
      site,
      target,
      fileCount: records.length,
      uploadCount: 0,
      dryRun: true,
    };
  }

  const created = await request("POST", `/projects/-/sites/${site}/versions`, {
    status: "CREATED",
  });
  const versionName = firebaseHostingVersionName(created.name, site);

  let uploadUrl = "";
  const uploadHashes = new Set();
  for (const fileBatch of batch(Object.entries(files), 1000)) {
    const populated = await request("POST", `/${versionName}:populateFiles`, {
      files: Object.fromEntries(fileBatch),
    });
    if (typeof populated.uploadUrl === "string")
      uploadUrl = populated.uploadUrl;
    for (const hash of populated.uploadRequiredHashes ?? [])
      uploadHashes.add(hash);
  }

  if (uploadHashes.size > 0 && !uploadUrl) {
    throw new Error(
      `Hosting API requested uploads for ${site} but did not return uploadUrl`,
    );
  }

  const uploads = [...uploadHashes].map((hash) => {
    const record = hashToRecord.get(hash);
    if (!record) throw new Error(`Hosting API requested unknown hash ${hash}`);
    return record;
  });
  await runConcurrent(
    uploads,
    Number(process.env.FIREBASE_HOSTING_UPLOAD_CONCURRENCY ?? 20),
    (record) => uploadHash(uploadUrl, site, record.hash, record.gzipped),
  );

  const versionId = versionName.split("/").at(-1);
  await request(
    "PATCH",
    `/projects/-/sites/${site}/versions/${versionId}?updateMask=status,config`,
    {
      status: "FINALIZED",
      config: convertedConfig,
    },
  );

  const release = await request(
    "POST",
    `/projects/-/sites/${site}/channels/live/releases?versionName=${encodeURIComponent(versionName)}`,
    message ? { message } : {},
  );
  const releaseName = firebaseHostingReleaseName(release.name, site);

  console.log(
    `hosting[${site}] released ${versionName} uploads=${uploads.length}`,
  );
  return {
    site,
    target,
    fileCount: records.length,
    uploadCount: uploads.length,
    versionName,
    releaseName,
  };
}

const config = readJson(configPath);
const firebaserc = readJson(firebasercPath);
if (
  firebaserc.projects?.default !== project ||
  Object.keys(firebaserc.targets ?? {}).length !== 1 ||
  Object.keys(firebaserc.targets?.[project] ?? {}).join(",") !== "hosting" ||
  JSON.stringify(firebaserc.targets?.[project]?.hosting) !==
    JSON.stringify({ marketing: ["burnbar"], console: ["burnbar-console"] })
) {
  throw new Error(
    ".firebaserc must contain only the exact reviewed production Hosting target map",
  );
}
if (!Array.isArray(config.hosting)) {
  throw new Error("firebase-hosting.ci.json must contain a hosting array");
}

const results = [];
for (const entry of config.hosting.map((value, index) =>
  requirePlainObject(value, `hosting[${index}]`),
)) {
  results.push(await deployOne(entry, firebaserc));
}

if (dryRun) {
  console.log(`DRY_RUN: ${JSON.stringify({ project, results })}`);
} else {
  if (!resultPath)
    throw new Error("--result is required for non-dry-run Hosting deploys");
  writeFileSync(
    resultPath,
    `${JSON.stringify({ schemaVersion: 1, project, sites: results }, null, 2)}\n`,
    {
      encoding: "utf8",
      flag: "wx",
      mode: 0o600,
    },
  );
  console.log(`Released ${results.length} Firebase Hosting site(s).`);
}
