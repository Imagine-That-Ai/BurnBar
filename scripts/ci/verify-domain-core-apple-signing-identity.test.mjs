import assert from "node:assert/strict";
import { createHash } from "node:crypto";
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
const CERTIFICATE = Buffer.from("authorized Developer ID leaf certificate");
const CERTIFICATE_SHA1 = createHash("sha1")
  .update(CERTIFICATE)
  .digest("hex")
  .toUpperCase();
const POLICY = JSON.stringify({
  schemaVersion: 2,
  teamIdentifier: TEAM,
  authority: AUTHORITY,
  certificateSha1: CERTIFICATE_SHA1,
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
  assert.deepEqual(
    verifyAppleCodeSigningIdentity(POLICY, CODESIGN_OUTPUT, CERTIFICATE),
    {
      authority: AUTHORITY,
      certificateSha1: CERTIFICATE_SHA1,
      teamIdentifier: TEAM,
    },
  );
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
    schemaVersion: 2,
    teamIdentifier: "4Y367DF25B",
    authority:
      "Developer ID Application: Imagine That AI Limited Liability Company (4Y367DF25B)",
    certificateSha1: "2FAA2102B33D02ED5F1A3D34EF51B210A4398ECA",
  });
});

test("release signing secrets must exactly match committed pins", () => {
  assert.deepEqual(
    verifyAppleSigningEnvironment(POLICY, {
      APPLE_TEAM_ID: TEAM,
      APPLE_SIGNING_IDENTITY: AUTHORITY,
      APPLE_SIGNING_CERTIFICATE_SHA1: CERTIFICATE_SHA1,
    }),
    parseAppleSigningPolicy(POLICY),
  );
  assert.throws(
    () =>
      verifyAppleSigningEnvironment(POLICY, {
        APPLE_TEAM_ID: "Z9Y8X7W6V5",
        APPLE_SIGNING_IDENTITY: AUTHORITY,
        APPLE_SIGNING_CERTIFICATE_SHA1: CERTIFICATE_SHA1,
      }),
    /APPLE_TEAM_ID/,
  );
  assert.throws(
    () =>
      verifyAppleSigningEnvironment(POLICY, {
        APPLE_TEAM_ID: TEAM,
        APPLE_SIGNING_IDENTITY: `Developer ID Application: Attacker LLC (${TEAM})`,
        APPLE_SIGNING_CERTIFICATE_SHA1: CERTIFICATE_SHA1,
      }),
    /APPLE_SIGNING_IDENTITY/,
  );
  assert.throws(
    () =>
      verifyAppleSigningEnvironment(POLICY, {
        APPLE_TEAM_ID: TEAM,
        APPLE_SIGNING_IDENTITY: AUTHORITY,
        APPLE_SIGNING_CERTIFICATE_SHA1: "0".repeat(40),
      }),
    /APPLE_SIGNING_CERTIFICATE_SHA1/,
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
        CERTIFICATE,
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
        CERTIFICATE,
      ),
    /leaf Authority mismatch/,
  );
  assert.throws(
    () =>
      verifyAppleCodeSigningIdentity(
        POLICY,
        CODESIGN_OUTPUT,
        Buffer.from("substituted certificate"),
      ),
    /leaf certificate SHA-1 mismatch/,
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
  assert.deepEqual(
    verifyAppleCodeSigningIdentity(POLICY, dmgSignature, CERTIFICATE),
    {
      authority: AUTHORITY,
      certificateSha1: CERTIFICATE_SHA1,
      teamIdentifier: TEAM,
    },
  );
  assert.throws(
    () =>
      verifyAppleCodeSigningIdentity(
        POLICY,
        dmgSignature.replace(
          `Authority=${AUTHORITY}`,
          `Authority=Developer ID Application: Substituted LLC (${TEAM})`,
        ),
        CERTIFICATE,
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
          schemaVersion: 1,
          teamIdentifier: TEAM,
          authority: AUTHORITY,
          certificateSha1: CERTIFICATE_SHA1,
        }),
      ),
    /schemaVersion must be 2/,
  );
  assert.throws(
    () =>
      parseAppleSigningPolicy(
        JSON.stringify({
          schemaVersion: 2,
          teamIdentifier: TEAM,
          authority: AUTHORITY,
          certificateSha1: CERTIFICATE_SHA1,
          fallbackAuthority: AUTHORITY,
        }),
      ),
    /must contain exactly/,
  );
  assert.throws(
    () =>
      parseAppleSigningPolicy(
        `{"schemaVersion":2,"teamIdentifier":"${TEAM}","teamIdentifier":"${TEAM}","authority":${JSON.stringify(AUTHORITY)},"certificateSha1":"${CERTIFICATE_SHA1}"}`,
      ),
    /each protected field exactly once/,
  );
  assert.throws(
    () =>
      parseAppleSigningPolicy(
        JSON.stringify({
          schemaVersion: 2,
          teamIdentifier: TEAM,
          authority: "Apple Development: Imagine That LLC (A1B2C3D4E5)",
          certificateSha1: CERTIFICATE_SHA1,
        }),
      ),
    /Developer ID Application identity/,
  );
  assert.throws(
    () =>
      parseAppleSigningPolicy(
        JSON.stringify({
          schemaVersion: 2,
          teamIdentifier: TEAM,
          authority: "Developer ID Application: Imagine That LLC (Z9Y8X7W6V5)",
          certificateSha1: CERTIFICATE_SHA1,
        }),
      ),
    /exact teamIdentifier/,
  );
  assert.throws(
    () =>
      parseAppleSigningPolicy(
        JSON.stringify({
          schemaVersion: 2,
          teamIdentifier: TEAM,
          authority: AUTHORITY,
          certificateSha1: "a".repeat(40),
        }),
      ),
    /40 uppercase hexadecimal/,
  );
});

