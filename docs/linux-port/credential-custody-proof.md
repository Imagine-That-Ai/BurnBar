# P-05 Installed Credential Custody Proof

P-05 certifies that the signed Linux candidate can store, read, rotate, remove,
and recover an ephemeral credential through the native custodian for the exact
support-matrix environment. It is the live custody counterpart to the P-34
security proof. P-34 proves fixed-path discovery, redaction, and fail-closed
contracts without creating a credential; P-05 performs the lifecycle against
the real installed backend.

The capture never uses a fixture, development binary, production credential,
or plaintext fallback. A passing result is candidate-bound evidence for one
environment row only. All seven rows require their own signed installed-candidate
receipts before P-05 is complete.

## Backend matrix

| Support environment | Required backend | Live behavior |
|---|---|---|
| Ubuntu 24.04 GNOME, X11 or Wayland, x86_64 or aarch64 | Secret Service through root-owned `secret-tool` | Exercise the active desktop keyring over the session DBus. |
| Fedora KDE Wayland, x86_64 or aarch64 | KWallet through root-owned `kwallet-query` | Exercise the active `kdewallet` wallet, or the wallet named by `OPENBURNBAR_KWALLET_NAME`. |
| Arch Sway Wayland, x86_64 | Encrypted systemd credential through root-owned `systemd-creds` | Encrypt an ephemeral value to an owner-only temporary file, decrypt it, rotate it, and prove the encrypted bytes do not contain the plaintext. |

The producer accepts executables only from `/usr/bin`, `/usr/local/bin`, or
`/bin`. The executable must be a regular, non-symlinked, root-owned file with no
group or other write permission. Ambient `PATH` entries cannot replace the
native backend.

## What the live session proves

`run-p05-credential-custody-session.mjs` creates random, single-use values and
records booleans rather than values or command output. For every backend it
requires:

- the native backend health check succeeds;
- the ephemeral credential is absent before the first write;
- the first write can be read back exactly;
- rotation returns the new value and rejects the old value;
- deletion is observed as missing;
- a new recovery value can be written and read after deletion;
- backend unavailability fails closed; and
- secret material is never placed in process arguments.

For Secret Service and KWallet, secret input is sent only on standard input.
The producer repeats the backend health operation with an invalid session-bus
address and requires failure. This is an automated unavailable-backend check;
it is not a claim that a user's keyring was visibly locked and unlocked. The
operator QA below retains that separate manual check.

For the headless row, `systemd-creds encrypt` receives the value on standard
input and writes only an encrypted credential blob beneath the owner-only
session directory. The producer scans that blob for the plaintext, decrypts it
for exact readback, replaces it during rotation, deletes it, and requires a
subsequent decrypt to fail. No general-purpose plaintext credential file is an
accepted backend.

All cleanup runs in a `finally` path. A failed or interrupted desktop capture
also attempts to delete its ephemeral keyring entry; the headless capture
removes its encrypted temporary blob.

## Preconditions

Run the producer inside the declared graphical or headless environment after
installing the exact signed candidate package. The following installed files
must be root-owned, non-symlinked, and not group/other writable:

```text
/usr/bin/openburnbar-linux-desktop
/usr/bin/openburnbar-daemon
/usr/bin/openburnbar-cli
/usr/share/openburnbar/attestation/installed-manifest.json
```

The manifest SHA-256, package version, architecture, package format, target
commit, candidate workflow run, and immutable artifact digest must all refer to
the same candidate. GNOME and KDE captures also require the real desktop
session's `DBUS_SESSION_BUS_ADDRESS`, `XDG_CURRENT_DESKTOP`, and
`XDG_SESSION_TYPE`. Unlock the test user's keyring or wallet before starting;
never supply a production keyring or credential.

Create the evidence root inside the checkout and make it owner-only. The
capture contract requires the session report directly at this root:

```bash
set -euo pipefail

TARGET_HEAD="$(git rev-parse --verify HEAD)"
ENVIRONMENT_ID=ubuntu-24.04-gnome-wayland-x86_64
CANDIDATE_RUN_ID=123456789
CANDIDATE_ARTIFACT_DIGEST=sha256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef
INPUT_ROOT="$PWD/docs/linux-port/evidence/product-parity-inputs/P-05/$ENVIRONMENT_ID"
SESSION_REPORT="$INPUT_ROOT/p05-installed-custody-session.json"
MANIFEST=/usr/share/openburnbar/attestation/installed-manifest.json

mkdir -p "$INPUT_ROOT"
chmod 700 "$INPUT_ROOT"
rm -f "$SESSION_REPORT"
MANIFEST_SHA256="$(sha256sum "$MANIFEST" | awk '{print $1}')"
PACKAGE_VERSION="$(node -e \
  'const fs=require("node:fs"); console.log(JSON.parse(fs.readFileSync(process.argv[1], "utf8")).packageVersion)' \
  "$MANIFEST")"
```

Replace the example environment, run ID, and artifact digest with values from
the immutable candidate resolver. Stop if the installed manifest does not name
`TARGET_HEAD`, the expected package architecture, or the expected package
format.

## Capture

First produce the live installed-custody session:

