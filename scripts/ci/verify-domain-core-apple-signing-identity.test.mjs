import assert from "node:assert/strict";
import {
  mkdtempSync,
  readFileSync,
  rmSync,
  symlinkSync,
  writeFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import test from "node:test";

import {
  parseAppleSigningPolicy,
  run,
  verifyAppleCodeSigningIdentity,
  verifyAppleSigningEnvironment,
} from "./verify-domain-core-apple-signing-identity.mjs";

const TEAM = "A1B2C3D4E5";
const AUTHORITY = `Developer ID Application: Imagine That LLC (${TEAM})`;
const POLICY = JSON.stringify({
  schemaVersion: 1,
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

test("committed policy pins the production TeamIdentifier and leaf Authority", () => {
  const policy = parseAppleSigningPolicy(
    readFileSync(
      new URL(
        "../../config/apple-release-signing-policy.json",
        import.meta.url,
      ),
      "utf8",
    ),
  );
  assert.deepEqual(policy, {
    schemaVersion: 1,
    teamIdentifier: "4Y367DF25B",
    authority:
      "Developer ID Application: Imagine That AI Limited Liability Company (4Y367DF25B)",
  });
});

test("release signing secrets must exactly match committed pins", () => {
  assert.deepEqual(
    verifyAppleSigningEnvironment(POLICY, {
      APPLE_TEAM_ID: TEAM,
      APPLE_SIGNING_IDENTITY: AUTHORITY,
    }),
    parseAppleSigningPolicy(POLICY),
  );
  assert.throws(
    () =>
      verifyAppleSigningEnvironment(POLICY, {
        APPLE_TEAM_ID: "Z9Y8X7W6V5",
        APPLE_SIGNING_IDENTITY: AUTHORITY,
      }),
    /APPLE_TEAM_ID/,
  );
  assert.throws(
    () =>
      verifyAppleSigningEnvironment(POLICY, {
        APPLE_TEAM_ID: TEAM,
        APPLE_SIGNING_IDENTITY: `Developer ID Application: Attacker LLC (${TEAM})`,
      }),
    /APPLE_SIGNING_IDENTITY/,
  );
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

test("rejects a substituted outer DMG signer", () => {
  const dmgSignature = [
    "Executable=/tmp/OpenBurnBar-1.2.3-macOS.dmg",
    "Identifier=OpenBurnBar-1.2.3-macOS",
    `Authority=${AUTHORITY}`,
    "Authority=Developer ID Certification Authority",
    "Authority=Apple Root CA",
    `TeamIdentifier=${TEAM}`,
  ].join("\n");
  assert.deepEqual(verifyAppleCodeSigningIdentity(POLICY, dmgSignature), {
    authority: AUTHORITY,
    teamIdentifier: TEAM,
  });
  assert.throws(
    () =>
      verifyAppleCodeSigningIdentity(
        POLICY,
        dmgSignature.replace(
          `Authority=${AUTHORITY}`,
          `Authority=Developer ID Application: Substituted LLC (${TEAM})`,
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
          schemaVersion: 2,
          teamIdentifier: TEAM,
          authority: AUTHORITY,
        }),
      ),
    /schemaVersion must be 1/,
  );
  assert.throws(
    () =>
      parseAppleSigningPolicy(
        JSON.stringify({
          schemaVersion: 1,
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
        `{"schemaVersion":1,"teamIdentifier":"${TEAM}","teamIdentifier":"${TEAM}","authority":${JSON.stringify(AUTHORITY)}}`,
      ),
    /each protected field exactly once/,
  );
  assert.throws(
    () =>
      parseAppleSigningPolicy(
        JSON.stringify({
          schemaVersion: 1,
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
          schemaVersion: 1,
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

test("release signing environment rejects missing protected values", () => {
  assert.throws(
    () => verifyAppleSigningEnvironment(POLICY, {}),
    /APPLE_TEAM_ID/,
  );
  assert.throws(
    () =>
      verifyAppleSigningEnvironment(POLICY, {
        APPLE_TEAM_ID: TEAM,
      }),
    /APPLE_SIGNING_IDENTITY/,
  );
});
