#!/usr/bin/env node
import assert from "node:assert/strict";
import {
  closeSync,
  cpSync,
  mkdtempSync,
  mkdirSync,
  openSync,
  readFileSync,
  readdirSync,
  rmSync,
  writeFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import { spawnSync } from "node:child_process";
import test from "node:test";
import { fileURLToPath } from "node:url";
import {
  extractCatalogNames,
  extractMigrationNames,
  normalizeSwiftBody,
  verifyMigrationRollbackCatalog,
} from "./verify-migration-rollback-catalog.mjs";

const repoRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..", "..");
const appFiles = [
  "OpenBurnBarDatabase.swift",
  "OpenBurnBarDatabase+MigrationsV1toV20.swift",
  "OpenBurnBarDatabase+MigrationsV21toV40.swift",
  "OpenBurnBarDatabase+MigrationsV41toV51.swift",
  "OpenBurnBarDatabase+MemoryMigrations.swift",
  "OpenBurnBarDatabase+MigrationV55.swift",
  "OpenBurnBarDatabase+MigrationV56.swift",
  "OpenBurnBarDatabase+MigrationV57.swift",
  "OpenBurnBarDatabase+MigrationV58.swift",
  "OpenBurnBarDatabase+MigrationV59.swift",
  "OpenBurnBarDatabase+MigrationV60.swift",
  "OpenBurnBarDatabase+UsageMemoryMigrations.swift",
  "OpenBurnBarDatabase+MigrationV62.swift",
  "OpenBurnBarDatabase+StandingOrderMigrations.swift",
  "OpenBurnBarDatabase+CommandBoardIndexMigration.swift",
];
const sharedFiles = [
  "OpenBurnBarDatabase.swift",
  "OpenBurnBarDatabase+DataMigrationsV1toV20.swift",
  "OpenBurnBarDatabase+DataMigrationsV21toV40.swift",
  "OpenBurnBarDatabase+DataMigrationsV41toV51.swift",
  "OpenBurnBarDatabase+MemoryMigrations.swift",
  "OpenBurnBarDatabase+DataMigrationV55.swift",
  "OpenBurnBarDatabase+DataMigrationV56.swift",
  "OpenBurnBarDatabase+DataMigrationV57.swift",
  "OpenBurnBarDatabase+DataMigrationV58.swift",
  "OpenBurnBarDatabase+DataMigrationV59.swift",
  "OpenBurnBarDatabase+DataMigrationV60.swift",
  "OpenBurnBarDatabase+UsageMemoryMigrations.swift",
  "OpenBurnBarDatabase+DataMigrationV62.swift",
  "OpenBurnBarDatabase+StandingOrderMigrations.swift",
  "OpenBurnBarDatabase+CommandBoardIndexMigration.swift",
];

function copyFiles(sourceDirectory, destinationDirectory, files) {
  mkdirSync(destinationDirectory, { recursive: true });
  for (const file of files) cpSync(path.join(sourceDirectory, file), path.join(destinationDirectory, file));
}

function fixture(t) {
  const root = mkdtempSync(path.join(tmpdir(), "openburnbar-migration-contract-"));
  t.after(() => rmSync(root, { recursive: true, force: true }));
  copyFiles(
    path.join(repoRoot, "AgentLens", "Services", "DataStore"),
    path.join(root, "AgentLens", "Services", "DataStore"),
    appFiles
  );
  copyFiles(
    path.join(repoRoot, "OpenBurnBarCore", "Sources", "OpenBurnBarData"),
    path.join(root, "OpenBurnBarCore", "Sources", "OpenBurnBarData"),
    sharedFiles
  );
  copyFiles(
    path.join(repoRoot, "OpenBurnBarCore", "Sources", "OpenBurnBarKernel", "SharedModels"),
    path.join(root, "OpenBurnBarCore", "Sources", "OpenBurnBarKernel", "SharedModels"),
    ["SwitcherProfile.swift", "AgentProvider.swift"]
  );
  copyFiles(path.join(repoRoot, "scripts"), path.join(root, "scripts"), ["rollback-migration.sh"]);
  copyFiles(path.join(repoRoot, "docs"), path.join(root, "docs"), ["DATABASE_OPERATIONS.md"]);
  return root;
}

function mutate(root, relativePath, before, after) {
  const file = path.join(root, relativePath);
  const source = readFileSync(file, "utf8");
  assert(source.includes(before), `${relativePath} is missing mutation target`);
  writeFileSync(file, source.replace(before, after));
}

test("extracts balanced Swift migration registrations", () => {
  assert.deepEqual(
    extractMigrationNames(`
      migrator.registerMigration("v1_initial") { db in
        try db.create(table: "items") { table in table.column("value{still-a-string}") }
      }
      migrator.registerMigration("v2_sync") { _ in /* { ignored } */ }
    `),
    ["v1_initial", "v2_sync"]
  );
});

test("normalization ignores layout and comments but preserves string contents", () => {
  assert.equal(normalizeSwiftBody("try work( 1 ) // note\n"), normalizeSwiftBody("try work(1)"));
  assert.notEqual(normalizeSwiftBody('try sql("a b")'), normalizeSwiftBody('try sql("ab")'));
});

test("extracts only complete migration contracts", () => {
  assert.deepEqual(
    extractCatalogNames(`
      MIGRATIONS=(
        "v1_initial|atomic|unapplied-only|backup-restore|Initial schema"
        "v2_old|safe-rerun|Old unsafe claim"
      )
    `),
    ["v1_initial"]
  );
});

test("current migration surfaces, catalog, and generated documentation agree", () => {
  // 65 as of v64_token_usage_start_time_index. This literal is a deliberate
  // tripwire, not a derived value: pinning it means adding a migration cannot
  // quietly pass by agreeing with itself, and forces the author past every
  // mirror. Bump it ONLY together with the migrator, the rollback catalog, the
  // Windows endpoint/count, and the byte-compat vector.
  assert.equal(verifyMigrationRollbackCatalog(repoRoot), 65);
});

test("registration reorder fails closed", (t) => {
  const root = fixture(t);
  mutate(
    root,
    "OpenBurnBarCore/Sources/OpenBurnBarData/OpenBurnBarDatabase.swift",
    "registerDataMigrationsV1toV20(on: &migrator)\n        registerDataMigrationsV21toV40(on: &migrator)",
    "registerDataMigrationsV21toV40(on: &migrator)\n        registerDataMigrationsV1toV20(on: &migrator)"
  );
  assert.throws(() => verifyMigrationRollbackCatalog(root), /registration order differs/u);
});

test("migration body mutation fails closed", (t) => {
  const root = fixture(t);
  mutate(
    root,
    "OpenBurnBarCore/Sources/OpenBurnBarData/OpenBurnBarDatabase+DataMigrationsV41toV51.swift",
    "MAX(inputTokens, 0)",
    "MAX(inputTokens, 1)"
  );
  assert.throws(() => verifyMigrationRollbackCatalog(root), /v41_reprice_openai_family_cached_input migration body differs/u);
});

test("column-default mutation fails closed", (t) => {
  const root = fixture(t);
  mutate(
    root,
    "OpenBurnBarCore/Sources/OpenBurnBarData/OpenBurnBarDatabase+DataMigrationsV1toV20.swift",
    '.defaults(to: "provider_log")',
    '.defaults(to: "mutated_default")'
  );
  assert.throws(() => verifyMigrationRollbackCatalog(root), /v9_source_type migration body differs/u);
});

test("allowlisted provider mapping mutation invalidates its pinned fingerprint", (t) => {
  const root = fixture(t);
  mutate(
    root,
    "OpenBurnBarCore/Sources/OpenBurnBarData/OpenBurnBarDatabase+DataMigrationsV41toV51.swift",
    'case "codex":\n            return "codex"',
    'case "codex":\n            return "mutated-provider"'
  );
  assert.throws(() => verifyMigrationRollbackCatalog(root), /v46_drain_target_per_provider shared exception fingerprint changed/u);
});

test("app enum mapping mutation invalidates the migration dependency fingerprint", (t) => {
  const root = fixture(t);
  mutate(
    root,
    "OpenBurnBarCore/Sources/OpenBurnBarKernel/SharedModels/SwitcherProfile.swift",
    "case .junie: return .junie",
    "case .junie: return .codex"
  );
  assert.throws(() => verifyMigrationRollbackCatalog(root), /v46_drain_target_per_provider app exception fingerprint changed/u);
});

test("stale generated catalog fails closed", (t) => {
  const root = fixture(t);
  mutate(
    root,
    "docs/DATABASE_OPERATIONS.md",
    "Durable provider quota snapshot cache",
    "Stale provider quota description"
  );
  assert.throws(() => verifyMigrationRollbackCatalog(root), /migration catalog is stale/u);
});

test("inspection creates a checksummed main-file and WAL bundle without sqlite3", (t) => {
  const home = mkdtempSync(path.join(tmpdir(), "openburnbar-rollback-home-"));
  t.after(() => rmSync(home, { recursive: true, force: true }));
  const support = path.join(home, "Library", "Application Support", "OpenBurnBar");
  mkdirSync(support, { recursive: true });
  writeFileSync(path.join(support, "openburnbar.sqlite"), "encrypted-main");
  writeFileSync(path.join(support, "openburnbar.sqlite-wal"), "encrypted-wal");

  const result = spawnSync(path.join(repoRoot, "scripts", "rollback-migration.sh"), ["--inspect"], {
    env: { ...process.env, HOME: home },
    encoding: "utf8",
  });
  assert.equal(result.status, 0, result.stderr);
  assert.match(result.stdout, /Stock sqlite3 cannot inspect SQLCipher ciphertext/u);

  const backupRoot = path.join(support, "backups");
  const bundle = path.join(backupRoot, readdirSync(backupRoot).find((entry) => entry.endsWith(".bundle")));
  assert.deepEqual(readdirSync(bundle).sort(), ["SHA256SUMS", "openburnbar.sqlite", "openburnbar.sqlite-wal"]);
  const checksum = spawnSync("shasum", ["-a", "256", "-c", "SHA256SUMS"], {
    cwd: bundle,
    encoding: "utf8",
  });
  assert.equal(checksum.status, 0, checksum.stderr);
});

test("inspection refuses a database held open by another process", (t) => {
  const home = mkdtempSync(path.join(tmpdir(), "openburnbar-rollback-open-home-"));
  t.after(() => rmSync(home, { recursive: true, force: true }));
  const support = path.join(home, "Library", "Application Support", "OpenBurnBar");
  mkdirSync(support, { recursive: true });
  const database = path.join(support, "openburnbar.sqlite");
  writeFileSync(database, "encrypted-main");
  const descriptor = openSync(database, "r");
  t.after(() => closeSync(descriptor));

  const result = spawnSync(path.join(repoRoot, "scripts", "rollback-migration.sh"), ["--inspect"], {
    env: { ...process.env, HOME: home },
    encoding: "utf8",
  });
  assert.equal(result.status, 1);
  assert.match(result.stderr, /still has the database open/u);
});
