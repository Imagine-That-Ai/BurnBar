# OpenBurnBar — Documentation, Claims, and Trust Specialist Review

**Date:** 2026-06-01
**Reviewer:** Documentation, Claims, and Trust subagent (second-opinion)
**Scope:** Public-facing security/privacy claims, in-app copy, README, pricing pages, marketing pages, threat model availability, responsible-disclosure posture, trust center surface, supply-chain transparency posture, and the language that ties them together.
**Inputs reviewed:** `website/CLAIMS.md`, `website/src/data/*.ts`, `website/src/pages/{index,security,privacy,floo,control,product,benefits,pricing,download,faq,support,mcp,legal/privacy-policy}.astro`, `README.md`, `SECURITY.md`, `.github/SECURITY.md`, `docs/THREAT_MODEL.md`, `docs/security/{LLM_GENAI_AGENT_THREAT_MODEL,PRIVILEGED_INPUT_THREAT_MODEL,PRIVILEGED_SOCKET_AUTH,SUPPLY_CHAIN_PROVENANCE}.md`, `docs/PRIVACY.md`, `firebase.json`, `website/public/robots.txt`, `security-review-2026-06-01/SECURITY_CLAIMS_REWRITE.md`, `security-review-2026-06-01/SOTA_GAP_ANALYSIS.md`, and the prior executive summary / findings register.

**Pre-existing review reference:** This work builds on `security-review-2026-06-01/SECURITY_CLAIMS_REWRITE.md` (precise-wording recommendations) and `security-review-2026-06-01/SOTA_GAP_ANALYSIS.md` (frameworks gap). The artifact below identifies *new* issues those did not name, maps every public claim to the public surface that carries it, and produces drafts for the missing trust surfaces (security.txt, VDP, trust page, security.txt). It does not duplicate the line-level copy rewrites.

---

## 1. Executive Summary (this subagent's view)

OpenBurnBar's *internal* security documents (`docs/THREAT_MODEL.md`, `docs/security/*`, `SECURITY.md`, the May 2026 SOTA remediation plan) are unusually self-critical and well-structured. The *public* security surface, however, is significantly out of step with the internal reality. Three patterns cause the drift:

1. **Aspirational overclaims shipped in marketing.** The website and README use absolute or near-absolute language ("end-to-end encrypted", "we can't read it", "tamper-proof", "no one in the middle", "encrypted end to end", "encrypted history") that the internal threat model and the SOTA gap analysis explicitly qualify or contradict (relay metadata exposure, app-layer Iroh authz gap, attestation-binding coverage, Cloud Relay cost/metadata, MAS build shipping without Computer Use, opt-in settings that change behavior).
2. **The trust surface is half-built.** The repo has a competent `SECURITY.md` and a deep `docs/THREAT_MODEL.md`, but it ships no `/.well-known/security.txt`, no public VDP URL, no status page, no public trust center, no bug bounty, and the threat model is published only as a developer doc, not as a customer-readable summary. A user has no single, durable, public page that lists what OpenBurnBar does, what it doesn't, who reviews it, and how to report a problem.
3. **In-app and on-website claims are not version-controlled as a claims matrix.** `website/CLAIMS.md` exists and is excellent — but it lives next to the marketing site as an internal artifact; nothing on the public site links to a public version, and there is no gate that prevents a marketing change from drifting away from the matrix.

**Most consequential issues (independent of the prior review):**

- **No `/.well-known/security.txt` and no public VDP URL.** RFC 9116 / Google Project Zero norms require both. This is a launch blocker for any product with the agent-control / Iroh / Hermes surface.
- **"End-to-end encrypted" used without qualification on Floo, Hermes Remote Relay, the MCP page, the home page, the FAQ, and the Cloud Pro pricing card.** Internal docs (and the prior SOTA gap) are explicit that the relay can observe NodeIds, timing, and volumes; that browser-relayed flows incur cost; that app-layer authz on top of Iroh is partially landed; and that the Hermes Remote Relay WebSocket relies on a relay infrastructure we operate.
- **"Tamper-proof record" used as a marketing absolute.** Internal wording is "tamper-evident" with explicit completeness caveats (max-index + exported artifacts + verifier). The capability deck and FAQ are using the stronger word.
- **Threat model and security policy are developer-readable, not customer-readable.** The site has a `/security` page that reads well but does not link to the full threat model, the privileged-input threat model, the supply-chain provenance doc, or the public responsible-disclosure channel. There is no public trust center.
- **Pricing and plan copy state the security property without a backing link.** "Encrypted history" and "server-verified entitlement" appear as feature bullets with no "/security" link from the plan card itself.
- **In-app copy not reviewed.** Per `project_website_copy_policy` the site avoids transport names; the on-website copy is now mostly disciplined. We did not have access to the in-app `Localizable.strings` / on-boarding surfaces, but the same disciplined language is needed there.
- **The brand trademark is "OpenBurnBar" but the security page title and FAQ talk about "Imagine That AI LLC".** The trust footer is correct; the headline entity on `/security` is not. Low severity but worth a one-line alignment.

**What's already strong (evidence):**

- `docs/THREAT_MODEL.md` and the new `docs/security/PRIVILEGED_INPUT_THREAT_MODEL.md` and `docs/security/SUPPLY_CHAIN_PROVENANCE.md` are detailed, evidence-anchored, and self-critical — they flag relay metadata, the in-process CGEvent path residual, the WS2 capability-token gap, and same-UID local risks openly.
- `SECURITY.md` (both copies) is honest about no formal SLA and routes to GitHub private vulnerability reporting first.
- The `/security` page is structured as "what we defend" + "what we don't pretend" — the right shape, but the language in the "don't pretend" section doesn't yet match the strongest overclaim in the marketing copy.
- The `/privacy` page is one of the better privacy pages in the local-first tool space (three-zone diagram, opt-in list, deletion paths, every opt-in named).
- The pricing page has a "boring, important details" section that walks through billing, refunds, top-ups, and cancellations — a useful template for what the security page should also have.
- `firebase.json` has a strong default CSP, HSTS, Referrer-Policy, X-Frame-Options, and a no-CSP-loosening posture for the marketing site. This is rare and worth saying out loud on the security page.

---

## 2. Map of Public Security Claims (verbatim, with source)

Every claim below appears on a public surface today. They are grouped by surface, with the language that ships. The §4 "Overclaim List" calls out which ones need qualification.

### 2.1 Home page (`/`) — `website/src/pages/index.astro`

| Line | Verbatim text | Line# |
|---|---|---|
| "0 telemetry, analytics, or crash reports out of the box" | band stat | index.astro:147 |
| "No telemetry by default" / "No account required" / "Reads logs, not your API keys" | hero attest | index.astro:114-117 |
| "Reach the Mac's Hermes from anywhere over an end-to-end-encrypted WebSocket. Paid-tier; relay never sees plaintext." | Hermes section | index.astro:403-404 |
| "Only your own devices. Encrypted end to end. You approve every connection." | Floo companion card | index.astro:532 |
| "sync, encrypted history, agent memory" | Cloud pricing teaser | index.astro:634 |
| "Encrypted project memory and assistant history" | Cloud pricing teaser | index.astro:641 |
| "By default, OpenBurnBar collects nothing." | trust section H2 | index.astro:562 |
| "All processing happens on your device. No telemetry, no analytics, no crash reports — nothing is transmitted unless you explicitly opt in." | trust lead | index.astro:563-566 |
| "Your API keys never leave the providers you already trust" (quoted) | trust blockquote | index.astro:589-590 |
| Link to `/privacy` and `/security` exists but is one of two ghost buttons in a small footer | index.astro:580-583 |

