import assert from "node:assert/strict";
import {
  mkdirSync,
  mkdtempSync,
  readFileSync,
  rmSync,
  symlinkSync,
  writeFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import test from "node:test";

import { stage } from "./stage-domain-core-attestation-artifact.mjs";

function fixture(context) {
  const root = mkdtempSync(join(tmpdir(), "domain-core-attestation-stage-"));
  context.after(() => rmSync(root, { recursive: true, force: true }));
  const artifactPath = join(root, "artifact.bin");
  const identityReportPath = join(root, "observed.json");
  const outputPath = join(root, "staged");
  writeFileSync(artifactPath, "artifact bytes\n");
  writeFileSync(identityReportPath, '{"sourceSha256":"observed"}\n');
  return { root, artifactPath, identityReportPath, outputPath };
}

test("stage freezes the observed artifact and identity report as exact bytes", (context) => {
  const paths = fixture(context);
  stage(paths);
  assert.equal(
    readFileSync(join(paths.outputPath, "artifact"), "utf8"),
    "artifact bytes\n",
  );
  assert.equal(
    readFileSync(join(paths.outputPath, "observed-identity.json"), "utf8"),
    '{"sourceSha256":"observed"}\n',
  );
});

test("stage rejects symlinked artifacts and identity reports", (context) => {
  const paths = fixture(context);
  const artifactLink = join(paths.root, "artifact-link");
  const reportLink = join(paths.root, "report-link");
  symlinkSync(paths.artifactPath, artifactLink);
  symlinkSync(paths.identityReportPath, reportLink);
  assert.throws(
    () => stage({ ...paths, artifactPath: artifactLink }),
    /not a symlink/u,
  );
  assert.throws(
    () => stage({ ...paths, identityReportPath: reportLink }),
    /non-empty file/u,
  );

  mkdirSync(join(paths.root, "empty"));
  assert.throws(
    () => stage({ ...paths, identityReportPath: join(paths.root, "empty") }),
    /non-empty file/u,
  );
});
