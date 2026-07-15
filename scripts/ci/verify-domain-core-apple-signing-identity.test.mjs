import assert from "node:assert/strict";
import { mkdtempSync, rmSync, symlinkSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import test from "node:test";

import {
  parseAppleSigningPolicy,
  run,
  verifyAppleCodeSigningIdentity,
} from "./verify-domain-core-apple-signing-identity.mjs";

const TEAM = "A1B2C3D4E5";
const AUTHORITY = `Developer ID Application: Imagine That LLC (${TEAM})`;
const POLICY = JSON.stringify({
  teamIdentifier: TEAM,
  authority: AUTHORITY,
});
const CODESIGN_OUTPUT = [
  "Executable=/Volumes/OpenBurnBar/OpenBurnBar.app/Contents/MacOS/OpenBurnBar",
  "Identifier=com.openburnbar.app",
  `Authority=${AUTHORITY}`,
  "Authority=Developer ID Certification Authority",
  "Authority=Apple Root CA",
  `TeamIdentifier=${TEAM}`,
  "Runtime Version=26.0.0",
].join("\n");

test("accepts the exact protected TeamIdentifier and leaf Authority", () => {
  assert.deepEqual(verifyAppleCodeSigningIdentity(POLICY, CODESIGN_OUTPUT), {
    authority: AUTHORITY,
    teamIdentifier: TEAM,
  });
});

test("rejects substituted TeamIdentifier and leaf Authority values", () => {
  assert.throws(
    () =>
      verifyAppleCodeSigningIdentity(
        POLICY,
        CODESIGN_OUTPUT.replace(
          `TeamIdentifier=${TEAM}`,
          "TeamIdentifier=Z9Y8X7W6V5",
        ),
      ),
    /TeamIdentifier mismatch/,
  );
  assert.throws(
    () =>
      verifyAppleCodeSigningIdentity(
        POLICY,
        CODESIGN_OUTPUT.replace(
          `Authority=${AUTHORITY}`,
          `Authority=Developer ID Application: Attacker LLC (${TEAM})`,
        ),
      ),
    /leaf Authority mismatch/,
  );
});

test("rejects malformed, extra, and duplicate protected policy fields", () => {
  assert.throws(() => parseAppleSigningPolicy("{"), /not valid JSON/);
  assert.throws(
    () =>
      parseAppleSigningPolicy(
        JSON.stringify({
          teamIdentifier: TEAM,
          authority: AUTHORITY,
          fallbackAuthority: AUTHORITY,
        }),
      ),
    /must contain exactly/,
  );
  assert.throws(
    () =>
      parseAppleSigningPolicy(
        `{"teamIdentifier":"${TEAM}","teamIdentifier":"${TEAM}","authority":${JSON.stringify(AUTHORITY)}}`,
      ),
    /each protected field exactly once/,
  );
  assert.throws(
    () =>
      parseAppleSigningPolicy(
        JSON.stringify({
          teamIdentifier: TEAM,
          authority: "Apple Development: Imagine That LLC (A1B2C3D4E5)",
        }),
      ),
    /Developer ID Application identity/,
  );
  assert.throws(
    () =>
      parseAppleSigningPolicy(
        JSON.stringify({
          teamIdentifier: TEAM,
          authority: "Developer ID Application: Imagine That LLC (Z9Y8X7W6V5)",
        }),
      ),
    /exact teamIdentifier/,
  );
});

test("rejects missing, malformed, and duplicate codesign identity lines", () => {
  assert.throws(
    () =>
      verifyAppleCodeSigningIdentity(
        POLICY,
        CODESIGN_OUTPUT.replace(`TeamIdentifier=${TEAM}`, ""),
      ),
    /missing TeamIdentifier/,
  );
  assert.throws(
    () =>
      verifyAppleCodeSigningIdentity(
        POLICY,
        `${CODESIGN_OUTPUT}\nTeamIdentifier=${TEAM}`,
      ),
    /duplicate TeamIdentifier/,
  );
  assert.throws(
    () =>
      verifyAppleCodeSigningIdentity(
        POLICY,
        `${CODESIGN_OUTPUT}\nAuthority=${AUTHORITY}`,
      ),
    /duplicate Authority/,
  );
  assert.throws(
    () =>
      verifyAppleCodeSigningIdentity(
        POLICY,
        CODESIGN_OUTPUT.replace(
          `TeamIdentifier=${TEAM}`,
          `TeamIdentifier =${TEAM}`,
        ),
      ),
    /TeamIdentifier is malformed/,
  );
});

test("CLI rejects symlinked protected policy and codesign evidence", () => {
  const workspace = mkdtempSync(join(tmpdir(), "apple-signing-test-"));
  try {
    const policy = join(workspace, "policy.json");
    const policyLink = join(workspace, "policy-link.json");
    const output = join(workspace, "codesign.txt");
    const outputLink = join(workspace, "codesign-link.txt");
    writeFileSync(policy, POLICY);
    writeFileSync(output, CODESIGN_OUTPUT);
    symlinkSync(policy, policyLink);
    symlinkSync(output, outputLink);

    assert.throws(
      () => run(["--policy", policyLink, "--signature", output]),
      /nonempty regular file, not a symlink/,
    );
    assert.throws(
      () => run(["--policy", policy, "--signature", outputLink]),
      /nonempty regular file, not a symlink/,
    );
  } finally {
    rmSync(workspace, { recursive: true, force: true });
  }
});
