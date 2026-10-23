# Docs index and ownership rules

Where documentation lives, who owns it, how it stays fresh, and which files are
frozen records. Agents: [`AGENTS.md`](../AGENTS.md) points here; follow these
rules when you add, move, or correct a doc.

## Rules

1. **Placement.** One README per app or package, beside its code. Everything
   else lives under `docs/`, in the area directory that matches its subject
   (table below). New top-level files at the repository root are blocked by the
   root-inventory ratchet (`bash scripts/ci/check-root-inventory.sh`).
2. **Ownership.** Every live doc has an owner. OpenBurnBar has one operator
   ([`docs/runbooks/HANDOVER.md`](runbooks/HANDOVER.md)), so every area below is owned
   by the primary operator until that page names someone else. Change the Owner
   column only when a named person has accepted the area.
3. **Freshness.** A live doc must be linked from an index or another live doc.
   `bash scripts/ci/check-docs-freshness.sh` counts orphaned docs untouched for
   more than 90 days; the count is a shrink-only ratchet
   (`budgets/docs-freshness-baseline.json`). Fix a stale doc by linking it,
   refreshing it, or archiving it — never by raising the ceiling.
4. **Frozen records.** Audits, diligence reports, reviews, legal packets,
   evidence bundles, and the archive are point-in-time records. A correction is a
   new dated file that supersedes the old one; the old body is never edited. A
   frozen record may gain a dated STALE banner at the top that points at the
   newer evidence, as long as the banner changes no signature and no verdict.
5. **Evidence freezes.** A dated, one-off evidence capture (a drill, a
   certification run, a screenshot set proving a fix) goes under
   `docs/archive/evidence/YYYY-MM-DD-<slug>/` with a README that names the
   commit, the command that produced it, and the verdict. Commit structured
   results (JSON, Markdown); raw `*.log` streams are ignored by `.gitignore`
   unless an integrity manifest hashes them. Launch-gate receipts stay in
   `launch-evidence/`, where the launch gate reads them. The existing port
   evidence trees (`docs/windows-port/evidence/`, `docs/linux-port/evidence/`)
   stay where they are: parity-ledger gates and certification manifests
   reference their paths and hash their files. Do not add new raw captures there.
6. **Generated docs are never hand-edited.** Regenerate them instead:
   `docs/SCHEMA_SQLITE.sql` (`OpenBurnBarSchemaExport`),
   `docs/TECH_DEBT_METRICS.md` (`scripts/ci/update-tech-debt-metrics.sh`),
   `docs/status/release-status.json` and the README status block
   (`node scripts/release/render-release-status.mjs`), and the Droid wiki under
   `droid-wiki/` (local wiki generation; see [`AGENTS.md`](../AGENTS.md)).

## Areas

| Area | Holds | Owner | Index / freshness |
| --- | --- | --- | --- |
| `docs/*.md` (top level) | Product, subsystem, and program docs | Primary operator | Linked from [README.md](../README.md), [ONBOARDING.md](ONBOARDING.md), or this page; freshness ratchet |
| [`docs/architecture/`](architecture/README.md) | Numbered ADRs and architecture notes | Primary operator | [architecture/README.md](architecture/README.md) |
| `docs/adr/`, `docs/decisions/` | Dated decision records | Primary operator | Frozen once accepted; supersede with a new record |
| [`docs/runbooks/`](runbooks/oncall.md) | Operator runbooks, including [runbooks/HANDOVER.md](runbooks/HANDOVER.md) and [oncall.md](runbooks/oncall.md) | Primary operator | Linked from [oncall.md](runbooks/oncall.md) and [ONBOARDING.md](ONBOARDING.md) |
| `docs/ops/` | Access inventory, alert rules, event catalog, staging notes | Primary operator | `bash scripts/ops/verify-access-inventory.sh --schema` |
| `docs/security/` | Threat models, privacy invariants, assurance and sign-off pages | Primary operator | Confidentiality guard (`node scripts/security/scan-internal-content.mjs`) |
| `docs/governance/` | Risk register and security register | Primary operator | Accepted risks carry a review date |
| `docs/engineering/` | Ownership and bus factor, extraction plans | Primary operator | Freshness ratchet |
| [`docs/data-room/`](data-room/INDEX.md) | Diligence data-room index | Primary operator | `node scripts/ci/verify-data-room.mjs --check` |
| `docs/status/` | Generated release status and its inputs | Primary operator | `node scripts/release/render-release-status.mjs --check` |
| [`docs/mobile-parity/`](mobile-parity/README.md) | Mobile parity ledger and evidence scaffolding | Primary operator | `node scripts/mobile-parity/validate-mobile-parity.mjs --allow-blocked` |
| `docs/windows-port/` | Windows port plans, ledger, runbooks, certification evidence | Primary operator | `bash scripts/ci/verify-windows-parity-ledger.sh` |
| [`docs/linux-port/`](linux-port/README.md) | Linux port plans, ledger, mission evidence | Primary operator | `node scripts/linux-port/validate-parity-ledger.mjs` |
| `docs/legal/` | AGPL and licensing packets | Primary operator | Frozen record per release |
| [`docs/audits/`](audits/INDEX.md), `docs/diligence/`, `docs/reviews/`, `docs/rca/` | Audits, diligence reports, reviews, incident analyses | Primary operator | Frozen records; [audits/INDEX.md](audits/INDEX.md) |
| `docs/evidence/`, `docs/macos-ui-automation/` | Dated evidence captures | Primary operator | Frozen records; new captures follow rule 5 |
| [`docs/archive/`](archive/README.md) | Retired docs and dated evidence freezes | Primary operator | [archive/README.md](archive/README.md); excluded from the freshness ratchet |
| `docs/plans/`, `docs/superpowers/`, `docs/product-focus/`, `docs/fleet/`, `docs/signalification/` | Program plans, specs, and handoffs | Primary operator | Freshness ratchet; archive when shipped |
| `docs/analytics/`, `docs/api/`, `docs/ci/`, `docs/contracts/`, `docs/schemas/`, `docs/qa/`, `docs/analysis/` | Reference material for one subsystem each | Primary operator | Freshness ratchet |