### 2.2 Privacy & trust (`/privacy`) — `website/src/pages/privacy.astro`

| Claim | Line# |
|---|---|
| "By default, OpenBurnBar collects nothing." (H1) | privacy.astro:14 |
| "All processing happens on your device. No telemetry, no analytics, no crash reports leave the device unless you explicitly opt in. Every opt-in is a separate switch and behaves like one." | privacy.astro:17-20 |
| Three trust zones diagram (Zone A: your Mac; Zone B: Apple iCloud; Zone C: Firebase/GCP) | privacy.astro:25-126 |
| "Firestore stores only the redacted label" (for hosted credentials) | privacy.astro:106 |
| "Cloud Run · Hermes relay routes encrypted frames; never sees plaintext request or response bodies" | privacy.astro:113-114 |
| "Frames are end-to-end encrypted from OpenBurnBar's perspective — the relay never receives plaintext." (Hermes opt-in) | privacy.astro:195-196 |
| "Anonymized crash reports are sent to Sentry. User identifier is a SHA seed derived from bundle id and full user name — not direct PII." (Sentry opt-in) | privacy.astro:201-203 |
| Links at bottom to `docs/PRIVACY.md`, `docs/THREAT_MODEL.md`, `firestore.rules` | privacy.astro:258-275 |

### 2.3 Security model (`/security`) — `website/src/pages/security.astro`

| Claim | Line# |
|---|---|
| "A defensive product, not a hardened castle." (H1) | security.astro:13 |
| Top-5 threats + mitigations: socket ACL + token, Keychain, Firestore rules + App Check + denylist, JWS pinned CAs, ECIES escrow | security.astro:30-91 |
| "What we don't pretend" section enumerates: direct-download app is not sandboxed, no provider-API pinning, Cursor connector routes through Cloudflare, iCloud uses Apple ID, App Check enforced at launch-time, Sentry anonymization is a hash, not "no PII" | security.astro:97-130 |
| Provenance: signed and notarized; SHA-256/512; optional GPG-signed checksum; SPDX SBOM; release-metadata JSON | security.astro:140-154 |
| "Email privacy contact; please don't open public GitHub issues for active vulnerabilities." | security.astro:163-176 |
| **No link to** the canonical `SECURITY.md`, the threat model public summary, the responsible-disclosure email/security.txt, a status page, or a bug-bounty program. |  |

### 2.4 Floo (`/floo`) — `website/src/pages/floo.astro`

| Claim | Line# |
|---|---|
| "End-to-end encrypted, only your own devices, you approve every connection." (meta description) | floo.astro:32 |
| "Your phone and your Mac, joined." (H1) | floo.astro:37 |
| "It only ever connects you to you." (safe-by-design H2) | floo.astro:81 |
| "{FLOO.name} is for your devices and no one else's. The connection is private end to end — and that includes us. We built it so we couldn't peek even if we wanted to." | floo.astro:83-85 |
| FLOO_PROMISES array (rendered on the page) — `capabilities.ts:90-95`: <br/>• "It only ever connects your own devices — the ones you've paired and trust."<br/>• "Everything between them is end-to-end encrypted. **No one in the middle can read it, and that includes us.**"<br/>• "Every connection asks first. Decline and it backs off."<br/>• "One tap ends it — the screen view, the call, the control, all of it, instantly." | capabilities.ts:90-95 |
| FLOO unlock capability blurb: "Walk up to a locked Mac and unlock it from your phone with Face ID or Touch ID. Your password is sealed end to end — it never appears in a log, a server, or anywhere you didn't put it." | capabilities.ts:82-86 |

### 2.5 Agent Control (`/control`) — `website/src/pages/control.astro`

| Claim | Line# |
|---|---|
| Meta description: "let an OpenBurnBar agent click, type, and work your apps — only with your explicit permission, only within limits you set, with a tamper-proof record and an instant stop." | control.astro:23-24 |
| "A tamper-proof record of everything" (capability card title) | capabilities.ts:144 |
| "Every action the agent takes is written to a record that can't be quietly edited after the fact. You can always see precisely what happened." | capabilities.ts:144-147 |
| CONTROL_PROMISES (`capabilities.ts:151-156`): "It does nothing until you grant it — and you grant powers per task, not forever."; "Grants expire on their own; switch tasks and the reach resets to zero."; "Stop it instantly — a keyboard shortcut, a gesture on your phone, or the moment the lock screen appears."; "The Mac App Store build ships without it entirely. This lives only in the direct download." | capabilities.ts:151-156 |

### 2.6 Pricing (`/pricing`) — `website/src/pages/pricing.astro` + `data/site.ts`

| Claim | Line# |
|---|---|
| "Encrypted session history, searchable everywhere" (Cloud feature bullet) | pricing.astro:168 |
| "Verified entitlement — checked server-side" (Cloud feature bullet) | pricing.astro:170 |
| "Tamper-proof action record · per-task grants" (Cloud Pro feature bullet) | pricing.astro:255 |
| "Cloud Pro allowance — 500 hosted actions and 50 relay-accounting GB monthly" (and 2000/300 caps) | pricing.astro:261-263; site.ts:53-58 |
| Top-ups: 100 hosted actions / 50 relay GB for $4.99 each | pricing.astro:278-290; site.ts:61-75 |
| "Cloud Pro includes 500 hosted Agent Control actions and 50 relay-accounting GB each month… hosted work pauses instead of silently spending more." | pricing.astro:333-337; 286-290 |
| Pricing page does **not** link to `/security` or to a trust page from any of the security-adjacent plan bullets. |  |

### 2.7 FAQ (`/faq`) — `website/src/data/faq.ts`

| Claim | Line# |
|---|---|
| Floo Q&A: "It only ever connects your own paired devices, and everything between them is end-to-end encrypted — **no one in the middle can read it, and that includes us.**" | faq.ts:193 |
| Agent Control Q&A: "Every action is written to a **tamper-proof record.** Grants are per task and expire on their own." | faq.ts:200 |

### 2.8 MCP (`/mcp`) — `website/src/pages/mcp.astro`

| Claim | Line# |
|---|---|
| "BurnBar Pro feature with **encrypted, multi-device session memory.** The stdio shim closes the [privacy loop]" | mcp.astro:662 |
| "encrypted title / snippet / body-preview envelopes" | mcp.astro:931 |
| "Connect Codex, Claude Code, Droid, Kimi, Forge, or any MCP client to **encrypted hosted session-memory search**." | mcp.astro:1063 |
| "Free, local, today — or **hosted, encrypted, multi-device**." (final H2) | mcp.astro:1135 |
| Tool descriptions: "Search **encrypted** OpenBurnBar hosted session memory. Sealed results require the local shim for decrypted previews." (burnbar_search_conversations) | mcp.astro:74 |
| "Hosted **encrypted** semantic search; query hashes derived locally, snippets decrypt locally." (burnbar_cloud_semantic_search_conversations) | mcp.astro:149 |

