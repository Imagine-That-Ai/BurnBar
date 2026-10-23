# Afar Mac 0.1.14 blank DMG: clean-install acceptance record (2026-10-21)

**Frozen record** ([docs/INDEX.md](../../../INDEX.md) rules 4 and 5). A correction is a new dated record; this body is never edited.

## Purpose

This is the durable clean-GUI acceptance evidence for `config/afar-mac-release.json`. That contract's `cleanGuiAcceptance.evidenceSha256` is the SHA-256 of this file, and the publisher's tests recompute it.

It authorizes nothing by itself:
- **Publication:** dispatching `.github/workflows/publish-afar-mac-artifact.yml` still needs the normal `release` environment approval.
- **Site:** `website/public/mission-control/release.json` stays `preparing` until a separate reviewed change.

The record was written by the Afar Mac publisher owner from receipts held in the release command's custody. The receipts stay there, and are pinned here by SHA-256.

## Artifact

| Field | Value |
| --- | --- |
| File | `MissionControl-blank-0.1.14-universal-release.dmg` |
| Size | 41,118,073 bytes |
| SHA-256 | `9957bf67a5677ca9a23fdcfe1c80fe7335ae050e8ccf11c625108402f9f445a8` |
| Source commit | `201aa7d1e839d9609a5f35f74749c371865e747b` |
| State | Signed, notarized and stapled blank (customer) build; no new build or signing for this record |
| Destination | `https://downloads.burnbar.ai/mission-control/0.1.14/MissionControl-blank-0.1.14-universal-release.dmg` (existing bucket and host; no new host) |

## Clean-install acceptance

| Field | Value |
| --- | --- |
| Clean install | `2026-10-21T19:23:37Z` (the contract's `acceptedAt`) |
| Installed version | `0.1.14` |
| Installed app tree SHA-256 | `4c92cd25a3e949b6eb21d6ef588a28c904f83d20c53b6c4e3ec2951ae59471d8` |
| Owner confirmation | Alberto confirmed the app opened and worked |
| Receipt | `CLEAN-CUSTOMER-TEST-RECEIPT.md`, 1,750 bytes, SHA-256 `17d12c406d83b1ae7d044cc0fffebae3db44693f1cfb7da04e99bff198e9158f` |
| Same-owner post-check | `2026-10-21T19:38:57Z`, 751 bytes, SHA-256 `dc2392d17896e3f77edc36dc5c5a495254d6bb1811a1a827c64a7ca54141b4a2` |

The post-check confirmed three things:
- the signed helper hash is `39ed207d6f4789dfd764b61d8015b93ac73b8e5a740ab62973336feb2741995d`;
- the listener binds to `127.0.0.1` only;
- the recorded filename scan found no owner identifiers.

## Target decision

The target is `ROOT2700-BLANK-MAC014-PUBLICATION-TARGET-DECISION-01`, dated `2026-10-21T15:49:48.878878Z`, 4,350 bytes, SHA-256 `f86eb1c43b7c2e0ac43d3c7714756562d260fabba1068625c89c3d5cf8567420`.
- **Selected:** only the existing `downloads.burnbar.ai` flow above.
- **Not selected:** any new bucket or host, and any change to another site's download allowlist.

## Not yet passed

The following happen only after publication and are **not** credited by this record:
- a browser download of the published object;
- Gatekeeper's first-launch check on the downloaded copy;
- an anonymous byte and hash check of the canonical URL.
