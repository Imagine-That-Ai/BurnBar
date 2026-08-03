# Main CI certification note (2026-08-03)

This PR exists solely to drive a full merge-group certification of the current
`main` tip after the business-readiness stack landed via admin squash merges.

## Why

`BurnBar CI Gate` on bare `workflow_dispatch` against `main` cannot go green:
most required component checks only fire on `pull_request` / `merge_group`.
The commercial launch gate needs a trusted `BurnBar CI Gate` result bound to
the shipped tree (main tip or exact tree-bound PR head).

## Related

- Production Functions dry-run: success for candidate `v1.0.30` plumbing
- Real tag deploy still blocked on libsignal runtime readiness + counsel approval