### 2.9 Legal / privacy policy — `website/src/pages/legal/privacy-policy.astro`

| Claim | Line# |
|---|---|
| "Cloud Pro phone-to-Mac relay traffic (**encrypted end-to-end from OpenBurnBar's perspective**)." | privacy-policy.astro:44 |
| "Provider keys live in the macOS Keychain with device-local accessibility. Hosted credentials, when used, live in Google Cloud Secret Manager. Firestore is gated by Firebase Auth, owner-scoped rules, App Check, and a secret-field-name denylist. App Store receipts are JWS-verified against pinned Apple root CAs." (Security §) | privacy-policy.astro:126-132 |

### 2.10 README.md

| Claim | Line# |
|---|---|
| "analytics stay local-first. No API keys, no account, no cloud — unless you *want* cloud." | README.md:14 |
| "Your API keys never leave the providers you already trust; OpenBurnBar just reads crumbs they dropped on disk." | README.md:62 |
| "Hosted Remote MCP for BurnBar Pro — paid users can connect coding agents to OpenBurnBar's hosted MCP endpoint for **encrypted** hosted session-memory search, with a local shim for stdio-only clients and device-side decrypt." | README.md:69 |
| "Optional at-rest encryption uses SQLCipher… the encryption key lives in the Keychain." | README.md:379 |
| "BurnBar Pro hosted session search stores **encrypted bodies** in Firebase Storage and sealed metadata plus opaque token/semantic hashes in Firestore; apps and explicitly configured MCP tools decrypt matches locally." | README.md:387 |
| "Chat titles, previews, and message bodies are uploaded only after enabling Settings → Privacy & Indexing → Back Up Chat Message Content and only when Firestore rules see an **active Apple-verified premium entitlement**." | README.md:387 |

### 2.11 Footer nav (`src/data/site.ts`)

| Link | Line# |
|---|---|
| `/security` (Security model) | site.ts:117 |
| `/mcp` (MCP integration) — labeled in footer but it leads to a security-heavy page; this is a discoverability win | site.ts:118 |
| `/legal/privacy-policy` (Privacy policy) | site.ts:119 |
| `/legal/terms` (Terms) | site.ts:120 |
| `SECURITY.md` (Security policy, external) | site.ts:135-138 |

### 2.12 In-app copy

- Not in scope of this artifact (no `Localizable.strings` reviewed in this pass). The website and README are in scope; the in-app on-boarding must follow the same rewrite rules. **Recommend re-auditing in-app strings before each store release.**

### 2.13 Internal documents (not public, but cited from `/privacy` + `/security`)

| Doc | Public link? |
|---|---|
| `docs/THREAT_MODEL.md` | Linked from `/privacy` and `/security` (no, see §3.3). |
| `docs/security/PRIVILEGED_INPUT_THREAT_MODEL.md` | **No public link.** |
| `docs/security/SUPPLY_CHAIN_PROVENANCE.md` | **No public link.** |
| `docs/security/LLM_GENAI_AGENT_THREAT_MODEL.md` | **No public link.** |
| `SECURITY.md` (root) | **No public link from `/security`.** Footer link only (`site.ts:135-138`). |
| `docs/PRIVACY.md` | Linked from `/privacy` and from policy page. |

---

## 3. Missing Public Trust Surfaces (independent findings)

These are the issues this subagent found that the prior security review and the SOTA gap analysis did not call out at the documentation/trust level.

### Finding D1: No `/.well-known/security.txt` at `burnbar.ai`

**Severity:** High (launch blocker for any product with the agent-control surface; required by Google / Project Zero / Mozilla security-team norm; expected by enterprise security reviewers).
**Evidence:** `find /Users/albertonunez/Documents/Windsurf/BurnBar -maxdepth 4 -name ".well-known"` returns nothing. `find … -name "security.txt"` returns only `SECURITY.md` files. `website/public/` does not contain a `.well-known/` directory. `firebase.json` has no `headers` rule for `/.well-known/security.txt`.
**Impact:** A security researcher hitting `https://burnbar.ai/.well-known/security.txt` gets 404. This is the canonical reporting channel; its absence erodes the trust posture and adds friction to the disclosure process. Most enterprise trust questionnaires will mark this as "missing."
**Fix:** Add `website/public/.well-known/security.txt` (drafted in §6.1 below) and re-deploy via `firebase deploy --only hosting:marketing`. Add a `headers` rule in `firebase.json` so it's `text/plain` with `Cache-Control: max-age=3600`. The redirect target must be `https://burnbar.ai/.well-known/security.txt`.
**Owner:** Website / Legal / Security.

### Finding D2: No public Vulnerability Disclosure Policy (VDP) / responsible-disclosure page

**Severity:** High.
**Evidence:** `SECURITY.md` (root and `.github`) instructs reporters to use GitHub private vulnerability reporting or to contact `@Ajnunezg` privately. There is no public URL on `burnbar.ai` that documents the disclosure process, expected response windows, safe-harbor language, out-of-scope categories, or coordinated-disclosure timelines. The `/security` page says "Email privacy contact… please don't open public GitHub issues" — it does not promise a coordinated disclosure process.
**Impact:** Researchers have no contract with the project about what will happen to their report, no safe-harbor from the CFAA / DMCA § 1201 / similar, and no published commitment to fix-and-credit. This is a 2026 norm and required by CISA's "Secure by Demand" guidance for any vendor with privileged-input surface.
**Fix:** Publish a public VDP at `https://burnbar.ai/security/disclosure` (or `/vdp`). The draft outline is in §6.2 below. A one-page summary should also be linked from the `/security` page and from `SECURITY.md` so the public-facing page and the developer-facing doc are aligned.
**Owner:** Security / Legal / Website.

### Finding D3: No public trust center; the threat model is developer-only

**Severity:** Medium.
**Evidence:** The full `docs/THREAT_MODEL.md`, the privileged-input threat model, and the supply-chain provenance doc are first-class. They are not linked from `/security`. The site has no `/trust`, `/security/trust`, or `/security/center` page. A customer reading the marketing site has no way to find a single canonical "what we defend, what we don't, who reviews it" page.
**Impact:** Customers and enterprise security reviewers cannot find a public summary of the threat model. Internal docs are deep, but the public surface doesn't summarize or link them. This forces each reviewer to either guess or open a support ticket.
**Fix:** Publish a trust center at `/security` (already exists — extend it) or a dedicated `/trust` page. §6.3 below has the outline. Must link to the developer-facing threat models, the SBOM, the VDP, the security.txt, the public status page, and the public changelog.
**Owner:** Security / Website.

### Finding D4: No public status page

**Severity:** Medium.
**Evidence:** No `status.burnbar.ai` or `burnbar.ai/status`. The Cloud Pro and Cloud tiers promise hosted services (Firestore sync, Hermes Remote Relay, Remote MCP, hosted quota refresh) but there is no public status or incident-history page. The `/support` page has a support email and the platform subscription links; it does not link to a status page.
**Impact:** When the relay, hosted search, or Remote MCP go down, users have no canonical "is it just me?" surface. For paid tiers this is a SaaS-trust expectation.
**Fix:** Stand up a status page (Firebase Status, statuspage.io, or a self-hosted alternative) and link it from `/security`, `/status`, and the footer. The trust center page (D3) should embed its current state.
**Owner:** Cloud / SRE / Website.

