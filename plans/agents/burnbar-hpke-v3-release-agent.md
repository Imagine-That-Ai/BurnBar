# BurnBar HPKE v3 Release Agent Prompt

Goal: Package the BurnBar HPKE v3 migration so Nous Research reviewers can
understand the standard choice, compatibility story, and exact security claims
without reverse-engineering the discussion.

Claude launch: run this workstream through Claude from the tmux `release`
window with the literal keyword `ultracode` in the prompt.

Success means:

- The PR narrative leads with RFC 9180 HPKE Auth mode v3.
- The docs explain why v2 remains present and why v3 is preferred.
- Security notes state KCI, static-key, metadata, replay, and safety-code
  limits plainly.
- The stacked PRs stay reviewable: platform plugin first, E2EE/HPKE second.
- The diff contains no secrets, proprietary side-product names, or unrelated
  files.
- CI and local gateway tests are linked in the PR body.

Stop when:

- The PR body, security notes, changelog entry, and reviewer checklist are ready
  to paste into GitHub.
- The branch diff has been reviewed against the intended base.
- The test evidence is current for the final commit.

Constraints:

- Describe the relay threat model as content confidentiality and sender
  authentication after pairing.
- Describe relay-visible metadata explicitly.
- Describe first-pairing MITM defense as safety-code comparison by the user.
- Keep v2 compatibility framed as migration support.

## Required PR Summary

Use this maintainer-facing summary:

```text
This PR adds BurnBar relay E2EE for the Hermes platform plugin. The preferred
key-wrap version is v3, which uses RFC 9180 HPKE Auth mode with
DHKEM(P-256, HKDF-SHA256), HKDF-SHA256, and AES-256-GCM. v2 remains supported
for existing BurnBar clients and fixtures, and the paired gateway path continues
to reject v1/plaintext downgrade attempts.
```

## Required Security Paragraph

Use this wording:

```text
Threat model: BurnBar Cloud is an untrusted relay that may reorder, drop,
duplicate, mutate, or inject gateway documents. The relay still sees routing
IDs, message IDs, timing, and approximate ciphertext sizes. E2EE protects
payload content and authenticates the paired sender after the user completes
the authenticated pairing flow and compares the safety code. If a static relay
private key is stolen, that key must be rotated by re-pairing.
```

## Required Reviewer Checklist

Include:

- v3 uses RFC 9180 HPKE Auth mode for key wrapping.
- v2 remains byte-stable for compatibility.
- v1 is not accepted on paired gateway links.
- plaintext is refused on paired gateway links.
- sender authentication binds the pinned sender key.
- inbound sealed events require replay counters.
- Swift-generated vectors cover current-schema event, reply, model switch, and
  attachment cases.
- wrong-sender vector fails.
- docs state KCI and metadata limits.

## Required Local Evidence

Paste the final command outputs for:

```bash
venv/bin/python -m pytest \
  tests/gateway/test_relay_e2ee.py \
  tests/gateway/test_relay_e2ee_v2.py \
  tests/gateway/test_relay_e2ee_v3.py \
  tests/gateway/test_burnbar_plugin.py \
  tests/gateway/test_burnbar_hpke_v3_vectors.py \
  -q
```

Paste the branch readback:

```bash
git status --short --branch
git diff --stat upstream/main...HEAD
```

## Release Decision

Submit only when:

- security review reports no P1
- P2 issues are fixed or intentionally documented with reviewer-visible
  rationale
- the vector suite is external-language generated
- the final branch contains only the intended platform/E2EE files

Hold when:

- v3 vectors are Python-only
- v3 falls back to v2 after authentication failure
- paired links accept plaintext
- sender authentication uses a wire key instead of the pinned key
- docs claim metadata privacy beyond what the relay design provides
