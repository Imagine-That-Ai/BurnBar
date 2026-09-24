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

// The verifier walks this directory whole, so the fixture mirrors it whole.
// Enumerating the migration files by hand meant every new migration had to be
// remembered here too, and forgetting left the mutation tests running against
// a partial migration surface — still throwing, just for the wrong reason,
// which is the one failure mode a fail-closed contract test cannot have.
// (Wave 2.2 deleted the AgentLens twin: OpenBurnBarData is the only surface.)
const migrationDirectories = [
  path.join("OpenBurnBarCore", "Sources", "OpenBurnBarData"),
];

function copyFiles(sourceDirectory, destinationDirectory, files) {
  mkdirSync(destinationDirectory, { recursive: true });
  for (const file of files) cpSync(path.join(sourceDirectory, file), path.join(destinationDirectory, file));
}

function fixture(t) {
  const root = mkdtempSync(path.join(tmpdir(), "openburnbar-migration-contract-"));
  t.after(() => rmSync(root, { recursive: true, force: true }));
  for (const directory of migrationDirectories) {
    cpSync(path.join(repoRoot, directory), path.join(root, directory), { recursive: true });
  }
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
  // 71 as of v70_agent_memories_index_backfill. This literal is a deliberate
  // tripwire, not a derived value: pinning it means adding a migration cannot
  // quietly pass by agreeing with itself, and forces the author past every
  // mirror. Bump it ONLY together with the migrator, the rollback catalog, the
  // Windows endpoint/count, and the byte-compat vector.
  assert.equal(verifyMigrationRollbackCatalog(repoRoot), 71);
});

test("registration reorder fails closed", (t) => {
  const root = fixture(t);
  mutate(
    root,
    "OpenBurnBarCore/Sources/OpenBurnBarData/OpenBurnBarDatabase.swift",
    "registerDataMigrationsV1toV20(on: &migrator)\n        registerDataMigrationsV21toV40(on: &migrator)",
    "registerDataMigrationsV21toV40(on: &migrator)\n        registerDataMigrationsV1toV20(on: &migrator)"
  );
  assert.throws(() => verifyMigrationRollbackCatalog(root), /rollback catalog order differs from migrator/u);
});

test("registration outside a migrator-called function fails closed", (t) => {
  const root = fixture(t);
  // providerIDForSwitcherCLIType is a helper no migrator call reaches, so a
  // registration smuggled into its body is invisible to the ordered walk but
  // visible to the whole-directory scan.
  mutate(
    root,
    "OpenBurnBarCore/Sources/OpenBurnBarData/OpenBurnBarDatabase+DataMigrationsV41toV51.swift",
    "static func providerIDForSwitcherCLIType(_ rawValue: String) -> String? {",
    'static func providerIDForSwitcherCLIType(_ rawValue: String) -> String? {\n        migrator.registerMigration("v46_sneaky_unregistered") { _ in }'
  );
  assert.throws(
    () => verifyMigrationRollbackCatalog(root),
    /has migration registrations outside the functions called by migrator/u
  );
});

test("catalog missing a migration fails closed", (t) => {
  const root = fixture(t);
  mutate(
    root,
    "scripts/rollback-migration.sh",
    '"v70_agent_memories_index_backfill|atomic|unapplied-only|backup-restore|',
    '"v70_agent_memories_index_backfill|atomic|unapplied-only|dropped|'
  );
  assert.throws(() => verifyMigrationRollbackCatalog(root), /rollback catalog order differs from migrator/u);
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