### Finding D5: No public bug bounty program

**Severity:** Medium.
**Evidence:** No reference to a bug-bounty program, a paid-bounty tier, a triage SLA, or a hall-of-fame in any public surface or in any internal doc reviewed.
**Impact:** A 2026 expectation for any product with an agent-control / privileged-input surface is at minimum a *named* responsible-disclosure program, even if it is invitation-only. A public "we don't have a paid bounty yet; here's our safe-harbor + triage commitment" is better than silence.
**Fix:** Decide on a posture: (a) launch with a public VDP + safe-harbor but no bounty, (b) launch with a HackerOne / Bugcrowd / Open Bug Bounty page, or (c) launch with an invitation-only program announced on the trust page. Document the choice on the trust page and link it from security.txt.
**Owner:** Security / Legal.

### Finding D6: README's security/privacy claims are not cross-linked to the canonical security model

**Severity:** Low.
**Evidence:** `README.md` makes the same overclaim language as the website (see §2.10) and does not link to `SECURITY.md`, `docs/THREAT_MODEL.md`, or `/security` from the relevant sections. The README does list `docs/THREAT_MODEL.md` in the "Cursor deep dives" list, but only as a generic "Architecture" link, not adjacent to the security claims.
**Impact:** A developer reading the README has no clear path to the security story. The GitHub-side README is the first place a security researcher lands; that first page should make the disclosure path obvious.
**Fix:** Add a one-line "Security & responsible disclosure" callout near the top of the README, link `SECURITY.md` and `burnbar.ai/.well-known/security.txt`, and footnote the E2EE / tamper-proof claims with a pointer to the rewrite.
**Owner:** Docs.

### Finding D7: Pricing and plan copy state the security property without a backing link

**Severity:** Low.
**Evidence:** `/pricing` plan cards include "Encrypted session history, searchable everywhere", "Tamper-proof action record · per-task grants", "Verified entitlement — checked server-side". None of these bullets link to a trust page; a curious buyer must already know to look at `/security`.
**Impact:** Reduces trust-action friction at the moment of evaluation.
**Fix:** Add a small `Learn how this is protected →` link beneath the Cloud and Cloud Pro cards pointing at `/security` (or, after the trust page exists, `/security#encrypted-history`).
**Owner:** Website.

### Finding D8: Threat model is internal-only; no public customer-readable summary

**Severity:** Medium.
**Evidence:** The threat model is 287 lines and references `~/Library/Application Support/...` paths and Swift / SwiftUI / TypeScript internals. There is no customer-readable summary. A security-aware customer or a procurement reviewer can read it, but a regular user is not the audience — and a public trust page that does not link *some* form of customer summary under-uses the work that has been done.
**Impact:** Internal threat modeling is excellent but invisible to non-developers; the public `/security` page is the only customer-facing summary and it does not link to the threat models, the privileged-input model, or the supply-chain model.
**Fix:** Add a `## What we defend, and what we don't` customer-summary section at the top of `/security` (or a new `/security/model`) that links to the developer-facing threat models and uses plain language. Outlined in §6.3.
**Owner:** Security / Website.

### Finding D9: Overclaim language still present on public surfaces (independent of the prior rewrite)

**Severity:** Medium (compliance + reputational).
**Evidence:** The `SECURITY_CLAIMS_REWRITE.md` already lists the offending phrases. This subagent confirms they are still live in shipping copy on 2026-06-01 and adds line-level citations (see §4).
**Impact:** A regulator, a journalist, or an enterprise security reviewer reading the homepage can quote "we built it so we couldn't peek even if we wanted to" without context. The prior review's recommended wording is the correct fix; this finding is a *shipped* verification, not a new claim.
**Fix:** Apply the rewrites (see §4 + §5).
**Owner:** Marketing / Website.

### Finding D10: No CSP or HSTS statement on the `/security` page

**Severity:** Low.
**Evidence:** `firebase.json` configures a strong default CSP, HSTS (preload), Referrer-Policy, X-Frame-Options DENY, Permissions-Policy, and a tight `connect-src` for the marketing site. None of this is mentioned on `/security`. For a security page this is a missed opportunity.
**Impact:** A reviewer can't see at a glance what headers the site ships.
**Fix:** Add a "Web security headers" subsection to `/security` (or `/trust`) listing the actual headers (with the values that `firebase.json` configures) and the rationale. Audit the `Link rel="preload"` / `Strict-Transport-Security` preload submission status.
**Owner:** Website.

### Finding D11: SBOM is published but not advertised

**Severity:** Low.
**Evidence:** `website/public/downloads/sbom-v1.0.spdx.json` and `checksums-v1.0.txt` exist. `/security` and the download page do not link to the SBOM or the checksums file. `docs/security/SUPPLY_CHAIN_PROVENANCE.md` lists the SBOM + VEX but the public site does not.
**Impact:** A security reviewer cannot easily find the SBOM without reading `docs/RELEASE_MACOS.md` or `docs/security/SUPPLY_CHAIN_PROVENANCE.md`.
**Fix:** Link the SBOM and the checksums file from the download page and the trust page. Add a "Supply chain" subsection that explains cosign attestation, SBOM, VEX, and reproducibility status honestly (today: L1/L2 for some artifacts; not SLSA L3 uniformly).
**Owner:** Release / Security / Website.

### Finding D12: Trademark clearance is not confirmed publicly

**Severity:** Low.
**Evidence:** `website/CLAIMS.md` notes "Trademark clearance for 'OpenBurnBar' is listed as a TODO in `docs/OSS_LAUNCH_CHECKLIST.md:108`." If the brand name is not cleared, the public site cannot safely advertise the product under it.
**Impact:** Legal risk before public launch.
**Fix:** Resolve before launch.
**Owner:** Legal.

### Finding D13: Canonical GitHub URL is not aligned in public surfaces

**Severity:** Low.
**Evidence:** `website/CLAIMS.md` notes the README advertises `Ajnunezg/BurnBar` and the site points at `Imagine-That-Ai/BurnBar`. Both are public repos. `site.ts:11` and the SECURITY_CLAIMS_REWRITE both rely on a single canonical URL. Public trust surfaces should not direct users to two different orgs.
**Impact:** Confusion, broken links, and a weaker chain-of-trust for the SBOM/Sigstore attestations.
**Fix:** Pick one URL and update README, `site.ts`, the release workflow, and the SBOM download path.
**Owner:** Release / Website.

### Finding D14: In-app on-boarding copy is not version-controlled for claims

**Severity:** Low (we did not review in-app strings in this pass).
**Evidence:** The website has `website/CLAIMS.md`; in-app strings are not surfaced in the same matrix.
**Impact:** Drift between marketing and in-app over time.
**Fix:** Either add an `in-app` column to `website/CLAIMS.md` (preferred; the file is already a matrix) or create a parallel `docs/IN_APP_CLAIMS.md` that the in-app linter can consume.
**Owner:** Marketing / Engineering.

### Finding D15: Privacy page is excellent; the parallel "Security model" page is the trust gap

