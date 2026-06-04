# BurnBar HPKE v3 Security Review Agent Prompt

Goal: Review the HPKE v3 migration as an upstream-blocking security reviewer
for a public Nous Research Hermes Agent PR.

Claude launch: run this workstream through Claude from the tmux `security`
window with the literal keyword `ultracode` in the prompt.

Success means:

- Findings lead the report, ordered by severity.
- Every finding includes severity, file:line, attack or defect, and fix.
- The review verifies code behavior, tests, and vectors instead of trusting
  comments or commit messages.
- The report explicitly states which security claims survive.
- The verdict says submit or hold and names the single most important fix.

Stop when:

- The targeted gateway tests and v3 vector verifier have been run or a concrete
  blocker explains why they could not run.
- The reviewer has opened the v3 fixture JSON directly.
- Every P1/P2 issue has an actionable fix.

Constraints:

- Treat BurnBar Cloud as a fully active malicious relay.
- Treat wire fields as attacker-controlled until code binds them to pinned or
  authenticated state.
- Use the pinned sender key as the sender-authentication source of truth.
- Keep metadata privacy claims scoped to content confidentiality.

## Review Commands

Run:

```bash
cd /Users/albertonunez/.hermes/hermes-agent
venv/bin/python -m pytest \
  tests/gateway/test_relay_e2ee.py \
  tests/gateway/test_relay_e2ee_v2.py \
  tests/gateway/test_relay_e2ee_v3.py \
  tests/gateway/test_burnbar_plugin.py \
  tests/gateway/test_burnbar_hpke_v3_vectors.py \
  -q
```

Open:

```bash
cd /Users/albertonunez/.hermes/hermes-agent
python -m json.tool tests/gateway/fixtures/HermesGatewayHPKEV3WireVector.json | sed -n '1,220p'
```

## Claims To Verify

1. The relay cannot read sealed message, event, attachment, sender-name, or file
   bytes under the stated content-confidentiality model.
2. Post-pairing, the relay cannot forge phone-to-agent or agent-to-phone v3
   envelopes without the sender static private key.
3. The gateway open path fails closed: v3 binds the pinned sender key, v2 is
   accepted only as compatibility, v1 remains unreachable on paired links, and
   plaintext remains refused on paired links.
4. v2 and v3 are domain-separated by version, algorithm marker, HPKE info, and
   parser shape.
5. Cross-language fixtures prove Swift-to-Python current-schema interop and
   wrong-sender rejection.
6. First trust remains rooted in authenticated pairing plus human safety-code
   comparison.

## Attack Surfaces

Review crypto:

- RFC 9180 Auth mode schedule and labels
- P-256 point validation and X9.63 encoding
- sender-auth binding
- UKS and KCI boundaries
- key and nonce uniqueness
- v2/v3 parser confusion
- empty or malformed `enc` and `wrappedKey`
- algorithm marker downgrade

Review adapter:

- `_open_envelope`
- paired-link plaintext refusal
- v3/v2 version gate
- pinned phone key source
- routing ID source
- replay high-water mark
- id-less event handling
- attachment AAD binding
- swallowed security exceptions

Review tests and hygiene:

- Python-only round trips versus external vectors
- forged-vector tests that actually fail
- PR stack cleanliness
- proprietary/internal names
- secrets or endpoints
- shared code impact outside BurnBar

## Report Format

Use:

```text
Findings

P1/P2/P3 - file:line - title
Attack or defect:
Fix:

Claims

1. Survives/Fails - reason
...

Verdict

safe to submit to Nous / hold
Single most important fix: ...
```

## Scoring Rubric

- 10: RFC 9180-conformant, cross-language current-schema vectors, no P1/P2,
  docs match code, PR stack clean.
- 9: same as 10 with only minor upstream presentation nits.
- 8: crypto sound, one contained P2 or documentation gap.
- 7: mergeable after a focused remediation pass.
- 6 or lower: bespoke ambiguity, missing vectors, fail-open path, dirty PR
  packaging, or overclaimed threat model.
