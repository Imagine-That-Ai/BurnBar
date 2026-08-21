#!/usr/bin/env node
import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { readdirSync, readFileSync, statSync, writeFileSync } from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const DOC_START = "<!-- BEGIN GENERATED MIGRATION CATALOG -->";
const DOC_END = "<!-- END GENERATED MIGRATION CATALOG -->";

// These are reviewed, semantic platform adaptations, not blanket exclusions.
// Both fingerprints are pinned so any edit on either side requires review.
export const INTENTIONAL_DIVERGENCES = {
  v21_multifield_fts: {
    app: "da820ee7efc0ae17440cc7032743f27c7d525d3a92f44e0aec0649941e907531",
    shared: "393f4396428b91eb0a5dd3d2d02c7d06b2f0e7ce939ca45e37a99ce8931711e0",
    reason: "Shared SQLCipher/Linux builds must create both FTS virtual tables before swapping the chunk table.",
  },
  v22_cross_device_sync: {
    app: "b6b325be8fb9a5799704e4d54252e1c148ccdb1928e9cf59c109ad4827eebcd9",
    shared: "afb2d0143986985a87a4d205ecf6d089e7c278a967004389eb6fedba4ea4138a",
    reason: "The app copy qualifies OpenBurnBarIdentity through the imported OpenBurnBarCore module.",
  },
  v46_drain_target_per_provider: {
    app: "b71f29aa36fb42d5ae4d589e7c01a766b27f99cc149cbfd7f3dc1b714b02ddb6",
    shared: "92860497ca3f6cc3c173e9b65ca792e97ccdec23c9f1e3fd05308bd837f80d4f",
    appExternalDependencies: [
      {
        file: "OpenBurnBarCore/Sources/OpenBurnBarKernel/SharedModels/SwitcherProfile.swift",
        property: "canonicalAgentProvider",
      },
      {
        file: "OpenBurnBarCore/Sources/OpenBurnBarKernel/SharedModels/AgentProvider.swift",
        property: "providerID",
      },
    ],
    sharedDependencies: ["providerIDForSwitcherCLIType"],
    reason: "The shared-data target cannot depend on the app enum; both its frozen map and the app's enum dependencies are pinned. Fingerprints refreshed for Junie + Prime Agent + fx switcher providerIDs.",
  },
};

function walkSwiftFiles(root) {
  const files = [];
  for (const entry of readdirSync(root).sort()) {
    const candidate = path.join(root, entry);
    if (statSync(candidate).isDirectory()) files.push(...walkSwiftFiles(candidate));
    else if (candidate.endsWith(".swift")) files.push(candidate);
  }
  return files;
}

function matchingBrace(source, openingBrace) {
  let depth = 0;
  let mode = "code";
  let blockCommentDepth = 0;

  for (let index = openingBrace; index < source.length; index += 1) {
    const current = source[index];
    const next = source[index + 1];
    const nextTwo = source.slice(index, index + 3);

    if (mode === "line-comment") {
      if (current === "\n") mode = "code";
      continue;
    }
    if (mode === "block-comment") {
      if (current === "/" && next === "*") {
        blockCommentDepth += 1;
        index += 1;
      } else if (current === "*" && next === "/") {
        blockCommentDepth -= 1;
        index += 1;
        if (blockCommentDepth === 0) mode = "code";
      }
      continue;
    }
    if (mode === "string") {
      if (current === "\\") index += 1;
      else if (current === '"') mode = "code";
      continue;
    }
    if (mode === "multiline-string") {
      if (nextTwo === '\"\"\"') {
        mode = "code";
        index += 2;
      }
      continue;
    }

    if (current === "/" && next === "/") {
      mode = "line-comment";
      index += 1;
    } else if (current === "/" && next === "*") {
      mode = "block-comment";
      blockCommentDepth = 1;
      index += 1;
    } else if (nextTwo === '\"\"\"') {
      mode = "multiline-string";
      index += 2;
    } else if (current === '"') {
      mode = "string";
    } else if (current === "{") {
      depth += 1;
    } else if (current === "}") {
      depth -= 1;
      if (depth === 0) return index;
    }
  }
  throw new Error(`unclosed brace at offset ${openingBrace}`);
}