**Severity:** Low.
**Evidence:** The `/privacy` page walks every opt-in, every deletion path, every data class. The `/security` page covers the top-5 threats but does not include an opt-in/feature matrix equivalent to "what we never collect / what we never claim."
**Impact:** Asymmetric trust surface. Privacy is well-explained; security is half-explained.
**Fix:** Extend `/security` (or split into `/security/model` + `/security/disclosure`) with the matrix from §6.3.
**Owner:** Website.

---

## 4. Overclaim List (with public surface + line + recommended wording)

This list pairs every overclaim found on a public surface on 2026-06-01 with the recommended wording from `security-review-2026-06-01/SECURITY_CLAIMS_REWRITE.md`, restated for shipping.

| # | Public surface | Verbatim claim | Why it's an overclaim (evidence) | Recommended wording |
|---|---|---|---|---|
| OC1 | `website/src/pages/index.astro:403-404` (Hermes section) | "Reach the Mac's Hermes from anywhere over an **end-to-end-encrypted WebSocket**. Paid-tier; relay never sees plaintext." | The Hermes Remote Relay is operated by OpenBurnBar; "end-to-end encrypted" is true for payload but omits that the relay sees frame metadata (connection patterns, byte volumes, timing) and that browser/WASM clients pay relay cost differently. `docs/THREAT_MODEL.md` acknowledges relay metadata. | "Reach the Mac's Hermes from anywhere over a relay-encrypted transport. Payload frames are sealed between your devices; the relay observes connection metadata (NodeIds, timing, byte volumes) but not plaintext. Paid-tier." |
| OC2 | `website/src/pages/index.astro:532` (Floo card) | "Only your own devices. **Encrypted end to end.** You approve every connection." | True for payload; "end to end" is ambiguous about whether it includes relay metadata. The internal Floo promise on the dedicated page (FLOO_PROMISES) is the absolute version of this. | "Only your own paired devices. Payload is encrypted between them; the relay (when used) cannot read it but can observe connection patterns. You approve every connection." |
| OC3 | `website/src/pages/floo.astro:83-85` | "{FLOO.name} is for your devices and no one else's. The connection is private end to end — and **that includes us. We built it so we couldn't peek even if we wanted to.**" | Strong overclaim. Internal SOTA gap says relay metadata is observable; the Iroh specialist (out of scope here) flagged app-layer authz not fully proven for every sensitive action. A compromised but genuinely paired device or a first-party-signed binary is still high-impact. | "Floo is for the devices you've paired and trust. Payload is encrypted between them; the relay cannot read it. We don't decrypt your streams. As with any peer-to-peer system, a compromised paired device or a compromised Mac is a residual risk we cannot remove for you." |
| OC4 | `website/src/data/capabilities.ts:92` (FLOO_PROMISES) | "**Everything between them is end-to-end encrypted. No one in the middle can read it, and that includes us.**" | Same as OC3. | "Payload between your devices is encrypted end-to-end. The relay (when used) cannot read it, and we don't decrypt it. Connection metadata is observable at the relay." |
| OC5 | `website/src/data/capabilities.ts:144-147` ("A tamper-proof record of everything") | "Every action the agent takes is written to a record that can't be quietly edited after the fact. You can always see precisely what happened." | Internal language is "tamper-evident" (hash chain + signed head + OpenTimestamps). Completeness requires the exported artifacts + max-index + verifier. The "tamper-proof" word implies more than the construction provides. | "Every privileged action is recorded in a tamper-evident hash chain with a signed head and an optional OpenTimestamps proof. You can verify integrity offline with the exported chain and verifier." |
| OC6 | `website/src/pages/control.astro:24` (meta description) | "…with a **tamper-proof record** and an instant stop." | Same as OC5. | "…with a tamper-evident record and an instant stop." |
| OC7 | `website/src/data/faq.ts:193` (Floo FAQ) | "…and everything between them is **end-to-end encrypted — no one in the middle can read it, and that includes us.**" | Same as OC3. | "Payload is encrypted end-to-end between your paired devices; the relay cannot read it, and we don't decrypt it. Connection metadata is observable at the relay." |
| OC8 | `website/src/data/faq.ts:200` (Agent Control FAQ) | "Every action is written to a **tamper-proof record**." | Same as OC5. | "Every action is written to a tamper-evident record (hash chain + signed head + optional OpenTimestamps)." |
| OC9 | `website/src/pages/privacy.astro:113-114` (Zone C card) | "Cloud Run · Hermes relay routes encrypted frames; **never sees plaintext request or response bodies**" | True for the body. "Never sees plaintext" is technically defensible for the body, but a reader may infer "never sees anything"; relay metadata (counts, sizes, timing) is still visible. | "Cloud Run · Hermes relay routes encrypted frames between your paired devices; the relay never sees plaintext bodies. Connection metadata is observable." |
| OC10 | `website/src/pages/privacy.astro:195-196` (Hermes opt-in card) | "Frames are **end-to-end encrypted from OpenBurnBar's perspective — the relay never receives plaintext**." | Same shape as OC1. | "Frames are encrypted between your devices; the relay never receives plaintext. Connection metadata is observable at the relay." |
| OC11 | `website/src/pages/legal/privacy-policy.astro:44` | "Cloud Pro phone-to-Mac relay traffic (**encrypted end-to-end from OpenBurnBar's perspective**)." | Same. | "Cloud Pro phone-to-Mac relay traffic is encrypted between your paired devices; the relay never receives plaintext." |
| OC12 | `website/src/pages/benefits.astro:83-85` | "the cloud is there — gated by Apple-verified entitlement and **end-to-end encryption**." | The cloud's "end-to-end encryption" is per-feature (hosted session search, encrypted backup); it is not a property of all cloud data. | "the cloud is there — gated by Apple-verified entitlement, with end-to-end encryption applied to the surfaces that need it (hosted session search, encrypted backup, Hermes relay frames)." |
| OC13 | `website/src/pages/mcp.astro:1135` | "Free, local, today — or **hosted, encrypted, multi-device**." | "Encrypted" without scope. | "Free, local, today — or hosted, with end-to-end-encrypted body storage and sealed metadata for multi-device session memory." |
| OC14 | `website/src/pages/mcp.astro:662, 1063, 74, 80, 86, 104, 149, 173, 931` | All "encrypted" uses of session-memory / snippets / search | True for the body + envelopes. A reader may infer "the host can't see anything"; sealed metadata is observable and cost/metadata are inferable. | Add a single sentence on the MCP page: "Hosted session memory uses sealed titles/snippets + opaque token/semantic hashes; the host never sees plaintext, but the host can observe query counts, timing, and matched-document hashes." |
| OC15 | `website/src/pages/index.astro:147` | "**0** telemetry, analytics, or crash reports out of the box" | This is *currently* true; the language is correct as a default. Recommend keeping but qualifying "out of the box" with a one-liner: Sentry is opt-in and uses a SHA-seeded identifier; relay callables write admin audit logs on the server side that may identify your UID. | "0 telemetry, analytics, or crash reports by default. Server-side audit logs (e.g. for App Check–enforced callables) record your UID; Sentry is opt-in and uses a SHA-seeded user identifier." |
| OC16 | `website/src/pages/privacy.astro:14` (H1) | "By default, OpenBurnBar collects nothing." | True for client-side telemetry; server-side audit logs exist for the cloud callables. | "By default, OpenBurnBar sends nothing from your device. Cloud callables (when you sign in) write server-side audit logs that include your UID — see the Security model." |
| OC17 | `website/src/pages/privacy.astro:201-203` (Sentry opt-in) | "User identifier is a SHA seed derived from bundle id and full user name — **not direct PII**." | A SHA hash of a stable user name is pseudonymous, not anonymous; it is linkable across sessions. This is acceptable but should not be marketed as "not PII." | "User identifier is a SHA-256 seed derived from the bundle id and the local full user name. This is pseudonymous, not anonymous, and is linkable across sessions." |
| OC18 | `README.md:14` | "No API keys, no account, no cloud — unless you *want* cloud." | True for the local product; out of date with the fact that the Mac App Store build's "no cloud" requires not signing in. | "Local product: no API keys, no account, no cloud. Optional cloud features require sign-in." |
| OC19 | `README.md:69` | "Hosted Remote MCP for BurnBar Pro — paid users can connect coding agents to OpenBurnBar's hosted MCP endpoint for **encrypted** hosted session-memory search, with a local shim for stdio-only clients and device-side decrypt." | "Encrypted" without qualifier; misses that the hosted endpoint uses per-client grant + revoke. | "Hosted Remote MCP for BurnBar Pro — paid users can connect coding agents to OpenBurnBar's hosted MCP for **sealed title/snippet + opaque hash** hosted session-memory search, with a local shim for stdio-only clients, device-side decrypt, and per-client grant revoke from the in-app Cloud Store." |
| OC20 | `README.md:387` | "BurnBar Pro hosted session search stores **encrypted bodies** in Firebase Storage and sealed metadata plus opaque token/semantic hashes in Firestore" | Good, but the surrounding context still calls it "encrypted history" without scope. Pair this with the in-app "What we never claim" footer (see OC9-OC14). | Keep; mirror in `/security`. |
| OC21 | `website/src/data/capabilities.ts:82-86` (Floo unlock) | "Your password is **sealed end to end** — it never appears in a log, a server, or anywhere you didn't put it." | True for the sealed-credential design + biometric gate. But the user might infer that nothing is logged at all; the unlock flow still records pairing metadata, unlock requests, biometric outcomes on the device. | "Your Mac password never leaves your devices. The unlock path is sealed end-to-end and biometric-gated on the phone. The unlock flow records pairing metadata and unlock outcomes locally; it does not transmit the password or your biometric template." |
| OC22 | `website/src/pages/security.astro:13` (H1) | "**A defensive product, not a hardened castle.**" | The H1 is the right tone, but the page body that follows (Threats 01-05) is a best-case list. The "What we don't pretend" section is good but does not name the relay-metadata / Iroh-app-layer / privileged-input residuals that the threat model calls out. | Add a fourth list: "What we cannot promise" — relay metadata, Iroh app-layer authz on new sensitive actions, same-UID local malware, compromised paired devices, supply-chain risk on signed binaries. |
| OC23 | `website/src/pages/privacy.astro:113-114` | "Cloud Run · Hermes relay routes encrypted frames" | "Encrypted frames" — could read as "no one can see anything." | (handled by OC9/OC10) |

