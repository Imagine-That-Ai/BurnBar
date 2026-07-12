import { test } from "node:test";
import assert from "node:assert/strict";
import { mkdtempSync, mkdirSync, writeFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, dirname } from "node:path";

import {
  parseFTS5Config,
  splitTopLevel,
  parseCSharpStringArray,
  parseRegisterOrder,
  extractSwiftMigrations,
  replayMigrations,
  extractWindows,
  diffSchemaSurfaces,
  reconcileBaseline,
  runParityCheck,
  SURFACES,
  BASELINE_PATH,
} from "./check-migrator-parity.mjs";

// ---------------------------------------------------------------------------
// Unit: parsing primitives
// ---------------------------------------------------------------------------

test("splitTopLevel respects nesting and strings", () => {
  assert.deepEqual(splitTopLevel("a, b(c, d), 'x, y', e"), [
    "a",
    "b(c, d)",
    "'x, y'",
    "e",
  ]);
});

test("parseFTS5Config separates columns, UNINDEXED flags, and options", () => {
  const cfg = parseFTS5Config(
    "inferredTaskTitle,\n fullText,\n chunkID UNINDEXED,\n content='conversations',\n content_rowid='rowid',\n tokenize='porter unicode61'",
  );
  assert.deepEqual(cfg.columns, [
    "inferredTaskTitle",
    "fullText",
    "chunkID UNINDEXED",
  ]);
  assert.equal(cfg.options.content, "conversations");
  assert.equal(cfg.options.content_rowid, "rowid");
  assert.equal(cfg.options.tokenize, "porter unicode61");
});

test("parseCSharpStringArray handles regular strings, raw strings, and symbols", () => {
  const text = `
    private static readonly string[] Items =
    {
        "one",
        """
        CREATE TABLE t (
            id TEXT NOT NULL PRIMARY KEY
        )
        """,
        SomeSymbol,
    };
  `;
  const entries = parseCSharpStringArray(text, "Items");
  assert.equal(entries.length, 3);
  assert.deepEqual(entries[0], { kind: "string", value: "one" });
  assert.match(entries[1].value, /CREATE TABLE t/);
  assert.deepEqual(entries[2], { kind: "symbol", value: "SomeSymbol" });
});

test("parseCSharpStringArray ignores // and /* */ comments inside the literal", () => {
  const text = `
    private static readonly string[] Items =
    {
        "one",
        // a comment with "quotes" and 'apostrophes' that must not become entries
        /* block comment with "more quotes" */
        "two",
    };
  `;
  const entries = parseCSharpStringArray(text, "Items");
  assert.deepEqual(
    entries.map((e) => e.value),
    ["one", "two"],
  );
});

test("parseRegisterOrder returns register calls in source order", () => {
  const text = `
    static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()
        registerB(on: &migrator)
        registerA(on: &migrator)
        return migrator
    }
  `;
  assert.deepEqual(parseRegisterOrder(text, "x.swift"), [
    "registerB",
    "registerA",
  ]);
});

// ---------------------------------------------------------------------------
// Unit: replay semantics (create / drop / rename / alter / DSL / auto-index)
// ---------------------------------------------------------------------------

