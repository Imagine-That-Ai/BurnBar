# Windows v1.0.37 Private Microsoft Store Submission - BLOCKED

> **HARD STOP:** v1.0.37 is an immutable release `NO-GO`. Do not create a
> Partner Center draft for it, upload either Store package, change an audience,
> submit it for certification, or publish it to any flight. The physical x64
> evidence found release-blocking dashboard composition and accessibility
> defects. Diagnostic overrides do not change that verdict.

This file preserves the lifecycle requirements discovered while preparing the
candidate; it is not an executable submission runbook. The exact v1.0.37
identity remains recorded in `store-submission-v1.0.37.json` and
`exact-signed-artifacts-2757652e89.json` for forensic comparison only.

A successor may receive a new private-submission runbook only after all of the
following are true:

1. The source fixes are merged and a distinct higher version is tagged from the
   exact merged commit.
2. The release workflow produces new x64 and ARM64 Store packages and a new
   manifest bound to that commit.
3. The newly signed direct package passes the complete physical x64 rerun,
   including visible dashboard content, accessibility, and performance gates.
4. The operator explicitly authorizes a **private audience** submission of that
   exact successor. Public listing, public flight, production rollout, and
   update-feed publication remain separate operations.

## Lifecycle proof required for a future passing successor

The private Store gate requires all 14 canonical assertions, not merely a
successful upload:

1. Private audience and known-user-group restriction.
2. Clean Store install and responsive launch.
3. Upgrade from an exact certified private predecessor. **BLOCKED for the first
   private submission:** no earlier BurnBar package has been certified and made
   available to the authorized private audience. Do not substitute an unsigned,
   sideloaded, draft, or merely uploaded package. To unblock, retain the exact
   Store-signed version/hash/identity receipt from the first private
   certification, then publish a distinct higher-version private successor to
   the same audience and exercise the Store-managed upgrade between those two
   exact packages.
4. Repair.
5. Rollback/recovery.
6. Uninstall and reinstall.
7. Launch, protocol, file, toast, and startup activation.
8. Single-instance routing.
9. Valid signed direct feed.
10. Tampered feed/artifact rejection.
11. Unauthorized downgrade rejection.
12. Offline feed behavior.
13. Store/direct-download coexistence.
14. winget eligibility without opening a public manifest PR.

Capture these through the canonical `store-update-lifecycle` supplemental
receipt and retain raw hashed evidence. No evidence may contain credentials,
access tokens, private account data, or an unrestricted acquisition link.
The lifecycle gate remains `BLOCKED` until assertion 3 has that real predecessor
and successor evidence; the first private certification alone cannot be called
a lifecycle PASS.