export function normalizeSwiftBody(source) {
  let result = "";
  let mode = "code";
  let blockCommentDepth = 0;

  for (let index = 0; index < source.length; index += 1) {
    const current = source[index];
    const next = source[index + 1];
    const nextTwo = source.slice(index, index + 3);

    if (mode === "line-comment") {
      if (current === "\n") mode = "code";
      continue;
    }
    if (mode === "block-comment") {
      if (current === "/" && next === "*") {
        blockCommentDepth += 1;
        index += 1;
      } else if (current === "*" && next === "/") {
        blockCommentDepth -= 1;
        index += 1;
        if (blockCommentDepth === 0) mode = "code";
      }
      continue;
    }
    if (mode === "string") {
      result += current;
      if (current === "\\") {
        result += next ?? "";
        index += 1;
      } else if (current === '"') {
        mode = "code";
      }
      continue;
    }
    if (mode === "multiline-string") {
      result += current;
      if (nextTwo === '\"\"\"') {
        result += '\"\"';
        index += 2;
        mode = "code";
      }
      continue;
    }

    if (current === "/" && next === "/") {
      mode = "line-comment";
      index += 1;
    } else if (current === "/" && next === "*") {
      mode = "block-comment";
      blockCommentDepth = 1;
      index += 1;
    } else if (nextTwo === '\"\"\"') {
      result += nextTwo;
      mode = "multiline-string";
      index += 2;
    } else if (current === '"') {
      result += current;
      mode = "string";
    } else if (!/\s/u.test(current)) {
      result += current;
    }
  }
  return result;
}

function sha256(value) {
  return createHash("sha256").update(value).digest("hex");
}

function extractFunctionBodies(source) {
  const bodies = new Map();
  const pattern = /\b(?:private\s+)?static\s+func\s+([A-Za-z0-9_]+)\s*\(/gu;
  for (const match of source.matchAll(pattern)) {
    const openingBrace = source.indexOf("{", match.index + match[0].length);
    assert.notEqual(openingBrace, -1, `function ${match[1]} has no body`);
    const closingBrace = matchingBrace(source, openingBrace);
    bodies.set(match[1], source.slice(openingBrace + 1, closingBrace));
  }
  return bodies;
}

function extractPropertyBody(source, property) {
  const pattern = new RegExp(`\\bvar\\s+${property}\\s*:[^\\n{=]+\\{`, "u");
  const match = pattern.exec(source);
  assert(match, `missing computed property ${property}`);
  const openingBrace = source.indexOf("{", match.index + match[0].length - 1);
  const closingBrace = matchingBrace(source, openingBrace);
  return source.slice(openingBrace + 1, closingBrace);
}

export function extractMigrationRegistrations(source) {
  const migrations = [];
  const pattern = /migrator\.registerMigration\("([^"\n]+)"\)\s*\{/gu;
  for (const match of source.matchAll(pattern)) {
    const openingBrace = source.indexOf("{", match.index + match[0].length - 1);
    const closingBrace = matchingBrace(source, openingBrace);
    migrations.push({ name: match[1], body: source.slice(openingBrace + 1, closingBrace) });
  }
  return migrations;
}

export function extractMigrationNames(source) {
  return extractMigrationRegistrations(source).map(({ name }) => name);
}

export function extractCatalogEntries(source) {
  return Array.from(
    source.matchAll(
      /^\s*"([^"|]+)\|(atomic)\|(unapplied-only)\|(backup-restore)\|([^"\n]+)"\s*$/gmu
    ),
    (match) => ({
      name: match[1],
      transaction: match[2],
      retry: match[3],
      rollback: match[4],
      description: match[5],
    })
  );
}

export function extractCatalogNames(source) {
  return extractCatalogEntries(source).map(({ name }) => name);
}

function assertUnique(names, label) {
  const duplicates = names.filter((name, index) => names.indexOf(name) !== index);
  assert.deepEqual(duplicates, [], `${label} contains duplicate migrations: ${duplicates.join(", ")}`);
}

function loadMigrationSurface(root, repoRoot, side) {
  const files = walkSwiftFiles(root);
  const functions = new Map();
  const allRegistrations = [];
  const dependencyNames = new Set(
    Object.values(INTENTIONAL_DIVERGENCES).flatMap((entry) => [
      ...(entry.appDependencies ?? []),
      ...(entry.sharedDependencies ?? []),
    ])
  );
  for (const file of files) {
    const source = readFileSync(file, "utf8");
    allRegistrations.push(...extractMigrationRegistrations(source));
    for (const [name, body] of extractFunctionBodies(source)) {
      if (!body.includes("migrator.registerMigration") && !dependencyNames.has(name)) continue;
      assert(!functions.has(name), `duplicate static function ${name} under ${root}`);
      functions.set(name, { body, source, file });
    }
  }

  const rootSource = readFileSync(path.join(root, "OpenBurnBarDatabase.swift"), "utf8");
  const callOrder = Array.from(
    rootSource.matchAll(/\b(register[A-Za-z0-9_]+)\(on:\s*&migrator\)/gu),
    (match) => match[1]
  );
  assert(callOrder.length > 0, `${root} has no ordered migrator registration calls`);

  const ordered = [];
  for (const functionName of callOrder) {
    const definition = functions.get(functionName);
    assert(definition, `${root} calls missing migration function ${functionName}`);
    for (const registration of extractMigrationRegistrations(definition.body)) {
      const divergence = INTENTIONAL_DIVERGENCES[registration.name];
      const dependencies = root.includes(`${path.sep}OpenBurnBarCore${path.sep}`)
        ? divergence?.sharedDependencies ?? []
        : divergence?.appDependencies ?? [];
      const dependencyBodies = dependencies.map((dependency) => {
        const dependencyDefinition = functions.get(dependency);
        assert(dependencyDefinition, `${registration.name} is missing dependency ${dependency}`);
        return dependencyDefinition.body;
      });
      const externalDependencyBodies = (divergence?.[`${side}ExternalDependencies`] ?? []).map(
        (dependency) => {
          const source = readFileSync(path.join(repoRoot, dependency.file), "utf8");
          return extractPropertyBody(source, dependency.property);
        }
      );
      ordered.push({
        ...registration,
        fingerprint: sha256(
          [registration.body, ...dependencyBodies, ...externalDependencyBodies]
            .map(normalizeSwiftBody)
            .join("\n--dependency--\n")
        ),
      });
    }
  }

  assert.equal(
    ordered.length,
    allRegistrations.length,
    `${root} has migration registrations outside the functions called by migrator`
  );
  return ordered;
}