test("replayMigrations applies DDL in order across DSL and raw SQL", () => {
  const migrations = [
    {
      id: "v1_initial",
      body: `
        registerMigration("v1_initial") { db in
            try db.create(table: "conversations") { t in
                t.column("id", .text).primaryKey()
                t.column("provider", .text).notNull().indexed()
                t.column("fullText", .text).notNull()
                t.column("inferredTaskTitle", .text).notNull()
            }
            try db.execute(sql: """
                CREATE VIRTUAL TABLE conversations_fts USING fts5(
                    inferredTaskTitle,
                    fullText,
                    content='conversations',
                    content_rowid='rowid',
                    tokenize='porter unicode61'
                )
            """)
      `,
    },
    {
      id: "v2_standalone",
      body: `
        registerMigration("v2_standalone") { db in
            try db.execute(sql: "DROP TABLE IF EXISTS conversations_fts")
            try db.execute(sql: """
                CREATE VIRTUAL TABLE conversations_fts USING fts5(
                    inferredTaskTitle,
                    fullText,
                    tokenize='porter unicode61'
                )
            """)
            try db.execute(sql: """
                CREATE TRIGGER conversations_ai AFTER INSERT ON conversations BEGIN
                    INSERT INTO conversations_fts(rowid, inferredTaskTitle, fullText)
                    VALUES (new.rowid, new.inferredTaskTitle, new.fullText);
                END
            """)
            try db.alter(table: "conversations") { t in
                t.add(column: "deletedAt", .datetime)
            }
            try db.execute(sql: "ALTER TABLE conversations RENAME TO convos")
      `,
    },
  ];
  const state = replayMigrations(migrations);

  // conversations was renamed; rename carries columns, indexes, triggers.
  assert.ok(!state.tables.has("conversations"));
  assert.ok(state.tables.has("convos"));
  assert.ok(state.tables.get("convos").has("deletedAt"));
  assert.equal(state.indexes.get("conversations_on_provider").table, "convos");
  assert.equal(state.triggers.get("conversations_ai").table, "convos");

  // FTS was dropped and recreated STANDALONE (no content option).
  const fts = state.virtualTables.get("conversations_fts");
  assert.deepEqual(fts.columns, ["inferredTaskTitle", "fullText"]);
  assert.equal(fts.options.content, undefined);
  assert.equal(fts.options.tokenize, "porter unicode61");
});

test("diffSchemaSurfaces reports missing/extra tables, column deltas, fts config", () => {
  const canonical = replayMigrations([
    {
      id: "v1",
      body: `
        registerMigration("v1") { db in
          try db.execute(sql: "CREATE TABLE a (id TEXT PRIMARY KEY, x TEXT)")
          try db.execute(sql: "CREATE TABLE b (id TEXT PRIMARY KEY)")
          try db.execute(sql: "CREATE VIRTUAL TABLE f USING fts5(t, tokenize='porter')")
        }`,
    },
  ]);
  const mirror = replayMigrations([
    {
      id: "v1",
      body: `
        registerMigration("v1") { db in
          try db.execute(sql: "CREATE TABLE a (id TEXT PRIMARY KEY, y TEXT)")
          try db.execute(sql: "CREATE TABLE c (id TEXT PRIMARY KEY)")
          try db.execute(sql: "CREATE VIRTUAL TABLE f USING fts5(t, tokenize='unicode61')")
        }`,
    },
  ]);
  const keys = diffSchemaSurfaces("m", canonical, mirror).map((d) => d.key);
  assert.ok(keys.includes("m:missing-table:b"));
  assert.ok(keys.includes("m:extra-table:c"));
  assert.ok(keys.includes("m:table:a:missing-columns:x"));
  assert.ok(keys.includes("m:table:a:extra-columns:y"));
  assert.ok(keys.includes("m:fts-config:f"));
});

test("reconcileBaseline flags new, stale, and unannotated divergences", () => {
  const computed = [
    { key: "w:missing-table:a", detail: "a" },
    { key: "w:missing-table:b", detail: "b" },
  ];
  const baseline = {
    divergences: [
      { key: "w:missing-table:a", reason: "intentional: subsystem not ported" },
      { key: "w:missing-table:gone", reason: "was fixed" },
    ],
  };
  const errors = reconcileBaseline(computed, baseline);
  assert.equal(errors.length, 2);
  assert.match(errors[0], /NEW divergence not in baseline: w:missing-table:b/);
  assert.match(errors[1], /STALE baseline entry .*w:missing-table:gone/);

  const todoErrors = reconcileBaseline(
    [{ key: "w:x", detail: "x" }],
    { divergences: [{ key: "w:x", reason: "TODO: annotate divergence" }] },
  );
  assert.equal(todoErrors.length, 1);
  assert.match(todoErrors[0], /no real annotation/);
});

// ---------------------------------------------------------------------------
// Integration: synthetic repo tree end-to-end
// ---------------------------------------------------------------------------

const SWIFT_ASSEMBLY = `
extension OpenBurnBarDatabase {
    static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()
        registerCoreMigrations(on: &migrator)
        return migrator
    }
}
`;