test("rejects missing, malformed, and duplicate codesign identity lines", () => {
  assert.throws(
    () =>
      verifyAppleCodeSigningIdentity(
        POLICY,
        CODESIGN_OUTPUT.replace(`TeamIdentifier=${TEAM}`, ""),
        CERTIFICATE,
      ),
    /missing TeamIdentifier/,
  );
  assert.throws(
    () =>
      verifyAppleCodeSigningIdentity(
        POLICY,
        `${CODESIGN_OUTPUT}\nTeamIdentifier=${TEAM}`,
        CERTIFICATE,
      ),
    /duplicate TeamIdentifier/,
  );
  assert.throws(
    () =>
      verifyAppleCodeSigningIdentity(
        POLICY,
        `${CODESIGN_OUTPUT}\nAuthority=${AUTHORITY}`,
        CERTIFICATE,
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
        CERTIFICATE,
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
    const certificate = join(workspace, "codesign0");
    const certificateLink = join(workspace, "codesign0-link");
    writeFileSync(policy, POLICY);
    writeFileSync(output, CODESIGN_OUTPUT);
    writeFileSync(certificate, CERTIFICATE);
    symlinkSync(policy, policyLink);
    symlinkSync(output, outputLink);
    symlinkSync(certificate, certificateLink);

    assert.throws(
      () =>
        run([
          "--policy",
          policyLink,
          "--signature",
          output,
          "--certificate",
          certificate,
        ]),
      /nonempty regular file, not a symlink/,
    );
    assert.throws(
      () =>
        run([
          "--policy",
          policy,
          "--signature",
          outputLink,
          "--certificate",
          certificate,
        ]),
      /nonempty regular file, not a symlink/,
    );
    assert.throws(
      () =>
        run([
          "--policy",
          policy,
          "--signature",
          output,
          "--certificate",
          certificateLink,
        ]),
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
        APPLE_SIGNING_CERTIFICATE_SHA1: CERTIFICATE_SHA1,
      }),
    /APPLE_SIGNING_IDENTITY/,
  );
});
