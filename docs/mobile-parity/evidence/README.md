# Mobile parity evidence bundle

This directory is the candidate-bound evidence bundle for release and store
certification.

**The bundle is empty and blocked** until all of the following exist:

1. A **clean** git candidate (`git status --short` is empty).
2. A fingerprint written by `node scripts/mobile-parity/record-candidate-fingerprint.mjs`
   with `closable: true`.
3. Named iPhone, iPad, and Android devices with the **installed** candidate
   artifact digest recorded.
4. Authorized App Store Connect / TestFlight and Google Play closed-test
   readback of that same artifact.

Do **not** add placeholder PASS files, screenshots without `candidateSha`,
empty logs, or “lorem ipsum” receipts. Those fail
`scripts/mobile-parity/check-release-evidence.mjs` and cannot close
VAL-MOB-001 / VAL-MOB-013 / VAL-MOB-014 / VAL-MOB-015.

M8 only scaffolds the schema. It does not submit to TestFlight or Play and
does not create signing identities.