const SWIFT_MIGRATIONS = `
extension OpenBurnBarDatabase {
    static func registerCoreMigrations(on migrator: inout DatabaseMigrator) {
        migrator.registerMigration("v1_initial") { db in
            try db.create(table: "conversations") { t in
                t.column("id", .text).primaryKey()
                t.column("inferredTaskTitle", .text).notNull()
                t.column("fullText", .text).notNull()
                t.column("deletedAt", .datetime)
            }
            try db.execute(sql: """
                CREATE VIRTUAL TABLE conversations_fts USING fts5(
                    inferredTaskTitle,
                    fullText,
                    tokenize='porter unicode61'
                )
            """)
            try db.execute(sql: "CREATE TRIGGER conversations_ai AFTER INSERT ON conversations BEGIN INSERT INTO conversations_fts(rowid, inferredTaskTitle, fullText) VALUES (new.rowid, new.inferredTaskTitle, new.fullText); END")
            try db.execute(sql: "CREATE TRIGGER conversations_ad AFTER DELETE ON conversations BEGIN DELETE FROM conversations_fts WHERE rowid = old.rowid; END")
            try db.execute(sql: "CREATE TRIGGER conversations_au AFTER UPDATE ON conversations BEGIN DELETE FROM conversations_fts WHERE rowid = old.rowid; END")
        }
        migrator.registerMigration("v2_endpoint") { db in
            try db.execute(sql: "CREATE TABLE token_usage (id TEXT NOT NULL PRIMARY KEY, provider TEXT NOT NULL)")
        }
    }
}
`;

const WINDOWS_PROVISIONING = `
public sealed partial class WindowsSqlCipherProvisioner
{
    public const string CurrentMigrationEndpoint = "v2_endpoint";
    public const long CurrentMigrationCount = 2;

    private static readonly string[] SchemaStatements =
    {
        "CREATE TABLE IF NOT EXISTS grdb_migrations (identifier TEXT NOT NULL PRIMARY KEY)",
        """
        CREATE TABLE IF NOT EXISTS conversations (
            id TEXT NOT NULL PRIMARY KEY,
            inferredTaskTitle TEXT NOT NULL,
            fullText TEXT NOT NULL,
            deletedAt TEXT
        )
        """,
        "CREATE VIRTUAL TABLE IF NOT EXISTS conversations_fts USING fts5(inferredTaskTitle, fullText, tokenize='porter unicode61')",
        "CREATE TRIGGER IF NOT EXISTS conversations_ai AFTER INSERT ON conversations BEGIN INSERT INTO conversations_fts(rowid, inferredTaskTitle, fullText) VALUES (new.rowid, new.inferredTaskTitle, new.fullText); END",
        "CREATE TRIGGER IF NOT EXISTS conversations_ad AFTER DELETE ON conversations BEGIN DELETE FROM conversations_fts WHERE rowid = old.rowid; END",
        "CREATE TRIGGER IF NOT EXISTS conversations_au AFTER UPDATE ON conversations BEGIN DELETE FROM conversations_fts WHERE rowid = old.rowid; END",
        "CREATE TABLE IF NOT EXISTS token_usage (id TEXT NOT NULL PRIMARY KEY, provider TEXT NOT NULL)",
    };
}
`;

const WINDOWS_METADATA = `
public sealed partial class WindowsSqlCipherProvisioner
{
    private static readonly string[] AppliedMigrationIdentifiers =
    {
        "v1_initial",
        CurrentMigrationEndpoint,
    };
}
`;

const LINUX_TESTS = `
final class OpenBurnBarDataLinuxTests: XCTestCase {
    func testMigrations() throws {
        XCTAssertEqual(migrations.last, "v2_endpoint")
        XCTAssertEqual(try database.migrationRows().last, "v2_endpoint")
    }
}
`;

const LINUX_MANIFEST = JSON.stringify({
  suites: [
    {
      id: "linux-data",
      target: "OpenBurnBarDataTests",
      filter: "OpenBurnBarDataTests.OpenBurnBarDataLinuxTests",
    },
  ],
});

const COMPAT_VECTOR = JSON.stringify({
  migrationCount: 2,
  schemaEndpoint: "v2_endpoint",
});

