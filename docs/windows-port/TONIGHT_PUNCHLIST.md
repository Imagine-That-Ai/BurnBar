# Windows Parity — Alberto's Hardware/Account Punch-List

**Date:** 2026-07-06
**Context:** Agent work has taken the Windows port from ~40% → ~55% by completing the portable-logic + live-data-seam layer (16 PRs merged this session). Everything remaining that agents CANNOT do falls into two buckets: **(C)** needs the Win11 Pro VM or real hardware, **(D)** needs your accounts/credentials. This is the exhaustive list, ordered by leverage.

Companion: [`PARITY_100_REMEDIATION_PLAN.md`](PARITY_100_REMEDIATION_PLAN.md) (full plan), [`PARITY_CERTIFICATION_BUNDLE.md`](PARITY_CERTIFICATION_BUNDLE.md) (evidence ledger).

---

## Bucket C — the Win11 Pro ARM VM (tonight)

The VM (`WIN-MIGC91I3AKQ`, Apple Virtualization, ARM64) unblocks all of these. **First step: give the agent SSH access** (see [§ SSH setup](#ssh-setup) below), then it can drive most of this itself.

| # | Item | Why it's bucket-C | Once the agent has SSH, it can… | Blocks |
|---|---|---|---|---|
| C1 | **Build the full WinUI app + run the whole Windows test suite** | XamlCompiler is Windows-only (drift D3); the 7 `net*-windows` projects can't build on macOS | Run `scripts/windows-port/vm-validate.ps1` — `dotnet build OpenBurnBar.sln` + `dotnet test` on real ARM64. Validates ALL the XAML pages + net8.0-windows adapters we've been deferring to CI. | G3 render proof |
| C2 | **TPM App Check (R14) — the last named kill-risk** | `NCryptCreateClaim` needs real TPM silicon; the VM has a virtual TPM 2.0 (Win11 requires it) | Run the mint client against the VM's vTPM → prove enforced callable clears firebase-admin. Retires R14. Portable mint client + loopback tests already landed. | Live cloud certification |
| C3 | **Win2D 60fps particle spike (WINUI-017)** | GPU render + frame-rate measurement needs a GPU | Build the Win2D host, run the 30-substrate swarm, measure fps on ARM64. **Mandatory G3 sub-gate.** | G3 |
| C4 | **Computer-use full loop** | SendInput/UIA/Graphics.Capture/ViGEm drive the real desktop | Exercise the input/capture/kill-switch loop end-to-end on the VM desktop. | G4 |
| C5 | **Live E2EE round-trip (C5)** | Needs Windows-seal → Mac-open across two machines | Seal a payload on the VM, open it on this Mac (vectors already prove byte-parity; this is the live confirmation). Retires the C5 deferral. | G2 cloud criterion |
| C6 | **FFI-008 — native shim msvc loopback** | The 13 real FFI round-trips ran on macOS dylibs; the msvc-runtime run needs a Windows cargo step | Build the Rust crates on the VM, run the same loopback tests → green on Windows. | Native-shim full proof |
| C7 | **Launch-evidence screenshots (bundle §5)** | Every §5 row is a PLACEHOLDER; needs real screenshots of running surfaces | Screenshot each surface (dashboard, quota, chat, settings, pet…) running with real data on the VM. | G5 evidence |

**The efficient path:** items C1, C5, C6 the agent can fully self-drive over SSH. C2, C3, C4, C7 the agent drives but you'll want to eyeball the results (fps numbers, TPM enforcement, screenshots).

---

## Bucket D — your accounts & one-time approvals

| # | Item | What to do | Blocks |
|---|---|---|---|
| D1 | **Authenticode / Azure Trusted Signing cert (W0)** | Obtain a code-signing cert (Azure Trusted Signing is the modern path; ~$10/mo, or an EV cert). Add its secrets to the repo's Actions secrets. | **All of G5** — no signed MSIX, no shippable installer, no auto-update round-trip without it |
| D2 | **Microsoft Store + winget publisher accounts** | Register a Partner Center account (Store) + confirm the winget-pkgs PR path. Publisher id is already `ImagineThat` in the manifests. | Store/winget distribution |
| D3 | **Flip `pr-windows-full` to a required check (WS-A2)** | GitHub → Settings → Branches → main protection → add "PR Windows Full Gate" to required checks. **This ends the admin-merge era** — once required + green history exists, Windows PRs merge normally. | Trustworthy Windows CI gating |
| D4 | **Real Google OAuth client + Firebase Web API key** | Create a **Desktop-type** OAuth client (the committed plist is iOS-type; the loopback flow wants a Desktop client) + grab the Firebase Web API key. Add as Actions secrets. | The OAuth flow's real-endpoint CI proof (the portable flow + fake-server tests already landed in #1304) |

---

## SSH setup

In the Win11 VM, open **PowerShell as Administrator** and paste:

```powershell
Add-WindowsCapability -Online -Name OpenSSH.Server~~~~0.0.1.0
Start-Service sshd
Set-Service -Name sshd -StartupType Automatic
New-NetFirewallRule -Name sshd -DisplayName 'OpenSSH Server' -Enabled True -Direction Inbound -Protocol TCP -Action Allow -LocalPort 22
ipconfig | Select-String IPv4   # note the 192.168.64.x address
```

Then give the agent: **the IPv4 address**, **your Windows username**, **your password**. The agent runs `scripts/windows-port/vm-validate.ps1` first to confirm the toolchain and build the solution.

**Toolchain the VM needs** (the agent will check and report what's missing): .NET 10 SDK, Visual Studio 2022 Build Tools (or VS) with the Windows App SDK / WinUI workload, the Windows 10 SDK 10.0.19041+, Rust (for C6), and the Swift-for-Windows toolchain (for the engine C-ABI DLL, if we validate that too).

---

## Your separate track: physical phone

You mentioned physical-phone work tonight — that's the iOS/Android device validation (Signal relocation, live cross-device flows) tracked separately from this Windows-parity goal. Not blocked by anything here; just noting it's its own lane.

---

## What "done" looks like after tonight

If C1–C7 pass on the VM and you close D1–D4, the port reaches **G2 fully certified + G3/G4 validated + G5 shippable** — i.e. a signed, installable, auto-updating OpenBurnBar for Windows with a complete evidence bundle. That's the 100%. The agent will drive every VM item it can over SSH and hand you back only the eyeball-and-approve results.
