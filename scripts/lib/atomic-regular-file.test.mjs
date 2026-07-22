import assert from "node:assert/strict";
import {
  mkdtempSync,
  mkdirSync,
  rmSync,
  symlinkSync,
  writeFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import test from "node:test";

import {
  readRegularFileIfExistsSync,
  readRegularFileSync,
} from "./atomic-regular-file.mjs";

function fixture(context) {
  const root = mkdtempSync(join(tmpdir(), "atomic-regular-file-"));
  context.after(() => rmSync(root, { recursive: true, force: true }));
  return root;
}

test("reads text and bytes from the validated regular-file descriptor", (context) => {
  const root = fixture(context);
  const path = join(root, "receipt.json");
  writeFileSync(path, "trusted\n");

  assert.equal(
    readRegularFileSync(path, { encoding: "utf8", label: "receipt" }),
    "trusted\n",
  );
  assert.deepEqual(
    readRegularFileSync(path, { label: "receipt" }),
    Buffer.from("trusted\n"),
  );
});

test("rejects symbolic links and directories", (context) => {
  const root = fixture(context);
  const target = join(root, "target.txt");
  const link = join(root, "link.txt");
  const directory = join(root, "directory");
  writeFileSync(target, "secret\n");
  symlinkSync(target, link);
  mkdirSync(directory);

  assert.throws(
    () => readRegularFileSync(link, { label: "receipt" }),
    /receipt must be a regular file/u,
  );
  assert.throws(
    () => readRegularFileSync(directory, { label: "receipt" }),
    /receipt must be a regular file/u,
  );
});

test("distinguishes a missing path from an unsafe existing path", (context) => {
  const root = fixture(context);
  assert.equal(
    readRegularFileIfExistsSync(join(root, "missing"), { label: "receipt" }),
    undefined,
  );

  const target = join(root, "target.txt");
  const link = join(root, "link.txt");
  writeFileSync(target, "secret\n");
  symlinkSync(target, link);
  assert.throws(
    () => readRegularFileIfExistsSync(link, { label: "receipt" }),
    /receipt must be a regular file/u,
  );
});
