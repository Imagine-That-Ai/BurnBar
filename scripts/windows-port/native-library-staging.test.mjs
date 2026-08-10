import assert from "node:assert/strict";
import {
  mkdtempSync,
  mkdirSync,
  readFileSync,
  rmSync,
  symlinkSync,
  writeFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import test from "node:test";

import { stageNativeLibrary } from "./native-library-staging.mjs";

const workspace = mkdtempSync(join(tmpdir(), "native-library-staging-test-"));
test.after(() => rmSync(workspace, { recursive: true, force: true }));

test("stages exact native bytes into the requested location", () => {
  const source = join(workspace, "source-library");
  const destination = join(workspace, "nested", "destination-library");
  writeFileSync(source, "candidate-bound-native-bytes");

  const result = stageNativeLibrary(source, destination);

  assert.equal(result.staged, true);
  assert.equal(readFileSync(destination, "utf8"), "candidate-bound-native-bytes");
  assert.match(result.sha256, /^[0-9a-f]{64}$/u);
});

test("replaces an older staged library atomically", () => {
  const source = join(workspace, "new-source-library");
  const destination = join(workspace, "replace-destination-library");
  writeFileSync(source, "new-candidate-native-bytes");
  writeFileSync(destination, "old-native-bytes");

  stageNativeLibrary(source, destination);

  assert.equal(readFileSync(destination, "utf8"), "new-candidate-native-bytes");
});

test("returns a no-op result when source and destination are identical", () => {
  const source = join(workspace, "already-staged-library");
  writeFileSync(source, "already-staged-native-bytes");

  const result = stageNativeLibrary(source, source);

  assert.equal(result.staged, false);
  assert.equal(result.source, result.destination);
});

test("rejects missing and directory sources", () => {
  const directorySource = join(workspace, "directory-library");
  mkdirSync(directorySource);
  const destination = join(workspace, "rejected-destination");

  assert.throws(
    () => stageNativeLibrary(join(workspace, "missing-library"), destination),
    /ENOENT|nonempty regular file/,
  );
  assert.throws(
    () => stageNativeLibrary(directorySource, destination),
    /nonempty regular file/,
  );
});

test("rejects symlink sources when the host permits symlink creation", (t) => {
  const realSource = join(workspace, "real-library");
  writeFileSync(realSource, "real-native-bytes");
  const symlinkSource = join(workspace, "symlink-library");
  try {
    symlinkSync(realSource, symlinkSource);
  } catch (error) {
    if (error && typeof error === "object" && error.code === "EPERM") {
      t.skip("host does not permit unprivileged symlink creation");
      return;
    }
    throw error;
  }

  assert.throws(
    () =>
      stageNativeLibrary(
        symlinkSource,
        join(workspace, "symlink-destination"),
      ),
    /not a symlink/,
  );
});