## Platform guides and proof contracts

These pages collect platform implementation notes and validation requirements.
Proof contracts retain their signed-candidate, environment, and real-device
requirements; dated plans and implementation notes retain their stated scope.

### Linux

| Area | References |
| --- | --- |
| Parity planning and comparison | [Full parity plan](linux-port/FULL_PARITY_PLAN.md), [P-39 differential oracle](linux-port/P39_DIFFERENTIAL_ORACLE.md) |
| Gateway credentials | [P-06 credential boundary](linux-port/P06_GATEWAY_CREDENTIAL_BOUNDARY_PROOF.md) |
| Browser and computer use | [P-07 proof contract](linux-port/P07_BROWSER_COMPUTER_USE_PROOF.md) |
| Mercury media | [P-08 proof contract](linux-port/P08_MERCURY_MEDIA_PROOF.md) |
| Navigation and shell | [P-09 proof contract](linux-port/P09_NAVIGATION_SHELL_PROOF.md) |
| Dashboard layout | [P-10 proof contract](linux-port/P10_DASHBOARD_LAYOUT_PROOF.md) |
| Usage ingestion | [P-11 proof contract](linux-port/P11_USAGE_INGESTION_PROOF.md) |
| Quota | [P-12 proof contract](linux-port/P12_QUOTA_PROOF.md) |
| Onboarding | [Authority](linux-port/LINUX_ONBOARDING_AUTHORITY.md), [P-13 provider setup](linux-port/P13_ONBOARDING_PROVIDER_SETUP.md), [P-13 proof contract](linux-port/P13_ONBOARDING_PROOF.md) |
| Chat | [P-14 threads](linux-port/P14_CHAT_THREADS.md), [P-14 proof contract](linux-port/P14_CHAT_PROOF.md) |
| Activity and sessions | [P-17 export](linux-port/P17_ACTIVITY_EXPORT.md), [P-17 proof contract](linux-port/P17_ACTIVITY_SESSION_PROOF.md) |
| Memory review | [P-18 proof contract](linux-port/P18_MEMORY_REVIEW_PROOF.md) |
| Projects | [P-19 implementation notes](linux-port/P19_PROJECTS_PARITY.md) |
| Missions | [P-20 implementation notes](linux-port/P20_MISSIONS_PARITY.md), [P-20 proof contract](linux-port/P20_MISSIONS_PROOF.md) |
| Insights | [P-21 proof contract](linux-port/P21_INSIGHTS_PROOF.md) |
| Database | [P-22 proof contract](linux-port/P22_DATABASE_PROOF.md) |
| Provider workspace | [P-23 proof contract](linux-port/P23_PROVIDER_WORKSPACE_PROOF.md) |
| Settings | [P-24 proof contract](linux-port/P24_SETTINGS_PROOF.md) |
| Updates | [P-25 proof contract](linux-port/P25_UPDATES_PROOF.md) |
| Notifications | [P-27 native actions](linux-port/P27_NATIVE_NOTIFICATION_ACTIONS.md) |
| SmartHub | [P-28 proof contract](linux-port/P28_SMARTHUB_PROOF.md) |
| Text expansion | [P-29 proof contract](linux-port/P29_TEXT_EXPANSION_PROOF.md) |
| Pet companion | [P-30 implementation notes](linux-port/P30_PET_PARITY.md) |
| Accessibility | [P-31 accessibility and visual preferences](linux-port/P31_ACCESSIBILITY_POLISH.md) |
| Reliability | [P-33 proof contract](linux-port/P33_RELIABILITY_PROOF.md) |
| Credential security | [P-34 proof contract](linux-port/credential-security-proof.md) |
| Diagnostics and support | [P-35 hardening notes](linux-port/ui-parity/packets/P35-diagnostics-support.md), [P-35 proof contract](linux-port/P35_DIAGNOSTICS_SUPPORT_PROOF.md) |
| Data and privacy | [P-40 implementation notes](linux-port/P40_PRIVACY_PARITY.md) |

### Windows

| Area | References |
| --- | --- |
| Chat processes and streams | [Process and history](windows-port/CHAT_PROCESS_AND_HISTORY.md), [H3 event mapping](windows-port/H3_CHAT_STREAM_EVENT_MAPPING.md) |
| Host validation | [Foundation evidence contract](windows-port/FOUNDATION_HOST_EVIDENCE.md) |
| Secret handling | [Secret storage, redaction, and child isolation](windows-port/SECURITY_SECRETS_AND_CHILD_ENV.md) |
| Storage and process boundaries | [Security, storage, and child-process policy](windows-port/SECURITY_STORAGE_PROCESS_POLICY.md) |
| Provisioning and recovery | [Storage provisioning and recovery](windows-port/STORAGE_PROVISIONING_AND_RECOVERY.md) |