function writeTree(root, overrides = {}) {
  const files = {
    [join(SURFACES.swiftCanon.dir, SURFACES.swiftCanon.assembly)]: SWIFT_ASSEMBLY,
    [join(SURFACES.swiftCanon.dir, "Migrations.swift")]: SWIFT_MIGRATIONS,
    [join(SURFACES.agentLens.dir, SURFACES.agentLens.assembly)]: SWIFT_ASSEMBLY,
    [join(SURFACES.agentLens.dir, "Migrations.swift")]: SWIFT_MIGRATIONS,
    [SURFACES.windows.provisioning]: WINDOWS_PROVISIONING,
    [SURFACES.windows.metadata]: WINDOWS_METADATA,
    [SURFACES.linux.dataLinuxTests]: LINUX_TESTS,
    [SURFACES.linux.manifest]: LINUX_MANIFEST,
    [SURFACES.linux.compatVector]: COMPAT_VECTOR,
    [BASELINE_PATH]: JSON.stringify({ divergences: [] }),
    ...overrides,
  };
  for (const [rel, content] of Object.entries(files)) {
    if (content === null) continue;
    const abs = join(root, rel);
    mkdirSync(dirname(abs), { recursive: true });
    writeFileSync(abs, content);
  }
}

function makeRoot() {
  return mkdtempSync(join(tmpdir(), "migrator-parity-test-"));
}

const LOW_FLOORS = { minMigrations: 2, minTables: 2 };

