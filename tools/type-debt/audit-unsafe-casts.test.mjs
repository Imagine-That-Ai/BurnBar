import assert from "node:assert/strict";
import fs from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import test from "node:test";
import { auditUnsafeCasts } from "./audit-unsafe-casts.mjs";

test("TypeScript scanner ignores const assertions, import aliases, comments, strings, and satisfies", async () => {
  const repo = await fixtureRepo({
    "src/example.ts": `
      import { thing as renamedThing } from "./thing";

      type User = { id: string };
      declare const payload: unknown;
      const literal = { ok: true } as const;
      const typed = payload as User;
      const loose = payload as any;
      const id = (typed!).id;
      const checked = payload satisfies User;
      // const ignored = payload as User;
      const text = "payload as User";
    `,
  });

  const report = await auditUnsafeCasts({ repoRoot: repo });

  assert.equal(report.byKind.ts_type_assertion, 1);
  assert.equal(report.byKind.ts_as_any, 1);
  assert.equal(report.byKind.ts_non_null_assertion, 1);
  assert.equal(report.total, 3);
});

test("Swift scanner counts force casts and force tries outside comments and strings", async () => {
  const repo = await fixtureRepo({
    "App/Example.swift": `
      let cast = value as! Widget
      let result = try! makeWidget()
      // let ignored = value as! Widget
      let text = "try! ignored and as! ignored"
    `,
  });

  const report = await auditUnsafeCasts({ repoRoot: repo });

  assert.equal(report.byKind.swift_force_cast, 1);
  assert.equal(report.byKind.swift_force_try, 1);
  assert.equal(report.total, 2);
});

test("Kotlin scanner skips import aliases and safe casts while counting unsafe casts and force unwraps", async () => {
  const repo = await fixtureRepo({
    "android/app/src/main/java/Example.kt": `
      import com.example.Original as Alias

      val unsafe = value as Widget
      val safe = value as? Widget
      val forced = maybeWidget!!
      // val ignored = value as Widget
      val text = "maybeWidget!! and value as Widget"
    `,
  });

  const report = await auditUnsafeCasts({ repoRoot: repo });

  assert.equal(report.byKind.kotlin_unsafe_cast, 1);
  assert.equal(report.byKind.kotlin_force_unwrap, 1);
  assert.equal(report.total, 2);
});

test("scanner excludes generated and vendor paths from the budget", async () => {
  const repo = await fixtureRepo({
    "Generated/Generated.swift": "let cast = value as! Widget\n",
    "Vendor/ThirdParty.swift": "let cast = value as! Widget\n",
    "node_modules/pkg/index.ts": "const typed = value as Thing\n",
    "src/HandWritten.swift": "let cast = value as! Widget\n",
  });

  const report = await auditUnsafeCasts({ repoRoot: repo });

  assert.equal(report.total, 1);
  assert.equal(report.violations[0].path, "src/HandWritten.swift");
});

async function fixtureRepo(files) {
  const repo = await fs.mkdtemp(path.join(os.tmpdir(), "unsafe-cast-fixture-"));

  await Promise.all(
    Object.entries(files).map(async ([relativePath, contents]) => {
      const fullPath = path.join(repo, relativePath);
      await fs.mkdir(path.dirname(fullPath), { recursive: true });
      await fs.writeFile(fullPath, contents.trimStart(), "utf8");
    }),
  );

  return repo;
}
