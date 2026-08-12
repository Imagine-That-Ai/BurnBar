# Windows parity — Alberto's exact checklist

**Date:** 2026-07-08
**Last refreshed:** 2026-08-11
**Historical context:** The agent lanes drove the Windows port from ~40% to
~55% honest parity during the 2026-07-06 session. The original prerequisite
list is retained below; use the refreshed current-status section for the work
that still needs Alberto.

## Current status - 2026-08-11

This checklist is retained as the original external-prerequisite runbook. Its
July 8 blocking state has materially advanced.

The simple current result is:

- **Code parity is done:** commit
  `8b07625eebe9db0bf0084e6a884becd6d8bcc72e` has 51/51 `Real` parity rows. That
  is the commit the measurement was taken on, not a standing claim about `main`;
  later commits land on top of it, so the gates are re-run at the new `main`
  head before any candidate is tagged.
- **Automated Windows proof is done:** the exact source passed 65/65 local
  certification commands plus hosted x64, ARM64, engine, candidate-export,
  distribution, MSIX, security, and shared-domain gates.
- **The staging infrastructure deployment is done:** run
  [31439802683](https://github.com/Imagine-That-Ai/BurnBar/actions/runs/31439802683)
  deployed exact candidate
  `0b8c208537bcf7786ff43370ffb28d0d4becb0f4` to `burnbar-staging` with
  Hosting off and exactly the four approved Functions. All four are active,
  identify that candidate, and deny anonymous calls with HTTP `401`.
  Production and Hosting stayed unchanged.
- **Release certification is not done:** there is no signed
  `windows-v1.0.39` release candidate yet. Five blocking external receipt
  groups are still open — physical x64 performance, accessibility/display,
  the signed-in OAuth/App Check/physical TPM/CloudVault staging protocol,
  paired media/Computer Use safety, and Store/update lifecycle. Physical ARM64
  is open too, but it does not block: it may ship as a clearly stated beta
  limitation. The honest verdict is **NO-GO**.

**Nothing public ships before certification.** Pushing the `windows-v1.0.39` tag
signs the candidate *and* publishes a public GitHub Release in one run unless
the publication job is held first, so the order below puts the public release
last.

What Alberto needs to approve or provide next, in order:

1. **Hold the publication gate before the tag exists.** Settings → Environments
   → `windows-release` → add a required reviewer. Verified 2026-08-11, that
   environment has no protection rules at all, so one tag push would sign and
   publish with no second approval. With a reviewer, signing and publication
   each need their own approval.
2. After release engineering rebinds the final candidate to then-current
   `main` and re-runs the candidate gates, separately approve creation and push
   of protected tag `windows-v1.0.39`, then approve the `build-sign` deployment
   only. That yields the signed candidate as a private workflow artifact and
   publishes nothing. PR approval and the completed staging deployment do not
   authorize the tag.
3. Make the physical Intel x64 Windows laptop and paired Mac/iPhone available
   for performance, accessibility/display, media, Computer Use, panic, and
   safety protocols against that private signed candidate. The signed-in
   staging protocol on this machine must cover OAuth, App Check, physical TPM,
   CloudVault, offline recovery, revocation, sign-out, and fixture restoration.
4. Explicitly authorize a private Partner Center flight after the signed
   physical x64 candidate passes.
5. Only once 3 and 4 have passed, approve the held publication deployment. That
   approval is what publishes the public GitHub Release. The tag approval, the
   `staging` Environment prompt, and the private-flight authorization are each a
   different decision and none of them is this one.
6. Provide physical ARM64 Windows hardware, or retain ARM64 as a clearly stated
   beta limitation. This item does not block the release.

If item 1 is skipped there is no private signing path, and the tag push is
itself the public release. In that case the tag waits until items 3 and 4 have
passed, and no candidate is ever tagged on the assumption that the release can
be deleted afterwards.

The older sections below explain how the original prerequisites were created.
Use the current
[`WINDOWS_PORT_OPERATIONS_RUNBOOK.md`](WINDOWS_PORT_OPERATIONS_RUNBOOK.md) for
the live sequence and current candidate identity.

The lettered sections below are ordered by urgency (lead time), not effort. The
numbered list above is the release order and takes precedence.

---

## B. Start the code-signing certificate TODAY (has multi-day lead time)

Blocks: Wave 5 entirely — without it there is no installable Windows app (W0).

**Recommended: Azure Trusted Signing** (~$9.99/mo, no key custody, signs from
GitHub Actions using the repository's approved release-workflow auth path):

1. portal.azure.com → search **Trusted Signing Accounts** → Create (Basic SKU,
   East US or West Europe).
2. Inside the account → **Identity validation** → New → Organization
   (Imagine That AI legal details). Validation takes ~1–5 business days —
   this is the long pole, start it first.
3. When validation completes → **Certificate profiles** → New → Public Trust.
4. Tell the agents the account/profile names after validation. They wire
   `openburnbar-release-windows.yml` to `azure/trusted-signing-action` using
   the current workflow credential model; no private key ever exists locally.

Fallback if Azure identity validation fails: OV Authenticode from SSL.com with
eSigner cloud signing (~$300/yr). EV (~$500/yr) buys instant SmartScreen
reputation; OV builds it over downloads.

**Your time: ~15 min + waiting on validation.**

---

## A. One Windows 11 ARM64 VM with SSH (the single biggest unlock)

Blocks: R14 TPM App Check proof (last named kill-risk), C5 live E2EE
Windows↔Mac round-trip, computer-use loop, 60fps ARM64 GPU spike (WINUI-017),
every PLACEHOLDER evidence item in the certification bundle §5.

Your part is only steps 1–4; agents drive everything after over SSH.

1. Create a **Windows 11 ARM64** VM on the Mac. Parallels Desktop is easiest
   (its Win11 install enables a **vTPM** automatically — required for the TPM
   attestation proof). UTM/VMware Fusion fine too if TPM is enabled.
2. In the VM, enable SSH (PowerShell **as admin**):
   ```powershell
   Add-WindowsCapability -Online -Name OpenSSH.Server~~~~0.0.1.0
   Set-Service sshd -StartupType Automatic
   Start-Service sshd
   ```
3. Install git and clone the repo:
   ```powershell
   winget install --id Git.Git -e
   # then in a new terminal, with a GitHub PAT or gh auth login:
   git clone https://github.com/Imagine-That-Ai/BurnBar C:\src\BurnBar
   ```
4. Install an SSH public key for agent access, then share only the VM IP and
   username. Use a temporary password only for your own bootstrap if needed, and
   remove password auth once key login works. Test from the Mac:
   `ssh <user>@<vm-ip>` must land in a prompt.

Agents then (no action from you): install .NET 10 SDK / VS Build Tools / Rust /
Swift over SSH, run
`pwsh scripts/windows-port/vm-validate.ps1 -RepoRoot C:\src\BurnBar`,
and drive the C2–C6 evidence lanes (TPM/App Check evidence, Win2D 60fps, SendInput/UIA loop,
E2EE seal→open vs the Mac, FFI msvc loopback), committing evidence to
`docs/windows-port/evidence/`.

**Your time: ~30–40 min (mostly Windows installing itself).**

---

## E. Four GitHub/infra switches (minutes each; two are "say go" for an agent)

1. **WS-A2 — make the required-safe Windows aggregate required on `main`.**
   First land the workflow change that publishes `PR Windows Full Gate` on every
   PR, including non-Windows path-filtered PRs. Then Settings → Branches →
   main → require status checks → add `PR Windows Full Gate`. *(An agent can do
   this via `gh api` on your word after the gate is required-safe.)*
2. **Issue #1277 — production environment rejects `v*` tags.**
   Settings → Environments → `production` → Deployment branches and tags →
   add rule allowing `v*` tags. *(Also agent-doable on your word.)*
   This un-reds `deploy-functions` + Cloud Run, failing since v1.0.29.
3. **Issue #1278 — Factory/droid exec failing in CI.**
   Log into the Factory dashboard → regenerate the API key → update repo
   secret `FACTORY_API_KEY`. (Verify glm-5.2 model access on the account.)
4. **Issue #1276 — App Check smoke needs authenticated gcloud in CI.**
   Decision + credential: provision a minimal read-only GCP service account
   (or Workload Identity Federation) for
   `scripts/ops/verify-firestore-app-check-enforcement.sh`. An agent can draft
   the exact `gcloud` commands for you to approve.

---

## D. Google OAuth client for Windows sign-in (~5 min)

Blocks: real (non-dev-token) Firebase sign-in on Windows
(`DesktopOAuthLoopbackFlow` is built and waiting).

1. console.cloud.google.com → select the BurnBar Firebase project →
   APIs & Services → Credentials → **Create credentials → OAuth client ID**.
2. Application type: **Desktop app**. Name: `OpenBurnBar Windows`.
   (Desktop type auto-allows the `http://localhost` loopback redirect — no
   extra config.)
3. Add the client ID, client secret, and Firebase Web API key as repo or
   environment secrets. Do not paste OAuth secrets into chat or agent prompts;
   agents wire configuration + CI naming from secret names only.

---

## C. Microsoft Partner Center account (~15 min + $19/$99)

Blocks: Microsoft Store submission. (winget needs **no** account — agents PR
`microsoft/winget-pkgs` once a signed installer exists. Chocolatey optional.)

1. partner.microsoft.com → Dashboard → Register → **Company** account
   (matches the signing-cert identity) — $99 one-time ($19 if individual).
2. Reserve the app name `OpenBurnBar`.

---

## F. Daemon strategy is already decided

WPD-0006 already chose **per-capability Tier-C substitution** (no monolithic
daemon port for v1). No new Alberto decision is needed here; agents should
continue executing the WPD-0006 substitution matrix and the remaining Wave 4
items.

---

## What happens after each item

| You do | Agents then finish |
|---|---|
| A (VM + SSH) | R14 TPM proof, C5 E2EE round-trip, computer-use loop, 60fps spike, all §5 evidence |
| B (cert) + C (Partner Center) | Signed MSIX in CI, Store/winget/choco submissions, update round-trip → **G5** |
| D (OAuth client) | Real Windows sign-in end-to-end, retire dev-token flow |
| E (4 switches) | Green `main`, Windows CI blocking, factory lanes restored |
| F (already decided: Tier-C substitution) | Wave 4 daemon execution continues |

Everything else on the road to 100% is agent-executable once these land.
