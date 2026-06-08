# AGPL Release Review Packet

This packet is for counsel review before any public release that links or ships
Signal/libsignal/SPQR-backed E2EE in the BurnBar product.

## Scope

The Nous/Hermes upstream contribution path remains a MIT-compatible encrypted
gateway hardening only lane. This packet covers the BurnBar product lane.

The upstream PR lane is MIT-compatible encrypted gateway hardening only; it is
not the Signal/libsignal product release lane.

## Required Review Scope

Counsel must review:

- AGPL-3.0-only product license posture
- official libsignal/SPQR dependency posture
- corresponding source availability
- app store and commercial distribution terms
- marketing and trust-copy claim boundaries

## Required Distribution Channels

Required Distribution Channels include Mac App Store, iOS App Store, direct
download, browser extension marketplaces, npm, Docker, and hosted services.

## Required Artifacts For Counsel

- `docs/legal/SOURCE_AVAILABILITY.md`
- `docs/legal/HERMES_GATEWAY_SIGNAL_REQUIRED_ROLLOUT.md`
- `docs/legal/agpl-release-review.evidence.template.json`
- `third_party/libsignal/runtime-readiness.json`
- `launch-evidence/latest-agpl-store-legal-packet.json`

The reviewer role is `external_counsel`.

Approved release evidence must be a signed packet, not a self-reported JSON
field. `scripts/ci/check_agpl_legal_release_review.py` requires:

- `reviewStatus: "approved"`
- `reviewerRole: "external_counsel"`
- an `approval` object with reviewer name, approval timestamp, reviewed
  document path, reviewed document SHA-256, detached signature path, public key
  path, and `signatureFormat: "openssl-sha256-rsa"`
- an OpenSSL SHA-256/RSA verification that succeeds against the reviewed
  document bytes

Pending evidence may pass CI only with `--allow-pending` and must explicitly
state that it is not legal approval.

## Attaching Counsel Approval

After external counsel approves a concrete reviewed document, store counsel's
public verification key and detached signature under `launch-evidence/`, then
materialize the approved evidence packet with the verifier-backed attach tool:

```bash
python3 scripts/ci/attach_agpl_legal_release_approval.py \
  --reviewer-name "External Counsel Name or Firm" \
  --approved-at "2026-06-08T15:00:00Z" \
  --signature launch-evidence/agpl-release-review.sig \
  --public-key launch-evidence/counsel-public.pem \
  --use-required-channels \
  --check

python3 scripts/ci/attach_agpl_legal_release_approval.py \
  --reviewer-name "External Counsel Name or Firm" \
  --approved-at "2026-06-08T15:00:00Z" \
  --signature launch-evidence/agpl-release-review.sig \
  --public-key launch-evidence/counsel-public.pem \
  --use-required-channels

python3 scripts/ci/attach_libsignal_runtime_evidence.py \
  --gate store_and_counsel_approval \
  --artifact launch-evidence/latest-agpl-store-legal-packet.json
```

The attach tool refuses absolute or out-of-repo paths, recomputes the reviewed
document hash, verifies the detached OpenSSL SHA-256/RSA signature, and writes
only a packet that `check_agpl_legal_release_review.py` already accepts. Do not
hand-edit `reviewStatus: "approved"`.

Run the aggregate product release gate before any Signal-enabled release:

```bash
python scripts/ci/check_burnbar_release_preflight.py
```

That command validates source provenance, runtime readiness, and this signed
legal packet together. It intentionally returns `HOLD` while the legal packet is
pending or missing.

Do not market a Signal-enabled BurnBar release as fully cleared until counsel
has approved the concrete distribution channels.
