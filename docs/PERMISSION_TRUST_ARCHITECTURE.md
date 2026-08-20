# Permission trust architecture

How OpenBurnBar asks the operating system for anything, and why it asks the way it does.

> **The rule, in one sentence:** no macOS dialog appears until the user has asked for
> that capability by name inside BurnBar, and BurnBar has explained what the dialog is
> about to say.

This is not a style preference. BurnBar's pitch is *let your own agents see and drive
your Mac*. macOS narrates that with "OpenBurnBar wants to record this computer's screen"
and "wants to control this computer". Meeting those sentences cold, seconds after
install, is indistinguishable from meeting spyware. The dialogs are unavoidable; being
the *second* voice instead of the first is not.

## Policy this implements

- [`docs/PRODUCT_FOCUS_AND_ONBOARDING_PLAN.md`](PRODUCT_FOCUS_AND_ONBOARDING_PLAN.md) §"Permission ladder" — nothing at T+0, nothing at T+2s.
- [`docs/product-focus/ONBOARDING_SPEC.md`](product-focus/ONBOARDING_SPEC.md) §6 — Screen Recording, Accessibility, Camera, Microphone, Remote Desktop and Automation are removed from onboarding entirely and asked at the moment of use.
- `FirstRunReveal`'s own header contract — "no account, no API key, and no OS permission prompt".

## The three layers

### 1. Nothing runs that the user did not turn on

`OpenBurnBarRuntime.shouldStartBackgroundApplicationServices` returns `true` for every
real launch — it suppresses only the DEBUG performance harness. It is *not* a feature
gate, and reading it as one is how two dialogs ended up firing for every user:

| Was | Now |
|---|---|
| `MacAgentReplyNotificationListener.start()` called `requestAuthorization()` outright | Asked in `deliver(_:)`, when a real agent reply exists to show. A prior denial is never re-asked. |
| `PixelClockController.start()` bound an all-interfaces `NWListener` on `:7001` regardless of settings | Binds only when Pixel Clock is enabled; the heartbeat reconciles so enabling later still works |
| `TextExpansionRuntimeController` prompted for Accessibility *and* force-opened System Settings on any launch with stale trust | Publishes `needsAccessibilityGrant`; Settings renders it as a row the user can act on |

**If you add a service to `startLiveServicesIfNeeded`, gate it on its own setting.**
`LaunchPermissionQuietnessTests` fails the build if the first two regress.

### 2. One door to the operating system

[`FirstRunPermissionLadder`](../AgentLens/Services/FirstRun/FirstRunPermissionLadder.swift)
is the only supported path from app UI to a macOS permission dialog.

```
caller → ladder.request(kind, bundleId:)
           ├─ already granted?           → return, ask nothing
           ├─ explainer (trust sheet)    → user says "Not now" → stop, never reach macOS
           └─ prompter                   → SystemPermissionPromptRunner → macOS dialog
```

It **fails closed**: with no explainer wired it refuses to prompt rather than degrading
to the old unannounced behaviour. That is deliberate — a silent fallback would restore
exactly the bug this type exists to prevent, and nobody would notice.

It is not a singleton. The process-wide instance lives on `AppCommandRouter`, which every
surface that can ask for a permission already reaches, so the shared-singleton ratchet in
`budgets/singleton-baseline.json` stays flat.

**Two paths deliberately bypass the ladder:**

- `SystemPermissionReceiver` (phone-initiated). The phone already showed its own
  explanation; a second modal on a Mac nobody is sitting at would block a remote flow.
- `ScreenCapturePipeline` / `CameraCapturePipeline`. They have no window to present from,
  and by then the user has already started a call or session. App-UI callers pass
  `requestPermissionIfNeeded: false` so the ladder owns first contact.

### 3. BurnBar speaks first

[`SystemPermissionKind.safetyFrame`](../OpenBurnBarCore/Sources/OpenBurnBarComputerUseCore/SystemPermissionSafetyFrame.swift)
carries five fixed answers per permission:

