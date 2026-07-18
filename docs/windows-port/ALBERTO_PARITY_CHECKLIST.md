# Windows parity — Alberto's exact checklist

**Date:** 2026-07-08
**Context:** The agent lanes drove the Windows port from ~40% to ~55% honest parity
(21 PRs, 2026-07-06 session) and hit the agent ceiling (~65%). Everything below is
the complete set of items only Alberto can do. Each unblocks a named wave of
agent-executable work; nothing here requires writing code.

## Current status - 2026-07-18

This checklist is retained as the original external-prerequisite runbook. Its
July 8 blocking state has materially advanced:

- **B - complete:** Azure Artifact Signing identity validation and the public
  trust certificate profile are active. The exact `windows-v1.0.37` x64 and
  ARM64 release completed with Authenticode and RFC 3161 verification.
- **C - account complete, lifecycle open:** the Imagine That AI LLC Store
  developer account is verified and `BurnBar` is reserved as Store product
  `9PKMSDP99CJ6`. The controlled private submission and Store/update lifecycle
  protocol have not been promoted to PASS.
- **D - configuration complete, live proof open:** the Windows OAuth client ID
  and Firebase API key are configured as repository variables. End-to-end
  OAuth, App Check, TPM, and CloudVault certification still requires deployed
  `burnbar-staging` services.
- **A - VM validation complete:** the exact `windows-v1.0.37` ARM64 MSIX
  lifecycle, portable launch, and 25/25 UIA route/scenario rerun passed under
  UTM. This does not count as physical ARM64 certification.
- **Physical x64 completed, candidate failed:** the exact v1.0.37 Intel run
  passed signature, lifecycle, soak, and evidence validation but returned
  **NO-GO** because native backdrop surfaces covered the Providers/dashboard
  content and compact/accessibility defects remained. PR #1854 contains the
  source remediation; v1.0.37 must not be submitted or promoted.

The current operator actions are therefore narrower: wait for PR #1854 and a
new signed candidate, rerun that successor on the physical Intel x64 laptop,
finish the isolated staging protocols, and authorize a non-public Partner
Center submission only after the replacement candidate passes local physical
gates. Physical ARM64 remains an explicit beta limitation until qualifying
hardware exists.

Ordering is by urgency (lead time), not effort.

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
