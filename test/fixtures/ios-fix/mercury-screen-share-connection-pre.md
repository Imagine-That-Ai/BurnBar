# Mercury screen-share connection — pre-fix

- Captured: 2026-08-06
- Device: Alberto's iPad, iPad Air 11-inch (M4), iPadOS 27.0
- App: `com.openburnbar.app`, version 1.0.2, build 82, Apple Development signed
- Source candidate: `0c290527d726d74154e8a670df3ee41f558c97b3`
- Mac peer shown by the app: `Alberto's MacBook Pro Hermes Relay`

Reproduction:

1. Open **Agents**.
2. Select the pinned Mac tile.
3. Confirm Mercury remains in the `Dialing` phase.
4. Tap **Ask to Mirror**.

Observed result:

- The button changes to **Waiting for Mac…**.
- The status says **Request sent. Check your Mac.**
- The control stream never becomes live.
- No approval or screen frames arrive.

The DebugBridge state accessors are not initialized in this app target, so the matching state snapshot is intentionally empty. The matching PNG is the authoritative visible physical-device reproduction.