| Field | Answers |
|---|---|
| `whoWatches` | Who is on the other side |
| `whereItGoes` | Where the data actually goes, including off this Mac |
| `whoDrives` | Who initiates, who approves |
| `ifYouDecline` | What still works — makes declining visibly safe |
| `howToRevoke` | How to take it back, and what the app does then |

The slots are fixed so every permission discloses the same five things, including the
unflattering ones. This is separate from the existing `onboardingCapabilitySummary` /
`onboardingDenialExamples` copy, which answers "what you gain" — necessary, and not
sufficient for someone asking whether this is malware.

`SystemPermissionTrustSheet` renders it immediately before the OS dialog. Its primary
button says **"Show the macOS prompt"**, never "Allow": the button grants nothing, and
an "Allow" followed by a second dialog asking the same thing is the double-consent
pattern that makes people suspect a trick.

## Honest copy is enforced, not hoped for

An early draft of the screen-recording text said *"Screenshots stay on this Mac."*
**It is false.** Tool results — screenshot content included — are returned to the
configured model provider, and frames go peer-to-peer to a paired iPhone during Agent
Watch. `docs/PRIVACY.md` §"Optional Computer Use Audit Notarization" is narrower than it
reads: it covers audit *export*, not the agent data path.

`SystemPermissionSafetyFrameTests.test_whereItGoes_neverClaimsDataStaysOnThisMac` fails
the build on that phrasing for any kind whose output leaves the machine. The guard was
verified by injecting the claim and watching it go red.

> A trust surface that overclaims is worse than no trust surface. The one user who
> checks and finds a gap stops believing all of it.

Independent review then caught three more overclaims that the first guard did not cover,
which is the useful lesson: *one* honesty rule is not a honesty policy. Each became its
own test.

| Overclaim | Why it was false | Guard |
|---|---|---|
| Accessibility said data went only to a local audit log | AX labels, window titles and URLs are returned as tool results and sent to the model provider, exactly like a screenshot | `test_kindsThatReachTheModelProviderSaySo` |
| "Every action stops for your approval" | True in Manual only. Step lets one approval cover up to ten similar actions or thirty seconds; Trusted dispatches scoped actions without asking | `test_noFrameClaimsUnconditionalPerActionApproval` |
| Full Disk Access described as opening "a specific folder" | macOS has no per-folder form: the grant covers Mail, Messages, Safari, Time Machine and more at once, and file contents an agent reads become tool results | `test_fullDiskAccessDisclosesTheGrantIsOSWide` |

**Per-action approval is a property of the session mode, not of the permission.** Any copy
that promises it unconditionally is wrong for two of the three modes. Describe the modes.

The same instinct is why `.remoteDesktop` and `.systemExtension` tell the user it is fine
to decline. Saying "say no" once is what makes the reassurance elsewhere credible.

## The keychain, and why it looked like a password grab

`DatabaseEncryptionService` reads the SQLCipher key inside `OpenBurnBarApp.init` —
before any window exists. Items written without `kSecUseDataProtectionKeychain` land in
the legacy login keychain, whose per-item ACL is bound to the requesting binary's code
signature. When that drifts, macOS asks for the login keychain password. Users cannot
tell that apart from a request for their computer password.

The daemon always wrapped these reads in `withKeychainUserInteractionDisabled`; the app
never did. It does now (promoted to `OpenBurnBarKernel`, so `DataStore` does not import a
Computer Use module), paired with `kSecUseAuthenticationUI: kSecUseAuthenticationUIFail`.

**Suppressing the dialog created a data-loss path that had to be closed in the same
change.** `getKey()` collapsed every failure into `nil`, and `getOrCreatePersistedKey()`
reads `nil` as permission to mint a new key — which makes an existing encrypted database
unopenable forever. Hence `KeyLookup`:

```swift
enum KeyLookup { case found(String); case absent; case unreadable(OSStatus) }
```

Only `.absent` may create a key. `.unreadable` throws
`DatabaseEncryptionError.keychainKeyUnreadable`.