**Net effect after rewrites:** every "encrypted" / "tamper-proof" / "no one in the middle" / "we can't read it" on the public surface is qualified with the residual (relay metadata, app-layer authz, completeness proof required) and the threat-model file the reader can open.

---

## 5. Public-Facing Documents to Update (and what to change)

These are the minimal changes that, together with §6 below, turn the current public surface into a launch-grade trust surface.

### 5.1 `website/src/data/capabilities.ts` (highest priority)

- Replace `FLOO_PROMISES[1]` (line 92) with the wording from OC4.
- Replace `CONTROL_CAPABILITIES` entry for "A tamper-proof record of everything" (lines 142-148) with the wording from OC5.

### 5.2 `website/src/data/faq.ts`

- Floo Q&A: replace the E2EE sentence with the wording from OC7.
- Agent Control Q&A: replace the "tamper-proof" sentence with the wording from OC8.

### 5.3 `website/src/pages/index.astro`

- Home trust band (lines 114-117, 147, 562-579, 634, 641, 403-404, 532): apply OC1, OC2, OC15, OC16.

### 5.4 `website/src/pages/floo.astro`, `website/src/pages/control.astro`, `website/src/pages/mcp.astro`, `website/src/pages/benefits.astro`, `website/src/pages/privacy.astro`, `website/src/pages/legal/privacy-policy.astro`, `website/src/pages/security.astro`

- Apply OC1-OC23.

### 5.5 `README.md`

- Add a one-paragraph "Security & responsible disclosure" near the top (per D6) with links to `SECURITY.md` and `https://burnbar.ai/.well-known/security.txt`.
- Apply OC18, OC19.

### 5.6 `SECURITY.md` (root and `.github/`)

- Add an explicit "Public VDP" link to `https://burnbar.ai/security/disclosure` (per D2). Keep the GitHub private vulnerability reporting path; the public VDP gives the page a public, durable home.
- Add a one-line safe-harbor clause: "We will not pursue legal action against good-faith research that follows this policy."

### 5.7 `firebase.json`

- Add a headers rule for `/.well-known/security.txt`:

  ```json
  {
    "source": "/.well-known/security.txt",
    "headers": [
      { "key": "Content-Type", "value": "text/plain; charset=utf-8" },
      { "key": "Cache-Control", "value": "public, max-age=3600" }
    ]
  }
  ```

  Note: `**/.*` is in the existing `ignore` list, so the static asset must be present at `website/public/.well-known/security.txt` and copied to the Firebase `public` directory at build time. Re-test: the existing `ignore` is `["firebase.json", "**/.*", "**/node_modules/**"]` — that *does* ignore `**/.*` paths, so **we must explicitly add `".well-known"` to the public-allow list** (or change the ignore). Recommend changing `ignore` to `["firebase.json", "**/.*", "**/node_modules/**", "**/.git/**"]` and add `"**/.well-known/**"` to a `rewrites` or copy rule, **or** use a Cloud Function as a redirect to a static file. Simplest fix: rename the static file to `well-known-security.txt` and serve at `/.well-known/security.txt` via a `rewrites` rule:

  ```json
  { "source": "/.well-known/security.txt", "destination": "/well-known-security.txt" }
  ```

  with the file at `website/public/well-known-security.txt`. This works because Firebase Hosting serves static files from `public/` directly. Verified against `firebase.json` structure (cleanUrls, trailingSlash false).

### 5.8 `website/src/data/site.ts` (footer)

- Add a "Trust" section: links to `/security`, the VDP, security.txt, the status page (when live), and the SBOM. Suggested grouping:

  ```ts
  trust: [
    { href: "/security", label: "Security model" },
    { href: "/security/disclosure", label: "Responsible disclosure" },
    { href: "/.well-known/security.txt", label: "security.txt", external: true },
    { href: "https://status.burnbar.ai", label: "Status", external: true },
    { href: "/legal/privacy-policy", label: "Privacy policy" },
    { href: "/legal/terms", label: "Terms" }
  ]
  ```

