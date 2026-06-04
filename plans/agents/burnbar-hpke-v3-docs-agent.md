# BurnBar HPKE v3 Docs Agent Prompt

Goal: Update maintainer-facing and security documentation so the HPKE v3
migration claims match exactly what ships.

Claude launch: run this workstream through Claude from the tmux `docs` window
with the literal keyword `ultracode` in the prompt.

Success means:

- Security docs describe v3 as RFC 9180 HPKE Auth mode key wrapping.
- Docs explain why v2 remains for compatibility.
- Docs state relay-visible metadata, KCI, static-key rotation, safety-code, and
  replay-counter limits plainly.
- Docs avoid claims beyond content confidentiality and post-pairing sender
  authentication.
- PR-ready wording exists for Nous maintainers.

Stop when:

- The docs are aligned with the final implementation and the release agent can
  paste the PR text without rewriting security claims.

Constraints:

- Edit docs only after the implementation shape is visible.
- Keep docs scoped to behavior that actually ships.
- Use the exact algorithm marker and version fields from the architecture note.

## Candidate Files

Inspect and update as needed:

- `/Users/albertonunez/.hermes/hermes-agent/plugins/platforms/burnbar/SECURITY.md`
- `/Users/albertonunez/.hermes/hermes-agent/plugins/platforms/burnbar/README.md`
- BurnBar docs that mention Hermes gateway relay E2EE or vectors
- PR body draft material in the release prompt

## Handoff Output

Return:

```text
Docs changed:
Security claims updated:
Compatibility wording:
Remaining doc gaps:
Suggested PR paragraph:
```