test("synthetic tree: full parity passes with zero divergences", () => {
  const root = makeRoot();
  try {
    writeTree(root);
    const result = runParityCheck(root, LOW_FLOORS);
    assert.deepEqual(result.hardErrors, []);
    assert.deepEqual(result.computedDivergences, []);
    assert.deepEqual(result.canon.identifiers, ["v1_initial", "v2_endpoint"]);
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
});

test("synthetic tree: Windows identifier reorder is a hard error", () => {
  const root = makeRoot();
  try {
    writeTree(root, {
      [SURFACES.windows.metadata]: WINDOWS_METADATA.replace(
        '"v1_initial",\n        CurrentMigrationEndpoint,',
        'CurrentMigrationEndpoint,\n        "v1_initial",',
      ),
    });
    const result = runParityCheck(root, LOW_FLOORS);
    assert.ok(
      result.hardErrors.some((e) =>
        e.includes("Windows AppliedMigrationIdentifiers diverged"),
      ),
      `expected identifier hard error, got: ${JSON.stringify(result.hardErrors)}`,
    );
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
});

test("synthetic tree: new Swift table missing on Windows is a divergence", () => {
  const root = makeRoot();
  try {
    writeTree(root, {
      [join(SURFACES.swiftCanon.dir, "Migrations.swift")]:
        SWIFT_MIGRATIONS.replace(
          'try db.execute(sql: "CREATE TABLE token_usage',
          'try db.execute(sql: "CREATE TABLE brand_new (id TEXT PRIMARY KEY)")\n            try db.execute(sql: "CREATE TABLE token_usage',
        ),
      [join(SURFACES.agentLens.dir, "Migrations.swift")]:
        SWIFT_MIGRATIONS.replace(
          'try db.execute(sql: "CREATE TABLE token_usage',
          'try db.execute(sql: "CREATE TABLE brand_new (id TEXT PRIMARY KEY)")\n            try db.execute(sql: "CREATE TABLE token_usage',
        ),
    });
    const result = runParityCheck(root, LOW_FLOORS);
    assert.deepEqual(result.hardErrors, []);
    const keys = result.computedDivergences.map((d) => d.key);
    assert.ok(keys.includes("windows:missing-table:brand_new"));
    // ...and the empty committed baseline must reject it.
    const errors = reconcileBaseline(result.computedDivergences, {
      divergences: [],
    });
    assert.ok(errors.some((e) => e.includes("windows:missing-table:brand_new")));
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
});

test("synthetic tree: Windows FTS config drift (external content) is caught", () => {
  const root = makeRoot();
  try {
    writeTree(root, {
      [SURFACES.windows.provisioning]: WINDOWS_PROVISIONING.replace(
        "USING fts5(inferredTaskTitle, fullText, tokenize='porter unicode61')",
        "USING fts5(fullText, inferredTaskTitle, tokenize='porter unicode61', content='conversations', content_rowid='rowid')",
      ),
    });
    const result = runParityCheck(root, LOW_FLOORS);
    const keys = result.computedDivergences.map((d) => d.key);
    assert.ok(
      keys.includes("windows:fts-config:conversations_fts"),
      `expected fts-config divergence, got: ${JSON.stringify(keys)}`,
    );
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
});

test("synthetic tree: canonical FTS going external-content is a hard error (ftsRowid contract)", () => {
  const root = makeRoot();
  try {
    const external = SWIFT_MIGRATIONS.replace(
      "fullText,\n                    tokenize='porter unicode61'",
      "fullText,\n                    content='conversations',\n                    content_rowid='rowid',\n                    tokenize='porter unicode61'",
    );
    writeTree(root, {
      [join(SURFACES.swiftCanon.dir, "Migrations.swift")]: external,
      [join(SURFACES.agentLens.dir, "Migrations.swift")]: external,
    });
    const result = runParityCheck(root, LOW_FLOORS);
    assert.ok(
      result.hardErrors.some((e) => e.includes("no longer standalone")),
      `expected ftsRowid hard error, got: ${JSON.stringify(result.hardErrors)}`,
    );
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
});

test("synthetic tree: dropping the rowid-mirror trigger is a hard error", () => {
  const root = makeRoot();
  try {
    const noTrigger = SWIFT_MIGRATIONS.replace(
      /try db\.execute\(sql: "CREATE TRIGGER conversations_au[^\n]*\n/,
      "",
    );
    writeTree(root, {
      [join(SURFACES.swiftCanon.dir, "Migrations.swift")]: noTrigger,
      [join(SURFACES.agentLens.dir, "Migrations.swift")]: noTrigger,
    });
    const result = runParityCheck(root, LOW_FLOORS);
    assert.ok(
      result.hardErrors.some((e) => e.includes("conversations_au")),
      `expected trigger hard error, got: ${JSON.stringify(result.hardErrors)}`,
    );
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
});

test("synthetic tree: AgentLens copy drift is a hard error", () => {
  const root = makeRoot();
  try {
    writeTree(root, {
      [join(SURFACES.agentLens.dir, "Migrations.swift")]:
        SWIFT_MIGRATIONS.replace('"v2_endpoint"', '"v2_renamed"'),
    });
    const result = runParityCheck(root, LOW_FLOORS);
    assert.ok(
      result.hardErrors.some((e) =>
        e.includes("AgentLens migrator identifier list diverged"),
      ),
      `expected AgentLens hard error, got: ${JSON.stringify(result.hardErrors)}`,
    );
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
});

test("synthetic tree: Windows count/endpoint const drift is a hard error", () => {
  const root = makeRoot();
  try {
    writeTree(root, {
      [SURFACES.windows.provisioning]: WINDOWS_PROVISIONING.replace(
        "CurrentMigrationCount = 2",
        "CurrentMigrationCount = 3",
      ),
    });
    const result = runParityCheck(root, LOW_FLOORS);
    assert.ok(
      result.hardErrors.some((e) => e.includes("CurrentMigrationCount")),
    );
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
});

test("synthetic tree: Linux pin drift and manifest loss are hard errors", () => {
  const root = makeRoot();
  try {
    writeTree(root, {
      [SURFACES.linux.dataLinuxTests]: LINUX_TESTS.replaceAll(
        '"v2_endpoint"',
        '"v1_initial"',
      ),
      [SURFACES.linux.manifest]: JSON.stringify({ suites: [] }),
      [SURFACES.linux.compatVector]: JSON.stringify({
        migrationCount: 1,
        schemaEndpoint: "v1_initial",
      }),
    });
    const result = runParityCheck(root, LOW_FLOORS);
    const text = result.hardErrors.join("\n");
    assert.match(text, /does not pin the current migrator endpoint/);
    assert.match(text, /no longer runs OpenBurnBarDataTests/);
    assert.match(text, /vector migrationCount/);
    assert.match(text, /vector schemaEndpoint/);
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
});

// ---------------------------------------------------------------------------
// Live repo: the committed tree must satisfy the ratchet
// ---------------------------------------------------------------------------

test("live repo: real tree passes against the committed baseline", async () => {
  const repoRoot = join(import.meta.dirname, "..");
  const result = runParityCheck(repoRoot);
  assert.deepEqual(result.hardErrors, []);
  const { loadBaseline } = await import("./check-migrator-parity.mjs");
  const errors = reconcileBaseline(
    result.computedDivergences,
    loadBaseline(repoRoot),
  );
  assert.deepEqual(errors, []);
});
