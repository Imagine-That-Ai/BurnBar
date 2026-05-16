# iOS iroh Gate Run

- Started: 2026-05-16T14:15:33Z
- Runs required: 10
- Interface plan: cellular
- Project: burnbar
- Device: AFB07C15-AD18-5EFA-AD1C-CADB4F286797
- Model: gpt-5.4-mini
- Relay URL: https://use1-1.relay.alberto8793.burnbar.iroh.link/
- Mac host log: docs/runbooks/iroh-dev-validation/ios-iroh-gate-20260516T141533Z/mac-host.log

- Run 01: passed (cellular)

Gate result: invalidated after run 01. The first cellular completion passed, but
the runner hit an arithmetic bug while selecting the repeated interface plan and
printed a false 10/10 summary. Use a later fixed-run artifact for Gate C/D
evidence.
Invalidated: 2026-05-16T14:17:46Z
