# Windows v1.0.37 Private Microsoft Store Submission

This runbook prepares a non-public Microsoft Store submission for exact source
commit `2757652e89440eb647d21721895fc61ec89935d3`. It does not authorize a
public listing, public flight, production rollout, or update-feed publication.

## Explicit authorization required

Before creating or submitting Partner Center state, obtain operator
authorization naming:

- Product `BurnBar`, Store ID `9PKMSDP99CJ6`.
- Exact version `1.0.37.0` and source commit above.
- `Private audience`, never public audience.
- The known-user group and each authorized Microsoft-account email.
- Permission to upload both exact Store packages below.
- Permission to submit the private build for Microsoft certification.

Creating a draft, changing audience, creating a known-user group, uploading,
and submitting are separate external mutations. Stop at any boundary not
explicitly authorized.

## Identity and packages

| Field | Exact value |
| --- | --- |
| Product | `BurnBar` / `9PKMSDP99CJ6` |
| Package identity | `ImagineThatAiLLC.BurnBar` |
| Publisher | `CN=5AE4835A-8FC9-48CF-9453-81F465AD2216` |
| Publisher display name | `Imagine That Ai LLC` |
| Package family | `ImagineThatAiLLC.BurnBar_txkpd5gwvjf3t` |
| Version | `1.0.37.0` |

Upload only these intentionally unsigned Store packages; Microsoft Store is
the final signer:

| Architecture | File | Bytes | SHA-256 |
| --- | --- | ---: | --- |
| x64 | `OpenBurnBar-1.0.37-store-x64.msix` | 233683346 | `ebca146a9504a6e8d68846b99de5324950c0098f7088084abbf2591d9cc2e0b7` |
| ARM64 | `OpenBurnBar-1.0.37-store-arm64.msix` | 227964914 | `06b0230ccea93f1f8c36860def5c07b2ded38ae4c110fed78bd1661a91e18144` |

Reconcile Partner Center against `store-submission-v1.0.37.json` from release
run `29650389335`. A hash, size, identity, publisher, architecture, or version
mismatch is a hard stop. Do not upload the direct-download MSIX files.

## Submission contract

- Pricing: Free
- Visibility: Private audience
- Category: Developer tools
- Subcategory: Utilities
- Privacy: `https://burnbar.ai/legal/privacy-policy`
- Support: `https://burnbar.ai/support`
- Terms: `https://burnbar.ai/legal/terms`
- Website: `https://burnbar.ai`

Use Windows screenshots from the exact physical x64 candidate. Scan them for
private prompts, emails, tokens, filesystem paths, device identifiers, and
production data before upload. Complete age-rating and capability declarations
literally, including network communication, AI output, optional messaging/media,
and explicitly approved Computer Use. Record that physical ARM64 certification
is an explicit beta limitation.

## Lifecycle proof after private certification

The private Store gate requires all 14 canonical assertions, not merely a
successful upload:

1. Private audience and known-user-group restriction.
2. Clean Store install and responsive launch.
3. Upgrade from the prescribed private predecessor.
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
