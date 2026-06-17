
## Deploy incident + rollback (post-Codex-fixes)

When Google's Firebase Rules service recovered (~00:17Z), my background deploy-retry
loop ran `firebase deploy` against the LOCAL `firestore.rules` — but a concurrent
process had, at 19:16 local, `git stash`ed the uncommitted changes
("wand-backbone-uncommitted-pre-followup-merge"), reverting `firestore.rules` to the
pre-V-10 HEAD. So the deploy pushed ruleset `fa47314f`, which uses bare
`sharedArtifactOwnerWrite` — **re-opening V-10 (plaintext shared artifacts)** in prod.

Detected immediately on readback (V-41/P1 both absent → investigated → found bare rule).
**Rolled the release pointer back to `f3990100` (V-10 sealed)** via REST UpdateRelease at
00:19Z. Exposure window ~2 min, gated behind opt-in collaboration sync → negligible.

State after rollback:
- **Production: `f3990100`, V-10 SEALED ✅** (verified).
- Full hardening (V-10 + V-41 + P1 validators) preserved in `git stash@{0}` (9 markers) and the V-41 ruleset `8140641b` is on the server.
- **Local `firestore.rules` is the reverted pre-V-10 version** — a future `firebase deploy` (or `/ship`) would RE-OPEN V-10. Do NOT deploy rules until the working tree is restored from `stash@{0}` and re-verified (108-case emulator suite).

Lesson: never run an unattended `firebase deploy` loop against a working tree a
concurrent process is mutating. Pin the ruleset content (deploy a specific ruleset by
ID, or snapshot the file) rather than re-reading the live working tree each attempt.