export function assertMigrationParity(appMigrations, sharedMigrations) {
  const appNames = appMigrations.map(({ name }) => name);
  const sharedNames = sharedMigrations.map(({ name }) => name);
  assert.deepEqual(sharedNames, appNames, "shared-data migration registration order differs from the app migrator");

  for (let index = 0; index < appMigrations.length; index += 1) {
    const app = appMigrations[index];
    const shared = sharedMigrations[index];
    if (app.fingerprint === shared.fingerprint) continue;

    const allowed = INTENTIONAL_DIVERGENCES[app.name];
    assert(allowed, `${app.name} migration body differs without a reviewed exception`);
    assert.equal(app.fingerprint, allowed.app, `${app.name} app exception fingerprint changed`);
    assert.equal(shared.fingerprint, allowed.shared, `${app.name} shared exception fingerprint changed`);
    assert(allowed.reason.length >= 20, `${app.name} exception requires a substantive reason`);
  }
}

export function renderMigrationCatalog(entries) {
  const rows = entries.map(
    (entry, index) =>
      `| ${index + 1} | \`${entry.name}\` | ${entry.transaction} | ${entry.retry} | ${entry.rollback} | ${entry.description} |`
  );
  return [
    DOC_START,
    "| # | Name | Transaction | Retry | Rollback | Description |",
    "|---:|---|---|---|---|---|",
    ...rows,
    DOC_END,
  ].join("\n");
}

function updateOrVerifyDocumentation(repoRoot, entries, writeDocumentation) {
  const documentationPath = path.join(repoRoot, "docs", "DATABASE_OPERATIONS.md");
  const documentation = readFileSync(documentationPath, "utf8");
  const start = documentation.indexOf(DOC_START);
  const end = documentation.indexOf(DOC_END);
  assert(start >= 0 && end > start, "DATABASE_OPERATIONS.md is missing generated migration catalog markers");

  const expected = renderMigrationCatalog(entries);
  const actual = documentation.slice(start, end + DOC_END.length);
  if (writeDocumentation) {
    writeFileSync(
      documentationPath,
      `${documentation.slice(0, start)}${expected}${documentation.slice(end + DOC_END.length)}`
    );
  } else {
    assert.equal(actual, expected, "DATABASE_OPERATIONS.md migration catalog is stale; run verifier with --write-doc");
  }
}

export function verifyMigrationRollbackCatalog(repoRoot, { writeDocumentation = false } = {}) {
  const appMigrations = loadMigrationSurface(
    path.join(repoRoot, "AgentLens", "Services", "DataStore"),
    repoRoot,
    "app"
  );
  const sharedMigrations = loadMigrationSurface(
    path.join(repoRoot, "OpenBurnBarCore", "Sources", "OpenBurnBarData"),
    repoRoot,
    "shared"
  );
  const rollbackSource = readFileSync(path.join(repoRoot, "scripts", "rollback-migration.sh"), "utf8");
  const rollbackEntries = extractCatalogEntries(rollbackSource);
  const rollbackNames = rollbackEntries.map(({ name }) => name);

  assertUnique(appMigrations.map(({ name }) => name), "app migrator");
  assertUnique(sharedMigrations.map(({ name }) => name), "shared-data migrator");
  assertUnique(rollbackNames, "rollback catalog");
  assertMigrationParity(appMigrations, sharedMigrations);
  assert.deepEqual(rollbackNames, appMigrations.map(({ name }) => name), "rollback catalog order differs from migrator");
  updateOrVerifyDocumentation(repoRoot, rollbackEntries, writeDocumentation);

  return appMigrations.length;
}

const currentFile = fileURLToPath(import.meta.url);
if (process.argv[1] && path.resolve(process.argv[1]) === currentFile) {
  const repoRoot = path.resolve(path.dirname(currentFile), "..", "..");
  const writeDocumentation = process.argv.includes("--write-doc");
  const count = verifyMigrationRollbackCatalog(repoRoot, { writeDocumentation });
  console.log(
    `migration contract: ${count} ordered migrations, normalized bodies, rollback catalog, and documentation verified`
  );
}
