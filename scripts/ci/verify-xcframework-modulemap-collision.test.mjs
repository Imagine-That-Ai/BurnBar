import assert from "node:assert/strict";
import { mkdtempSync, mkdirSync, writeFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import test from "node:test";

import {
  auditXcframeworkScripts,
  usesBareHeaderLayout,
} from "./verify-xcframework-modulemap-collision.mjs";

const BARE = `#!/usr/bin/env bash
  cp "\${GENERATED_DIR}/"*.modulemap "\${out_dir}/Headers/module.modulemap"
  build_xcframework_args+=(-library "\${out_dir}/lib.a" -headers "\${out_dir}/Headers")
`;

const FRAMEWORK = `#!/usr/bin/env bash
  cat > "\${framework_dir}/Modules/module.modulemap" <<EOF
framework module thing { umbrella header "thing.h" export * }
EOF
  build_xcframework_args+=(-framework "\${framework_dir}")
`;

function fixtureRoot(scripts) {
  const root = mkdtempSync(join(tmpdir(), "xcframework-collision-"));
  mkdirSync(join(root, "scripts"), { recursive: true });
  for (const [name, body] of Object.entries(scripts)) {
    writeFileSync(join(root, "scripts", name), body);
  }
  return root;
}

test("the bare static-library layout is what collides", () => {
  assert.equal(usesBareHeaderLayout(BARE), true);
  assert.equal(usesBareHeaderLayout(FRAMEWORK), false);
});

test("one bare-layout script is allowed; a second is the collision", () => {
  const one = fixtureRoot({
    "build-a-xcframework.sh": BARE,
    "build-b-xcframework.sh": FRAMEWORK,
  });
  const two = fixtureRoot({
    "build-a-xcframework.sh": BARE,
    "build-b-xcframework.sh": BARE,
  });
  try {
    assert.deepEqual(auditXcframeworkScripts(one), ["build-a-xcframework.sh"]);
    assert.deepEqual(auditXcframeworkScripts(two), [
      "build-a-xcframework.sh",
      "build-b-xcframework.sh",
    ]);
  } finally {
    rmSync(one, { recursive: true, force: true });
    rmSync(two, { recursive: true, force: true });
  }
});

test("only build-*-xcframework.sh scripts are considered", () => {
  const root = fixtureRoot({
    "build-a-xcframework.sh": BARE,
    "unrelated.sh": BARE,
  });
  try {
    assert.deepEqual(auditXcframeworkScripts(root), ["build-a-xcframework.sh"]);
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
});

test("the repository is within the limit", () => {
  // Guards the fix: converting domain-core to a .framework left exactly one
  // bare-layout script (iroh), which is safe on its own.
  assert.ok(
    auditXcframeworkScripts().length <= 1,
    `expected at most one bare-layout xcframework script, found: ${auditXcframeworkScripts().join(", ")}`,
  );
});

test("domain-core packages a framework, not a bare header directory", () => {
  const source = auditXcframeworkScripts();
  assert.equal(
    source.includes("build-domain-core-xcframework.sh"),
    false,
    "domain-core must stay on the .framework layout or the iOS archive breaks again",
  );
});