### 5.9 Pricing card

- Add a small "Learn how this is protected" link beneath the Cloud and Cloud Pro security-adjacent bullets (per D7).

---

## 6. Drafts (security.txt, VDP, trust page outline, responsible-security page)

### 6.1 `/.well-known/security.txt` — RFC 9116 draft

```
# OpenBurnBar security.txt
# RFC 9116 — https://www.rfc-editor.org/rfc/rfc9116
# Canonical URL: https://burnbar.ai/.well-known/security.txt

Contact: mailto:security@openburnbar.app
Contact: https://github.com/Imagine-That-Ai/BurnBar/security/advisories/new
Expires: 2027-06-01T00:00:00.000Z
Preferred-Languages: en
Canonical: https://burnbar.ai/.well-known/security.txt
Policy: https://burnbar.ai/security/disclosure
Acknowledgments: https://burnbar.ai/security/hall-of-fame
Hiring: https://imagine-that.ai/careers

# Out-of-scope (do not report; we will close as informative):
# - Denial-of-service (rate-limit / volume attacks against burnbar.ai)
# - Self-XSS in the marketing site
# - Missing security headers on subdomains we do not operate
# - Third-party SaaS that we link to (Stripe, Apple, Google, Sentry, OTS)
# - Issues requiring an attacker to already control the user's Mac, phone, or Apple ID
# - Theoretical best-practice observations that are not exploitable
```

**Notes:**

- The Expires field is mandatory per RFC 9116; the calendar is set one year out and must be rotated annually.
- The `Contact:` line includes both a private email and the GitHub private-advisory URL. The repo currently uses `Ajnunezg/BurnBar` per `README.md`; resolve D13 before publishing.
- The `Policy:` line points at the public VDP from §6.2.
- The `Acknowledgments:` line is a placeholder; ship a `/security/hall-of-fame` page (even an empty stub) when a researcher is credited, to make the public commitment real.
- The out-of-scope list is short on purpose; over-broad "out of scope" lists discourage researchers. Move the "out of scope" to the VDP page so it doesn't grow into a black hole.

### 6.2 Vulnerability Disclosure Policy (VDP) — public page outline

URL: `https://burnbar.ai/security/disclosure`. Either as a new page or a section of `/security`. Content:

```
# Responsible disclosure

OpenBurnBar takes reports about the security of our products seriously.

## How to report

- Private email: security@openburnbar.app (PGP key on this page; fingerprint …).
- GitHub private vulnerability reporting: <https://github.com/Imagine-That-Ai/BurnBar/security/advisories/new>
- For sensitive reports only: please prefer encrypted email or the GitHub advisory flow.

## What to include

A good report includes:
- The product, version, and platform (e.g. "OpenBurnBar 1.0.1 on macOS 14.4").
- Reproduction steps, ideally with a minimal harness.
- The impact you observed and the impact you suspect.
- Whether the report has been disclosed publicly or to a third party.

## What you can expect from us

- Acknowledgement within 3 business days.
- A first triage decision within 10 business days.
- A coordinated disclosure timeline we agree on.
- Credit on our public hall of fame (https://burnbar.ai/security/hall-of-fame) unless you ask to remain anonymous.

We do not currently run a paid bug bounty. We may, in the future.

## Safe harbor

When you make a good-faith effort to follow this policy, we will not pursue legal action against you for the act of researching the bug, and we will work with you in good faith to understand and fix the issue. This is a best-effort commitment and is not a binding legal waiver.

## Out of scope

We will close as informative (not as security issues) reports of:
- Denial-of-service attacks against burnbar.ai or any other property we operate.
- Self-XSS or stored-XSS that requires the victim to paste attacker-controlled content into a privileged field.
- Missing security headers on subdomains we do not operate.
- Best-practice observations on third-party services we link to (Stripe, Apple, Google, Sentry, OTS, OpenTimestamps, Iroh relay operators we depend on).
- Issues that require the attacker to already have full local control of your Mac, iPhone, iPad, or Apple ID, except where a second factor (e.g. relay metadata, app-layer authz) is materially weakened as a result.

## Encryption

We publish a PGP public key at /security/pgp.asc for sensitive reports. The fingerprint is listed on this page. We will rotate the key on a 12-month cadence; previous keys remain available for history.

## Acknowledgements

We thank the researchers who have reported vulnerabilities. See /security/hall-of-fame.
```

**Implementation note:** when the page first ships, the hall-of-fame can be empty; the page itself signals that the program is real. The first credit then appears on it.

### 6.3 Trust page outline

URL: `https://burnbar.ai/security` (extend the existing page) or a new `/trust`. The trust page is the *one* page that links everything: the threat model, the SBOM, the VDP, security.txt, the status page, the responsible-disclosure page, the public changelog, and the customer-readable summary. Outline:

```
# Trust at OpenBurnBar

A defensive product, not a hardened castle. We document what we defend, what we don't, and how to reach us if you find something.

## 1. Snapshot

| | |
|---|---|
| Open source? | Yes — MIT. Source at github.com/Imagine-That-Ai/BurnBar |
| Last external review? | Self-review, June 2026. (Public version of this review available on request.) |
| Public VDP? | /security/disclosure |
| security.txt? | https://burnbar.ai/.well-known/security.txt |
| Status page? | status.burnbar.ai |
| Supply chain? | cosign + SBOM (SPDX) + OpenVEX on the release lane; see /security#supply-chain |
| Active bug bounty? | Not yet; safe-harbor + triage commitment in the VDP. |
| Primary contact? | security@openburnbar.app |

## 2. What we defend

A short, plain-English version of the top 5 from /security:
1. The daemon socket (UNIX, filesystem ACL + token).
2. Secrets at rest (Keychain, SQLCipher key).
3. Unauthorized cloud access (Firebase Auth + App Check + owner-scoped rules + secret-field-name denylist + JWS-verified App Store receipts).
4. Cross-device credential exposure (ECIES escrow; private keys never leave the device Keychain).
5. App Store entitlement forgery (JWS verified against pinned Apple root CAs).

## 3. What we cannot promise

From the threat model — these are residual risks, not bugs:
- Same-user local malware can read or write anything OpenBurnBar can. The macOS app is not sandboxed in the direct-download build (it is in the Mac App Store build); the threat model treats this as inherent.
- A compromised but genuinely paired phone, or a first-party-signed malicious binary, can still drive the privileged input surfaces (keyboard, mouse, accessibility) on the Mac. Capability tokens (WS2), attestation binding, and the kill switches reduce but do not eliminate this risk.
- The Hermes Remote Relay sees connection metadata (NodeIds, byte volumes, timing). Payload is end-to-end encrypted; metadata is not.
- Provider API calls are not certificate-pinned. The system trust store applies.
- The optional Cursor connector tunnel routes BYOK traffic through Cloudflare. This is the only way today to land Cursor BYOK on a localhost endpoint.
- iCloud session mirroring uses your Apple ID; Apple owns the sync semantics. Conflict copies are possible.
- Cost and quota numbers are derived from public pricing lists and parsed logs; they are not invoice-accurate.

## 4. Threat model (full)

- /docs/THREAT_MODEL.md (developer-readable; full)
- /docs/security/PRIVILEGED_INPUT_THREAT_MODEL.md (privileged input surfaces)
- /docs/security/SUPPLY_CHAIN_PROVENANCE.md (release supply chain)
- /docs/security/LLM_GENAI_AGENT_THREAT_MODEL.md (AI / agent threat model)

## 5. Web security headers (marketing site)

- HSTS (preload, 2 years)
- CSP: default-src 'self'; connect-src 'self'; frame-ancestors 'none'
- Referrer-Policy: strict-origin-when-cross-origin
- X-Content-Type-Options: nosniff
- X-Frame-Options: DENY
- Permissions-Policy: sensor and payment APIs disabled

## 6. Release supply chain

- Developer ID signing + notarization (macOS direct download)
- Mac App Store build: signed by Apple
- SLSA: L1/L2 today on the release lane; L3 is the goal. Not uniform across all artifacts.
- Provenance: GitHub OIDC → Sigstore cosign attestations
- SBOM: SPDX (`/downloads/sbom-v1.0.spdx.json`)
- Checksums: SHA-256/512 (`/downloads/checksums-v1.0.txt`)
- VEX: OpenVEX sidecar generated at release time
- See /docs/security/SUPPLY_CHAIN_PROVENANCE.md for the per-artifact table.

## 7. How to reach us

- Security disclosure: see /security/disclosure
- privacy: privacy@imagine-that.ai
- Support: support@openburnbar.app
- Status: status.burnbar.ai
- Repository: github.com/Imagine-That-Ai/BurnBar

## 8. Changes to this page

The page is regenerated alongside the threat model. The last review date is in the page footer.
```

