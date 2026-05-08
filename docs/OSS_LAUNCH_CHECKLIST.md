# OpenBurnBar OSS Launch Checklist

This file tracks launch settings that cannot be inferred from the working tree alone.

Re-check every item immediately before changing repository visibility.

## Confirmed via GitHub API on 2026-04-04

- Repository visibility: `private`
- Default branch: `main`
- Remote branches currently exposed on origin: `main` only
- Issues: enabled
- Wiki: enabled
- Discussions: enabled
- Repository description: `Local-first macOS menu bar app for tracking AI coding agent usage, transcripts, and workflows.`
- Homepage URL: `https://github.com/Ajnunezg/BurnBar#readme`
- Topics: `ai-agents`, `burnbar`, `developer-tools`, `local-first`, `macos`, `openburnbar`, `swiftui`, `vscode-extension`
- Branch protection on `main`: enabled
- Required status checks on `main`: `openburnbar-pr` with strict mode enabled
- Required pull request reviews on `main`: 1 approval
- Dismiss stale reviews: enabled
- Enforce admins: enabled
- Force pushes: disabled
- Branch deletions: disabled
- SECURITY policy recognized by GitHub: yes

## Local release-prep verification on 2026-04-13 (branch `release/oss-prep-2026-04-13`)

- `./scripts/test-openburnbar-swift.sh` passed
- `./scripts/test-openburnbar-app.sh` passed (781 tests, 1 skipped, 0 failed)
- `./scripts/test-openburnbar-retrieval-evals.sh` passed (replay golden suites)
- `./scripts/test-openburnbar-ts.sh` passed (287 tests, 0 failed)
- `./scripts/test-openburnbar-replay-evals.sh` passed
- `./scripts/test-openburnbar-extension-host.sh` passed
- `make build` passed (Release app bundle + embedded daemon helper artifacts)
- Embedded helper daemon health probe against the built app responded `ok: true`
- `npm --prefix extensions/openburnbar audit --json` reports 0 vulnerabilities after pinning transitive `vite` via overrides
- Release hygiene cleanup applied:
  - updated `THIRD_PARTY.md` to match bundled logo asset usage
  - removed tracked generated validation `.log` artifacts
  - removed tracked local Cursor planning artifact under `.cursor/plans/`
  - added ignore rules to prevent those local/generated artifacts from being re-committed

### Follow-up required before tagging

- `npm --prefix extensions/openburnbar run test:cursor-smoke` timed out in this local environment and still needs a successful run on a known-good Cursor automation host before final sign-off.

## Confirmed from working tree on 2026-04-02

### Community files (.github/)
- [x] `CODEOWNERS` — defines ownership for AgentLens/, OpenBurnBarCore/, OpenBurnBarDaemon/, extensions/
- [x] `ISSUE_TEMPLATE/bug_report.md` — bug report form with version, component, steps to reproduce
- [x] `ISSUE_TEMPLATE/feature_request.md` — feature request form with problem/solution template
- [x] `PULL_REQUEST_TEMPLATE.md` — PR checklist with testing, breaking change, documentation sections
- [x] `SECURITY.md` — private vulnerability reporting path, security best practices

### CI/CD workflows (.github/workflows/)
- [x] `openburnbar-pr-harness.yml` — PR validation: Swift tests, app tests, retrieval evals, TS tests, replay evals, extension-host tests
- [x] `release.yml` — tagged source release: verifies the source tree and creates a draft source-only GitHub Release

### Dependency management
- [x] `dependabot.yml` — configured for npm (extensions/openburnbar), Swift (OpenBurnBarCore, OpenBurnBarDaemon), and GitHub Actions

## Confirmed from registry/package metadata on 2026-04-04

- npm package name `openburnbar`: not present in the public npm registry at the time of check
- VS Marketplace item `openburnbar.openburnbar`: not present (`404`) at the time of check
- Annotated source-release tag on remote: `v0.1.0-beta`

## Re-check snapshot on 2026-05-08

- GitHub Dependabot API reports 0 open alerts on the default branch after PR #45 landed the `fast-xml-builder@1.2.0` transitive override for Functions.
- Current commercial-launch privacy review found `docs/PRIVACY.md` needed to disclose paid Firestore chat/session backup, iCloud mirroring, hosted quota credentials, Secret Manager, and App Store entitlement behavior.

## Still needs manual confirmation before public launch

- [ ] After the repository is public, enable private vulnerability reporting in repository settings (GitHub documents this as a public-repository feature)
- [ ] After the repository is public, verify secret scanning is active; for a user-owned free public repo GitHub runs secret scanning automatically
- [ ] After the repository is public, enable code scanning if the public-repo settings expose it, or document the plan/visibility limitation if GitHub does not
- [ ] Whether all current vulnerability alerts have been reviewed, remediated, or explicitly accepted for launch
- [ ] Whether wiki should remain enabled
- [ ] Whether Discussions should remain enabled

## Action required at launch time

- [ ] Confirm the existing annotated tag `v0.1.0-beta` is the intended first public source-release milestone for repo `Ajnunezg/BurnBar`

## Before the next tagged release beyond `v0.1.0-beta`

- [ ] Re-review unexpected local source changes and any mid-audit edits to confirm they are intentional to ship
- [ ] Naming and trademark clearance for broader public distribution under the name `OpenBurnBar`
- [ ] Consider reserving npm package name `openburnbar` if not already taken
- [ ] Consider setting up a GitHub Pages site for documentation if wiki is disabled
