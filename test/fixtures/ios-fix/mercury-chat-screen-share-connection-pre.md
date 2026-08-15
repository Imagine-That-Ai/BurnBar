# Mercury chat and screen-share connection — pre-fix

- Captured: 2026-08-06
- Device: Alberto's iPad, iPad Air 11-inch (M4), iPadOS 27.0
- App: `com.openburnbar.app`, version 1.0.2, build 82, Apple Development signed
- Source candidate: `0c290527d726d74154e8a670df3ee41f558c97b3`
- Firebase bundle validation: `GOOGLE_APP_ID`, `PROJECT_ID`, `REVERSED_CLIENT_ID`, `CLIENT_ID`, and `API_KEY` are present.

The physical iPad is signed in and displays synced BurnBar data, proving the replacement build no longer follows the missing-Firebase configuration path seen in installed build 83.

Reproduction:

1. Open **Quick ask Hermes**.
2. Enter `Reply with exactly: MERCURY CHAT OK`.
3. Send the message.

Observed result:

> Update OpenBurnBar on your Mac, then reconnect Hermes. Messages here stay private to your devices, so they can only be sent once that Mac is ready.

The DebugBridge state accessors are not initialized in this app target, so the matching state snapshot is intentionally empty. The matching PNG is the authoritative visible physical-device reproduction.
