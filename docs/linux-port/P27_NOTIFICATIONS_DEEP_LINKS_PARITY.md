# P-27 Notifications And Deep Links Installed Proof

P-27 is certifiable only from the exact signed package installed in a real support desktop. Source tests, `notify-send` by itself, a staged Tauri binary, or a notification body without an observed product action do not satisfy this requirement.

## Proven contract

The producer binds every receipt to the selected release run, artifact digest, package version, signed installed manifest, signature, target commit, environment, desktop, display server, and compositor. It verifies package ownership of:

- `/usr/bin/openburnbar-daemon`
- `/usr/bin/openburnbar-linux-desktop`
- `/etc/xdg/autostart/openburnbar.desktop`

The native transcript must prove all of the following:

- The installed shell queried `native_notification_capabilities` and delivered through `native_notification_show` against a live `org.freedesktop.Notifications` server that advertised actions.
- A freedesktop **Open** action reached the product event bridge and opened Overview.
- A freedesktop **Reply** action reached the product event bridge, opened Chat, and focused the composer. This preserves reply intent without claiming unsupported inline notification text input.
- An action received before renderer bootstrap was queued and drained exactly once.
- A warm second launch forwarded exactly once to the existing owner process.
- The installed shell began a real Google PKCE operation, launched its authorization URL through an isolated browser sink, rejected a wrong-state callback with HTTP 400, accepted the matching callback with HTTP 200, and refused a replay after cancellation.
- OAuth callback, membership invite, and provider/model links were strictly accepted and retained one owner PID.
- At least five hostile or malformed links were rejected by the single-instance/deep-link boundary.
- The package-owned XDG entry launched `openburnbar-linux-desktop --background` at login.
- AT-SPI recorded the destination and focus outcome, with four distinct nonblank screenshots.
- The exact daemon state, desktop PID set, autostart bytes, and single-instance runtime-directory contents were restored.

The runtime capability snapshot records the real compositor/session. Wayland is not silently relabeled as X11, and a notification server without action support cannot certify P-27.

## Capture order

1. Create disjoint owner-only empty raw evidence, isolated `HOME`, and isolated `XDG_RUNTIME_DIR` directories.
2. Run `run-p27-native-notification-probes.mjs` in the live installed desktop.
3. Run `materialize-p27-notifications-session.mjs` to copy raw receipts and the installed manifest/signature under the canonical P-27 evidence root.
4. Run `capture-p27-notifications-proof.mjs` immediately. The capture rejects a checkout HEAD mismatch or evidence older than 15 minutes.
5. Register the resulting `feature.notifications-deep-links-installed` artifact only after the native producer has completed successfully.

The default runner uses installed paths and real host tools. It starts the supported Linux `tauri-driver`/`WebKitWebDriver` adapter against `/usr/bin/openburnbar-linux-desktop`, invokes `native_notification_capabilities`, `native_notification_show`, and the account commands through Tauri IPC, and observes the resulting product route and renderer state. Tests inject dependencies only at the exported function boundary. This prevents `notify-send`, a staged binary, a fabricated callback URL, or a synthetic D-Bus server from being mislabeled as product-adapter proof.

Cold-action proof runs during WebDriver session creation: as soon as the package-owned process exists, one package-owned second launch forwards a Reply action before WebDriver reports a mounted renderer. Certification then requires Chat/composer state, exactly one queued route, no second route, and no notification actions left after the renderer drain. Open and Reply delivery subsequently force Settings as a neutral precondition, activate the real desktop notification control through AT-SPI, and require the corresponding renderer transition.

The OAuth browser sink is confined to the session's isolated `HOME`. It captures only the product-opened Google authorization URL, never follows it, and is deleted with the isolated session. The probe extracts the real loopback port and 43-character PKCE state, proves that a wrong state cannot consume the listener, submits a bounded fake authorization code with the correct state, cancels before any credential exchange can succeed, and verifies that the one-shot listener is closed. No user browser profile, account credential, refresh token, or persistent auth state is used.

## Failure policy

Capture fails on stale or replayed screenshots/AT-SPI, symlink traversal, non-owner evidence, package substitution, unsupported action servers, malformed link acceptance, multiple owner PIDs, repeated warm forwarding, duplicate cold drains, changed autostart bytes, leaked runtime files, process/service drift, or any cleanup error. Primary and cleanup failures are preserved together in an `AggregateError`.
