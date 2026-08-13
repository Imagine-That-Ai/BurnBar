# Quota resets

OpenBurnBar treats a quota reset as news, not a number twitch.

## Kinds

| Kind | What it is | How it appears |
|---|---|---|
| **Scheduled** | The weekly, monthly, or daily window you already knew about | Ceremonial seal. No notification. No sound. |
| **Surprise** | Usage snapped back while the old `resetsAt` was still hours away. Codex users call this a Tibo reset. | Loud seal / jewel. Notification if the tray is closed. |
| **Banked** | A stored reset card was granted or redeemed. Codex has these; Grok and Cursor only if the payload exposes them. | Foil card. Notification if the tray is closed. |

Session / 5-hour windows refill the bar and stay silent. Estimated snapshots (SuperGrok consumer pacing) never celebrate.

## Tibo

Codex surprise copy may say “Tibo hit the button” or, after two surprises in 24 hours, “That’s cute. How about twice?” That is community folklore around [Tibo Sottiaux](https://x.com/thsottiaux). It is not an official OpenAI partnership, and OpenBurnBar never uses a likeness. Claude, Cursor, Grok, and every other provider use neutral surprise copy.

## Where it plays

- **Jewel** — nonactivating panel under the menu-bar item when the tray and Quota Vault are closed.
- **Tray** — the quota row is the stage if the popover is already open.
- **Vault** — `QuotaResetAtlas` today-cell + `SubscriptionCard` footer + `QuotaArcDial` if Quota Watch is frontmost.

Replay a remembered reset from the card footer. Play a sample from Settings → Quota Watch & Order.

## Settings

All default on except sound (off):

- Celebrate quota resets
- Scheduled weekly / monthly
- Surprise / Tibo resets
- Banked reset cards
- Play a sound

Reduce Motion removes particles. Reduce Transparency removes glass bloom.

## Detection rules (the parts that must not lie)

- Raw snapshots only. Never `reconcilingElapsedWindow` as detector input.
- Surprise only if the previous `resetsAt` was still ≥ 6 hours in the future.
- A previous `resetsAt` already in the past is a late scheduled observation.
- Clock-cross and the later HTTP refresh share one consumed boundary.
- Limit rose and absolute used did not fall → not a reset.
- Banked kind is fail-closed: no parsed inventory, no banked scene.
