# Text Expansion

OpenBurnBar text expansion lets a user save snippets behind `&&name` triggers, type the trigger in supported composers, and insert the saved text; macOS OpenBurnBar chat can also produce an LLM-rewritten preview that uses the current thread.

## Trigger Contract

- The activation prefix is always `&&`.
- The canonical trigger name strips repeated `&&`, lowercases the name, and accepts only `a-z`, `0-9`, `_`, and `-`.
- Trigger names are 2 to 64 characters.
- A trigger can belong to only one non-deleted snippet at a time, including disabled snippets.
- Expansion happens on a boundary: whitespace, newline, or sentence punctuation. In app-owned composers, an exact trigger can also expand without a trailing boundary when no enabled trigger has that trigger as a prefix.
- Prefix collisions stay inert until unambiguous. If `&&conf` and `&&confident` both exist, typing `&&conf` inside a longer token does not consume `&&confident`.

## Surfaces

| Surface | Static snippets | LLM rewrite | Context source |
|---|---:|---:|---|
| macOS OpenBurnBar chat | Yes | Preview before insert | Current OpenBurnBar chat thread |
| macOS global text fields | Yes, opt-in | No | None |
| iOS/iPadOS Hermes composer | Yes | Saved for Mac LLM preview | Current mobile composer state |
| iOS/iPadOS keyboard extension | Yes | No | None |
| Android Hermes/CLI composers | Yes | No | Current Android composer state |
| Android IME | Yes | No | None |

LLM rewrite is intentionally scoped to OpenBurnBar-owned thread surfaces. A global keyboard, macOS event tap, iOS keyboard extension, or Android IME cannot reliably read arbitrary third-party app thread context, and silently inventing that context would make the feature misleading. Those surfaces insert static snippets only.

## Storage And Sync

macOS stores snippets in SQLite table `text_expansion_snippets` with soft-delete tombstones, revision numbers, timestamps, and a JSON-encoded scope. macOS publishes an App Group snapshot to `group.com.openburnbar.app/text-expansion-snippets.json` for extension-style readers.

iOS/iPadOS stores the active snapshot in the same App Group shape so the keyboard extension can read it without reaching into app process state. iOS/iPadOS cloud sync uploads tombstones rather than deleting Firestore documents, so a stale device cannot resurrect a deleted snippet. Mobile can save Mac LLM-preview snippets, but mobile insertion surfaces only expand static snippets until they have an owned-thread preview flow.

Android stores static snippets in Room table `text_expansion_snippets`. The IME and in-app composers read enabled, non-deleted rows.

Cloud sync uses `users/{uid}/text_snippets/{snippetId}`. Firestore stores `sealedTitle`, `sealedTrigger`, `sealedBody`, `sealedScope`, `triggerHash`, mode, timestamps, revision, and encryption metadata. It rejects plaintext `title`, `trigger`, `body`, and `scope` fields. New writes use Cloud Vault sealed-text schema v2 with AAD bound to `uid`, collection, document id, and field name, so sealed values cannot be copied between users, documents, or fields without failing decryption. The vault key is the same Cloud Vault device-key system used by encrypted hosted session search, so Firebase stores ciphertext and keyed hashes, not snippet text.

## Safety Rules

- Global macOS expansion is off by default and compiles out of MAS builds.
- macOS global expansion requires Accessibility permission, skips OpenBurnBar itself, skips secure/focused denied surfaces, and resets its buffer on command/control/option and non-printable navigation events. When permission is missing, Settings → Text Expansion routes users to **Privacy & Security → Accessibility** (same pane as Computer Use).
- LLM snippets produce a preview with Insert/Cancel controls before draft replacement in macOS OpenBurnBar chat.
- Static snippets can run globally; LLM snippets stay in OpenBurnBar-owned thread contexts.
- Cloud rules allow owner-scoped read/write/delete only and validate the encrypted document shape.

## Verification

Run the focused gates after touching this feature:

```bash
swift test --package-path OpenBurnBarCore --filter TextExpansionTests
xcodebuild build -quiet -project OpenBurnBar.xcodeproj -scheme OpenBurnBar -configuration Debug -destination 'platform=macOS' -derivedDataPath /tmp/openburnbar-text-expansion-mac CODE_SIGNING_ALLOWED=NO
xcodebuild build -quiet -project OpenBurnBar.xcodeproj -scheme OpenBurnBarMobile -configuration Debug -destination 'generic/platform=iOS Simulator' -derivedDataPath /tmp/openburnbar-text-expansion-ios CODE_SIGNING_ALLOWED=NO
cd android && JAVA_HOME="$HOME/.homebrew/opt/openjdk@21" ANDROID_HOME="$HOME/Library/Android" ANDROID_SDK_ROOT="$HOME/Library/Android" ./gradlew :app:testDebugUnitTest --tests "com.openburnbar.data.text.TextExpansionMatcherTest" :app:assembleDebug --no-daemon
npm --prefix functions run test:firestore-rules
git diff --check
```
