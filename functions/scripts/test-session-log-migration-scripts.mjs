#!/usr/bin/env node

import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";

import { commitBatch as commitBackfillBatch } from "./backfill-legacy-session-log-cloud-search-v3.mjs";
import { buildUploadPlan, readLocalRows } from "./upload-local-sqlite-session-logs-v4.mjs";

function makeFakeDb() {
  const commits = [];
  return {
    commits,
    doc(refPath) {
      return { path: refPath };
    },
    collection(refPath) {
      return {
        doc(id) {
          return { path: `${refPath}/${id}` };
        },
      };
    },
    batch() {
      const writes = [];
      return {
        set(ref, data, options) {
          writes.push({ ref, data, options });
        },
        async commit() {
          commits.push(writes);
        },
      };
    },
  };
}

function sqlite(sqlitePath, sql) {
  const result = spawnSync("sqlite3", [sqlitePath, sql], { encoding: "utf8" });
  assert.equal(result.status, 0, result.stderr || result.stdout);
}

async function testBackfillBatchWindowing() {
  const db = makeFakeDb();
  const writes = Array.from({ length: 801 }, (_, index) => ({
    ref: { path: `collection/doc-${index}` },
    data: { index },
  }));

  await commitBackfillBatch(db, writes, true);

  assert.deepEqual(db.commits.map((batch) => batch.length), [400, 400, 1]);
  const committedPaths = db.commits.flat().map((write) => write.ref.path);
  assert.equal(new Set(committedPaths).size, 801);
  assert.equal(committedPaths[400], "collection/doc-400");
}

function testUploadPaginationCursor() {
  const dir = mkdtempSync(path.join(tmpdir(), "openburnbar-upload-test-"));
  const sqlitePath = path.join(dir, "openburnbar.sqlite");
  try {
    sqlite(sqlitePath, `
      CREATE TABLE conversations (
        id TEXT PRIMARY KEY,
        provider TEXT,
        sessionId TEXT,
        projectName TEXT,
        startTime TEXT,
        endTime TEXT,
        messageCount INTEGER,
        userWordCount INTEGER,
        assistantWordCount INTEGER,
        inferredTaskTitle TEXT,
        lastAssistantMessage TEXT,
        fullText TEXT,
        indexedAt TEXT,
        fileModifiedAt TEXT,
        summary TEXT,
        sourceType TEXT,
        summaryTitle TEXT,
        workingDirectory TEXT,
        logSyncedAt TEXT,
        isRemote INTEGER
      );
      INSERT INTO conversations (id, provider, sessionId, startTime, fullText, indexedAt, logSyncedAt, isRemote)
        VALUES
          ('a', 'codex', 's-a', '2026-01-01T00:00:00.000Z', 'first local row', '2026-01-01T00:00:00.000Z', NULL, 0),
          ('b', 'codex', 's-b', '2026-01-01T00:01:00.000Z', 'second local row', '2026-01-01T00:01:00.000Z', NULL, 0),
          ('c', 'codex', 's-c', '2026-01-01T00:02:00.000Z', 'third local row', '2026-01-01T00:02:00.000Z', NULL, 0);
    `);

    const first = readLocalRows(sqlitePath, 1, undefined, false);
    assert.deepEqual(first.map((row) => row.id), ["a"]);

    const second = readLocalRows(sqlitePath, 1, undefined, false, {
      sortKey: first[0].uploadSortKey,
      id: first[0].id,
    });
    assert.deepEqual(second.map((row) => row.id), ["b"]);
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
}

function testUploadPlanIncludesPostings() {
  const db = makeFakeDb();
  const plan = buildUploadPlan({
    db,
    uid: "uid-test",
    deviceId: "macbook",
    vaultKey: Buffer.alloc(32, 7),
    row: {
      id: "local:conversation/1",
      provider: "codex",
      sessionId: "session-1",
      projectName: "BurnBar",
      startTime: "2026-01-01T00:00:00.000Z",
      endTime: "2026-01-01T00:01:00.000Z",
      messageCount: 2,
      userWordCount: 12,
      assistantWordCount: 24,
      inferredTaskTitle: "Search migration test",
      fullText: "DeepSec upload migration should write encrypted cloud search postings for retryable local session search.",
      indexedAt: "2026-01-01T00:01:00.000Z",
      sourceType: "cli_assistant",
      summaryTitle: "Upload migration",
      workingDirectory: "/tmp/openburnbar",
    },
  });

  const writePaths = plan.writes.map((write) => write.ref.path);
  assert.ok(writePaths.some((refPath) => refPath.includes("/cloud_search_documents/")));
  assert.ok(writePaths.some((refPath) => refPath.includes("/cloud_search_chunks/")));
  assert.ok(writePaths.some((refPath) => refPath.includes("/cloud_search_postings/")));
  assert.ok(plan.postings > 0);
  assert.equal(plan.writes.length, writePaths.length);
}

await testBackfillBatchWindowing();
testUploadPaginationCursor();
testUploadPlanIncludesPostings();

console.log("session log migration script regressions ok");
