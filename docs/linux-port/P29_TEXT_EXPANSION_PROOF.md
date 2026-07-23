# P-29 installed text-expansion proof

P-29 is credited only from a real signed Linux package running in one of the seven release environments. The proof uses `/usr/libexec/openburnbar-daemon-launch`, `/usr/bin/openburnbar-linux-desktop`, the daemon RPC canon, a native Secret Service or KWallet backend, and a registered signed IBus/Fcitx engine. Browser fixtures, source scans, synthetic accessibility trees, and uninstalled binaries are rejected.

## Required live sequence

1. Verify the installed manifest, signature, package ownership, exact candidate HEAD, version, architecture, and environment.
2. Isolate daemon support, home, socket, token, and index paths without touching an existing profile.
3. Reach the Text Expansion surface through the installed desktop and capture real AT-SPI state.
4. Persist explicit in-app and system-IME consent with global capture declined. The proof uses a random `OPENBURNBAR_TEXT_EXPANSION_KEY_NAMESPACE`, never the user's default encryption-key identifier.
5. Create, edit, import, expand, and delete marked snippets through the typed daemon RPCs, proving readback and advancing revisions.
6. Expand one trigger through the registered input-method engine, then prove a password/secure field is denied before the engine write count changes.
7. Prove cancellation and the Linux kill switch stop the engine.
8. Restart the daemon and prove consent and snippet persistence from the AES-GCM sealed store.
9. Prove owner-only storage contains no plaintext, corruption fails closed, and removing the native key fails closed.
10. Restore the key, store, snippets, daemon service, desktop processes, and engine state exactly. Cleanup failures are aggregated with the primary failure.

Each meaningful state has a distinct PNG and AT-SPI artifact. The session materializer confines all evidence to `docs/linux-port/evidence/product-parity-inputs/P-29/<environment>/`, re-hashes copied bytes, and binds the session to the signed release candidate. `capture-p29-text-expansion-proof.mjs` derives the final claim exclusively from the validated session.

## Fail-closed conditions

The proof fails for an unavailable keyring, an unsigned/unregistered engine, a missing secure-field decision, any secure-field write, plaintext persistence, weak/symlinked paths, missing restart persistence, reused screenshots, synthetic AT-SPI, failed teardown/restoration, or mismatched candidate identity.

## Current runtime prerequisite

Deb, RPM, and AUR candidates package the executable-bound, release-signed IBus engine, its component XML, and its schema-v2 manifest. Fcitx remains an explicit unavailable capability until its native addon is packaged. Standalone AppImage system expansion also remains unavailable because an engine signed for the canonical `/usr/libexec` identity cannot safely authenticate a transient mount path; in-app expansion is unaffected.

The package also carries `/usr/share/openburnbar/text-expansion/fcitx5-openburnbar-addon.json`, a source-only capability contract. It is not an addon binary and does not promote a host `fcitx5` installation to product support. The contract records the required `Fcitx5Core` headers and the same no-global-capture, no-clipboard, no-surrounding-text, and secure-field-denial invariants. Release validation fails closed if this artifact is missing or if metadata marks Fcitx5 as runtime/package-supported before a signed native build exists.

`run-p29-installed-text-expansion-workflow.mjs` is the production adapter and direct entrypoint. It defaults exclusively to `/usr/bin/openburnbar-linux-desktop`, `/usr/libexec/openburnbar-daemon-launch`, and `/usr/libexec/openburnbar/text-expansion-engine`. The workflow selects the installed `openburnbar` IBus engine, types through real X11 keyboard events into an ephemeral GTK free-form entry, and accepts expansion only when the entry itself contains the configured replacement. It then types the same trigger into a GTK password entry and requires the literal trigger to remain with no replacement. The receipt binds both observations to the probe PID and marker. The prior IBus engine is restored exactly. The adapter also captures real screenshots and AT-SPI trees, exercises the real daemon RPC and Secret Service key, proves engine cancellation and kill-switch termination, and restores the isolated support/home trees plus the prior user-service state. The GTK process is only a field verifier; the engine, signed manifest, IBus component, daemon, CLI, and desktop are the installed production package. The proof directory must be empty and owner-only before the run; evidence is written only after restoration succeeds.

Linux-only contract validation:

```bash
swift test --package-path OpenBurnBarDaemon --filter BurnBarLinuxTextExpansionAdapterTests
swift test --package-path OpenBurnBarDaemon --filter BurnBarTextExpansionServiceTests
node --test scripts/linux-port/p29-native-text-expansion-probes.test.mjs scripts/linux-port/p29-text-expansion-proof.test.mjs scripts/linux-port/linux-text-expansion-engine.test.mjs
```
