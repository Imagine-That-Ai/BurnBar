# Fork PR CI parity

Pull requests from forks run a **degraded** CI matrix compared to same-repo PRs and pushes to `main`.

## Same-repo PRs and pushes (`INTERNAL_RUN=true`)

- Firebase config injection (macOS + Android when secrets are present)
- App Check config smoke
- Diff coverage hard-fail (requires xcresult + `openburnbar-coverage.json`)
- Commercial launch gate (`node scripts/commercial-launch-gate.mjs`) when `APP_STORE_ASC_*` secrets are configured in GitHub Actions
- Full Android Firebase config when `GOOGLE_SERVICES_JSON_BASE64` is available

## Fork PRs (`INTERNAL_RUN=false`)

- Dummy Android `google-services.json` so Gradle resolves the Firebase plugin
- No injected macOS Firebase plist or App Check debug token
- Diff coverage and commercial launch gate steps are skipped
- Auth-dependent integration surfaces may run without real Firebase credentials

**Do not treat a green fork PR as equivalent to a green internal PR.** Maintainers should run the full harness on a same-repo branch (or merge queue) before release.

Optional future improvement: label-gated `pull_request_target` full matrix for maintainer-approved fork contributions.