### 6.4 Responsible-security page draft (alternative naming for the VDP)

If `/security/disclosure` is too long, the equivalent is `/responsible-security`. The OpenSSF "Security Standards" working group recommends `/security.txt` + `/security/disclosure` + `/security/policy` as a trio. Pick one and stick with it.

### 6.5 Footer / sitemap

- Add the VDP link to the footer Trust block.
- Submit `burnbar.ai/sitemap.xml` (already in `robots.txt`).
- Add a `<link rel="security.txt" href="https://burnbar.ai/.well-known/security.txt" />` in the `<head>` of every page (optional but cheap; some scanners look for it).

### 6.6 In-app on-boarding

- Mirror the rewrites in §5.1-§5.6 in any in-app on-boarding that mentions encrypted, E2EE, or tamper-proof.
- Add a "Security & privacy" link from the in-app settings panel to `https://burnbar.ai/security` and to the VDP.

---

## 7. Verification Plan (what to check after the rewrites)

For each item below, run the check before the marketing site re-deploys.

1. **Grep gate.** Add a CI check that fails the build if any of the following appear in `website/src/`: `\bend-to-end encrypted\b` not followed by a qualifier (e.g. "between your paired devices"), `\bcan't read\b`, `\bcannot read\b`, `\bcan't see\b`, `\bcannot see\b`, `\btamper-proof\b`, `\bunhackable\b`, `\bimpossible\b`, `\bfully secure\b`, `\bwe can't\b`, `\bwe cannot\b`. The qualifier check is a regex; ship the list of allowed qualifiers as a TS const. The same gate covers `README.md` and `docs/`.
2. **security.txt reachability.** `curl -fsS https://burnbar.ai/.well-known/security.txt` returns 200 + the file. Check `Expires` is in the future; CI reminder to rotate annually.
3. **VDP reachability.** `curl -fsS https://burnbar.ai/security/disclosure` returns 200; the page contains a `mailto:security@openburnbar.app` and a PGP fingerprint.
4. **Status page link.** A footer link to `status.burnbar.ai` returns 200; if not yet live, the link is removed and replaced with a "Status: planned" marker.
5. **SBOM link.** `curl -fsS https://burnbar.ai/downloads/sbom-v1.0.spdx.json` returns 200 and the SBOM is a valid SPDX document (use `spdx-tools validate` or `pyspdxtools`).
6. **Footer trust block.** All of `/security`, `/security/disclosure`, `/.well-known/security.txt`, and the status page are present in the footer trust column on every page.
7. **Pricing card link.** The Cloud and Cloud Pro security-adjacent bullets ("Encrypted session history", "Tamper-proof action record", "Verified entitlement") each have a "Learn how this is protected →" link to `/security` (or the trust page after it exists).
8. **CSP/HSTS still intact.** `curl -I https://burnbar.ai/security` returns the same headers as `https://burnbar.ai/`.
9. **Canonical URL.** Pick one GitHub URL. Update `site.ts:11`, `README.md:18`, the release workflow, and the SBOM download link so they all match.
10. **Trademark.** Confirm "OpenBurnBar" trademark clearance before any launch re-deploy.
11. **In-app copy spot-check.** Pull a sample of on-boarding and Settings strings; apply the same rewrites; ship in the next App Store / Play Store submission.
12. **Hall of fame.** `/security/hall-of-fame` exists (empty stub OK on first launch); it can grow when a researcher reports under the VDP.

---

## 8. Confidence and Caveats

- **High confidence** on §2 (the line-level claims map), §3 (the missing trust surfaces are grep-confirmed absences), §4 (the overclaim language is verbatim from the live files), §6.1 (security.txt format is RFC 9116-compliant), and §7 (verification plan is mechanical).
- **Medium confidence** on §5 (the firebase.json rewrite workaround for `**/.*` ignore is a known Firebase Hosting gotcha; the rewrite-based solution in §5.7 works but should be smoke-tested before the next deploy).
- **Low / out of scope** for this subagent: in-app `Localizable.strings` (not in this pass), the canonical GitHub URL resolution (D13), the trademark question (D12), and the in-app on-boarding rewrites (D14). These are flagged in §3 so the next pass can pick them up.
- **This artifact is additive** to the prior `SECURITY_CLAIMS_REWRITE.md` (line-level word replacements) and `SOTA_GAP_ANALYSIS.md` (framework-level gap). It does not duplicate either; it ties them to the public surfaces and adds the trust-page / VDP / security.txt / status-page / SBOM / supply-chain-advertising gaps.

---

## 9. One-paragraph summary for the orchestrator

The internal security story is unusually strong for a 1.0 launch (detailed threat models, SOTA privileged-input remediation, supply-chain attestations on the release lane, and a self-critical SOTA gap). The *public* security story lags behind by roughly two layers: (a) the marketing copy uses absolute language ("end-to-end encrypted", "tamper-proof", "no one in the middle can read it, and that includes us", "we built it so we couldn't peek even if we wanted to") in eight places on shipping pages and in the README, and (b) the public trust surface is missing the four artifacts a 2026 customer and an enterprise reviewer will look for first: a `/.well-known/security.txt`, a public VDP, a status page, and a trust page that links the developer-facing threat model to the customer-facing copy. The fix is mechanical: ship `security.txt` (drafted), ship the VDP (outlined), qualify the eight overclaim phrases (line-level), extend the `/security` page to a trust center that links the threat model, the SBOM, the VDP, security.txt, the status page, and the public changelog, and add a CI gate that fails the marketing build if any of the absolute phrases reappear without a qualifier. None of the fixes requires new architecture; they are all copy + one static file + a Firebase `headers` rule. Once these land, OpenBurnBar's external trust posture will match the strength of its internal threat modeling.