**The classification has to survive to the caller.** `DataStoreCoordinator` opens an
existing encrypted database and originally called `getKey()`, which collapses
`.unreadable` back to `nil` — so a locked key was reported as *missing* and the recovery
screen offered archive-and-reset, discarding an intact database. It calls `lookUpKey()`
and switches on all three cases. Anything else that needs to tell these states apart must
do the same; `getKey()` is only for callers where "no usable key" is the whole answer.

Failing closed alone would have been a regression: before, a user could type their
password and continue; after, they would hit a dead end. So the recovery screen now
recognises this case, says plainly that the database is intact and that macOS is about to
ask for the login password, and offers **Unlock…**, which calls
`unlockUnreadableKeyWithUserConsent()` — the one place permitted to allow keychain UI,
and only from a control the user just clicked. Same rule as the ladder: we speak first.

### Why not just move to the data-protection keychain?

That is the textbook fix and it is **not currently safe here**. Data-protection items are
scoped by `keychain-access-groups`. The app declares one; **no daemon binary does**
(`OpenBurnBarDaemon`, the CLI, privileged-input and remote-access agents all read
app-written items). Migrating unilaterally would strand the daemon, which reads the same
`com.openburnbar.database-encryption` item.

Doing it properly means adding the entitlement to every binary that touches these items,
re-provisioning their signing, and sequencing the migration so neither side is stranded —
validated on signed Developer ID builds, not Debug. That is a real project, not a
follow-up flag, and it is tracked as such. Until then the interactive-unlock path makes
the failure recoverable in one click rather than fatal.

## Adding a new permission

1. Add the case to `SystemPermissionKind` and give it a `safetyFrame`. All five fields
   are required and `SystemPermissionSafetyFrameTests` enforces it.
2. Add the raw call to `SystemPermissionPromptRunner.run(kind:bundleId:)`, and declare in
   `hasNativePrompt(for:)` whether macOS can prompt at all or the user must be sent to
   System Settings.
3. Call it as `AppCommandRouter.shared.permissionLadder.request(kind)`. **Never call
   `CGRequestScreenCaptureAccess`, `AXIsProcessTrustedWithOptions` or
   `AVCaptureDevice.requestAccess` directly from app UI.**
4. If it can run at launch, gate it on a setting and add a case to
   `LaunchPermissionQuietnessTests`.

## Tests that hold this together

| Test | Guards |
|---|---|
| `FirstRunPermissionLadderTests` | Explanation always precedes the OS prompt; declining never reaches macOS; a missing explainer fails closed; per-app consent for Automation |
| `LaunchPermissionQuietnessTests` | Notifications only prompt on `.notDetermined`; the launch path never requests authorization, binds an ungated listener, or fires the Accessibility prompt |
| `DatabaseKeyLockedRecoveryTests` | `.absent` vs `.unreadable` classification; a locked key never mints a replacement; the failure surfaces as recoverable |
| `SystemPermissionSafetyFrameTests` | Every kind has a complete frame; no "stays on this Mac" overclaim; the frame is not a copy of the sales copy; the powerful grants invite declining |
| `SystemPermissionMonitorRefreshTests` | The wizard asks through the ladder; the trust overview blocks every request until acknowledged |

## Regenerating the Xcode project

Adding any file here means regenerating `OpenBurnBar.xcodeproj`. Do it from a checkout
with **no build output in it**. XcodeGen reads whatever is on disk, so a working copy
holding `.derived-data`, a `.spm-cache` symlink, or a previously generated `.xcodeproj`
emits hundreds of lines of duplicate group hierarchy — which regenerates clean on CI and
fails the `XcodeGen pbxproj drift` gate with a diff that looks nothing like your change.

```bash
git worktree add --detach /tmp/obb-pbxproj HEAD
(cd /tmp/obb-pbxproj && xcodegen generate --spec project.yml)
cp /tmp/obb-pbxproj/OpenBurnBar.xcodeproj/project.pbxproj OpenBurnBar.xcodeproj/project.pbxproj
```

Use the XcodeGen version pinned in `.github/workflows/pr-native-fast.yml`; different
versions emit different package-product sets and the gate compares them directly.