```bash
node scripts/linux-port/run-p05-credential-custody-session.mjs \
  --output-root "$INPUT_ROOT" \
  --environment "$ENVIRONMENT_ID" \
  --target-head "$TARGET_HEAD" \
  --candidate-run-id "$CANDIDATE_RUN_ID" \
  --candidate-artifact-digest "$CANDIDATE_ARTIFACT_DIGEST" \
  --package-version "$PACKAGE_VERSION" \
  --manifest-sha256 "$MANIFEST_SHA256"
```

Then convert that immutable observation into registered feature evidence:

```bash
node scripts/linux-port/capture-p05-credential-custody-proof.mjs \
  --input-root "$INPUT_ROOT" \
  --session-report "$SESSION_REPORT" \
  --environment "$ENVIRONMENT_ID" \
  --target-head "$TARGET_HEAD" \
  --candidate-run-id "$CANDIDATE_RUN_ID" \
  --candidate-artifact-digest "$CANDIDATE_ARTIFACT_DIGEST"
```

The capture requires the input root and session report to remain inside the
repository, rejects symlink traversal, requires checkout `HEAD` to equal
`TARGET_HEAD`, revalidates the session, and hashes the candidate source
contracts. Do not edit or hand-author either JSON document.

## Artifacts and trust binding

The live producer writes:

```text
p05-installed-custody-session.json
```

The capture writes:

```text
feature-artifacts/credential-custody-installed.json
feature-proof-registration.json
```

The registered role is `feature.credential-custody-installed`. The proof binds
the observed session bytes and these candidate source files by SHA-256:

- `OpenBurnBarCore/Sources/OpenBurnBarLinuxSecurity/LinuxNativeSecretStore.swift`
- `OpenBurnBarCore/Sources/OpenBurnBarLinuxSecurity/OpenBurnBarLinuxSecurity.swift`
- `OpenBurnBarDaemon/Sources/OpenBurnBarDaemon/OpenBurnBarConfigStore.swift`
- `scripts/linux-port/run-p05-credential-custody-session.mjs`

Feature-closure finalization snapshots the registered artifact. Requirement
materialization and the P-05 validator reopen the exact bytes and independently
check candidate, environment, package, backend, lifecycle, redaction, and source
bindings. Collection alone is not a passed parity receipt.

## Redaction and failure rules

Evidence contains backend identity, package metadata, environment metadata,
source hashes, and pass/fail booleans only. It must never contain a password,
token, bearer value, plaintext credential, raw credential bytes, or native
command stdout/stderr. The schema marks stdout, stderr, and diagnostics as
redacted, requires zero secret occurrences, and rejects credential-shaped
strings or secret-bearing field names.

Treat any of the following as a failed row:

- a required native command is missing or fails the trusted-file check;
- the desktop/session/OS/architecture does not match the environment ID;
- the installed manifest or package identity differs from the selected release;
- a keyring operation falls back to a file, environment value, or another backend;
- readback, rotation, old-value rejection, cleanup, recovery, or unavailable
  behavior is not observed;
- the systemd encrypted blob contains the plaintext;
- a secret appears in arguments, output, diagnostics, or the evidence JSON; or
- the report, feature artifact, registration, source hash, or candidate binding
  is missing or changed.

Do not relabel a failed desktop row as headless. Do not use P-34 fixture or
metadata proof as P-05 evidence.

## QA verification

For each of the seven support environments:

1. Confirm the release workflow succeeded for `TARGET_HEAD` and resolve the
   immutable candidate run and artifact digest.
2. Install the matching package and verify package-manager ownership plus the
   installed manifest's commit, architecture, format, version, and SHA-256.
3. Confirm the expected desktop, session type, session bus, and native backend.
4. Run the live producer and capture commands above. Review only metadata and
   booleans; do not print native command output while debugging.
5. Confirm the registration contains exactly
   `feature.credential-custody-installed` and points to
   `feature-artifacts/credential-custody-installed.json`.
6. Run the focused contract and certification gates:

   ```bash
   node --test scripts/linux-port/p05-credential-custody-proof.test.mjs
   node --test scripts/linux-port/parity-certification-preflight.test.mjs
   node --test scripts/linux-port/product-feature-proof-closure.test.mjs \
     scripts/linux-port/run-product-requirement-validator.test.mjs
   bash scripts/ci/check-no-suppressions.sh
   ```

7. Repeat with the desktop keyring or wallet locked. Read and write must fail
   with no plaintext fallback. Unlock it and verify retry succeeds without a
   daemon restart; retain only redacted operator observations.
8. Use a separate disposable canary credential through the installed product
   to inspect the app journal, daemon log, process arguments, process
   environment, renderer state, crash/support bundle, evidence tree, and
   temporary directory. The canary count must be zero after cleanup. The live
   producer's random values stay private and must not be printed for this check.
9. Mutate one proof claim at a time, including backend ID, package digest,
   rotation, old-value rejection, recovery, unavailable behavior, redaction,
   and a source hash. Each mutation must make validation fail.
10. Delete `p05-installed-custody-session.json` after the registered evidence
    has been finalized and no investigation requires the source report. Keep
    the input root owner-only while it contains live-session material.

P-05 is ready for promotion only when every support-matrix row has a current,
passed validator receipt for the same immutable candidate and the manual
locked/unlocked plus redaction checks have no unresolved finding.
