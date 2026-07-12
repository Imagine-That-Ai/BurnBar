# Self-Checks

Generated: 2026-07-04T15:02:00Z

## Commands

- `OB_EVIDENCE_OUT=/private/tmp/openburnbar-cu-evidence-qemu-final-20260704-092426 OB_CU_SKIP_CARGO=1 node scripts/linux-port/run-computer-use-evidence.mjs` exited `0` before mobile import; produced fresh QEMU portal, AT-SPI input, product audit, and target status artifacts.
- `OB_EVIDENCE_OUT=/private/tmp/openburnbar-cu-evidence-qemu-final-20260704-092426 OB_CU_ALLOW_REUSED_OUT=1 OB_CU_TARGET_STATUS_ONLY=1 OB_CU_MOBILE_LIVE_PROBE_SOURCE=/private/tmp/openburnbar-cu-evidence-portal-20260704-1054/mobile-live-surface-probe.json node scripts/linux-port/run-computer-use-evidence.mjs` exited `0`; raw-verified and imported the accepted terminal mobile probe, then resynthesized target status from artifacts in this bundle.
- `node --check scripts/linux-port/run-computer-use-evidence.mjs` exited `0`.
- `bash -n scripts/linux-port/portal-consent-lifecycle.sh` exited `0`.
- `PYTHONPYCACHEPREFIX=/private/tmp/ltf-pycache python3 -m py_compile src/linuxtest/portal_evidence.py` exited `0` in `$LINUX_TEST_FRAMEWORK`.
- `git diff --check` exited `0` in `/private/tmp/openburnbar-linux-mission-001`.

## Target Status

- `VAL-CU-001`: `pass`; QEMU aarch64 VM with virtio-gpu DRM, Sway, PipeWire, xdg-desktop-portal, xdg-desktop-portal-wlr, `chooser_type=dmenu`, ScreenCast Start success, approved PipeWire frame.
- `VAL-CU-002`: `pass`; AT-SPI2 visible-target proof bound to the passing QEMU portal baseline and product audit rows.
- `VAL-MOBILE-001`: `pass`; accepted terminal mobile probe raw fields re-verified, copied into this bundle with provenance, 12 simulator-to-Linux-peer exchanges.
- `VAL-SEC-003`: `pass`; product CLI audit verifier accepted valid artifacts and rejected chain/head/manifest/archive tamper cases.

## Notes

- `mobile-live-surface-probe.source.json`, `mobile-live-surface-probe.raw.json`, `mobile-live-surface-probe-import.json`, and `mobile-simulator-live-probe.png` preserve mobile source provenance in this bundle.
- `computer-use-target-status-only-run.json` records the explicit status-only synthesis over existing raw artifacts; default fresh-directory guard remains enabled unless `OB_CU_ALLOW_REUSED_OUT=1` is set.
