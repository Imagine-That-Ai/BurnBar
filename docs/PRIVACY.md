# OpenBurnBar Privacy Policy

**Last updated: May 2026**

## Summary

OpenBurnBar is local-first software. It reads files your AI coding agents leave on your own disk. No data is collected, transmitted, or sold by default.

---

## What OpenBurnBar Does

OpenBurnBar reads session log files that AI coding agents (Claude Code, Codex, Factory Droid, Cursor, Kimi, Windsurf, and others) write to your local disk. It uses this data to estimate token consumption and API spend, and displays that information to you inside the app.

**OpenBurnBar never reads your API keys.** It reads usage logs, not credentials.

---

## Data Collection

**By default, OpenBurnBar collects nothing.** All processing happens on your device. No telemetry, no analytics, no crash reports, no usage data is transmitted anywhere unless you explicitly opt in.

### Optional Cloud Sync (opt-in only)

If you choose to sign in with Google or Apple and enable cloud sync, OpenBurnBar may store the following in Firebase (Google Cloud):

- Usage row summaries (token counts, cost estimates, timestamps, provider names)
- In-app chat thread metadata (thread IDs, timestamps — not message bodies unless separately enabled)
- Sync state metadata

Cloud sync is **disabled by default**. You can disable it at any time in Settings → Cloud Sync. Disabling sync does not affect local data.

### Optional Diagnostics (opt-in only)

If you enable crash reporting or diagnostics, anonymized crash reports may be sent to Sentry. This is disabled by default.

---

## Data We Never Collect

- Your API keys or credentials
- The content of your source code or agent conversations (unless you explicitly enable conversation backup)
- Personal identifying information beyond what your Apple or Google account provides for sign-in
- Any data from other applications

---

## Third-Party Services

When cloud sync is enabled:

| Service | Purpose | Privacy Policy |
|---------|---------|----------------|
| Firebase (Google) | Authentication, optional cloud sync | [firebase.google.com/support/privacy](https://firebase.google.com/support/privacy) |
| Sentry | Optional crash reporting | [sentry.io/privacy](https://sentry.io/privacy) |

---

## Children's Privacy

OpenBurnBar is a developer tool intended for adults. We do not knowingly collect data from children under 13.

---

## Your Rights

You can:
- **Delete all local data** by removing the OpenBurnBar app and its support files
- **Delete cloud data** by signing out and selecting "Delete my data" in Settings → Account
- **Disable all optional features** at any time in Settings

---

## Changes to This Policy

If we make material changes, we will update the "Last updated" date above. Continued use after changes constitutes acceptance.

---

## Contact

For privacy questions or data deletion requests:

**Imagine That AI Limited Liability Company**
Email: privacy@imagine-that.ai
GitHub: [github.com/Imagine-That-Ai/BurnBar/issues](https://github.com/Imagine-That-Ai/BurnBar/issues)
