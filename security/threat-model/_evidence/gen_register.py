#!/usr/bin/env python3
"""Generate threat-register.csv (machine-readable) + threat-register.md (human) from the verified evidence base."""
import csv, os, re

EV = os.path.dirname(os.path.abspath(__file__))
TM = os.path.dirname(EV)
TSV = os.path.join(EV, "_threats.tsv")

# Per-family metadata: (threat_actor, asset, data_flow, owner, precondition, detection)
FAM = {
 "T-CRY": ("Network attacker / malicious or compromised relay", "Relay & gateway message payloads", "Phone<->Cloud<->Mac sealed relay/gateway", "Crypto/Core (OpenBurnBarCore)",
           "On-path network position or control of a relay/gateway lane", "Relay version telemetry; HPKE open-failure metrics; downgrade-rate alarm (missing)"),
 "T-CVS": ("Compromised unlocked endpoint / curious cloud operator", "CloudVault at-rest content; vault & identity private keys", "Client<->Firestore client-sealed sync", "Crypto/Core + Mobile",
           "Read access to Firestore ciphertext, OR code running as the app on an unlocked device", "Firestore read audit; at-rest open-failure metrics; key-access logs (endpoint side)"),
 "T-PTR": ("Malicious cloud/admin or social-engineering pairer", "Device trust graph, pairing records, vault wraps", "Device pairing & trusted-device promotion", "Identity/Pairing",
           "Firestore write (admin) or victim approving a pending device / first-pairing TOFU window", "high_risk_action_nonces, escrow approval audit events; pairing-record write audit"),
 "T-TRN": ("Malicious cloud/admin or relay operator", "iroh control channel; transport metadata (NodeIds, IPs, timing)", "Device<->Device iroh / relay / Firestore fallback", "Transport (iroh)",
           "Control of the Firestore pairing directory / relay, OR network position", "iroh_fallback_to_wss / fallback-rate audit events; pairing-key change audit"),
 "T-GW": ("Compromised relay, token+PoP-key thief, or malicious agent", "Gateway messages/events/attachments + routing metadata", "Phone<->Hermes Gateway<->Mac", "Backend (Functions)",
          "Stolen bearer AND PoP private key, OR control of the gateway store", "Gateway PoP-nonce txn writes; replay-ledger; sealed-write rejection logs"),
 "T-AZ": ("Malicious authenticated user or rogue admin (Admin SDK)", "Firestore/Storage objects across tenants; trust roots", "Client<->Firestore/Storage", "Backend (Functions/Rules)",
          "Valid Firebase session + App Check, OR Admin/IAM access", "Firestore rules-deny metrics; Cloud Audit Logs; Admin SDK access logs"),
 "T-DMN": ("Same-user malware or a compromised signed first-party app", "Local system control, HID, credentials, daemon RPC", "App<->Daemon unix socket / privileged HID socket", "Daemon/Core",
           "Code execution as the login user OR compromise of a signed first-party binary", "Daemon peer-auth rejections; ComputerUse audit hash-chain; launchd/binary integrity"),
 "T-TOOL": ("Prompt-injection adversary or malicious CLI agent runtime", "Local shell, filesystem, granted agent capabilities", "Agent<->Tools / CLI subprocess", "AgentLens (CLIBridge/ComputerUse)",
            "An active grant (esp. workspace_write/shell/YOLO/Trusted) on the session", "ComputerUse audit chain; CLI process registry; grant/approval audit events"),
 "T-AI": ("Indirect prompt-injection adversary (content author)", "Agent context/memory; downstream tool-call decisions", "Untrusted content (RAG/tool/web/log)<->model context", "AgentLens (Context/Chat)",
          "Attacker controls text that enters an active agent's context", "Provenance-wrap coverage gaps; tool-loop audit; oracle/RAG source tagging (missing)"),
 "T-IOS": ("Thief with unlocked phone, malicious sibling app, or backup extractor", "iOS local data, vault/escrow keys, pasteboard, push payloads", "iOS app<->Keychain/AppGroup/APNs", "Mobile-iOS",
           "Physical access to an unlocked device, a malicious co-resident app, or a device backup", "n/a on-device (no jailbreak detection); MDM/backup posture; APNs payload review"),
 "T-AND": ("Thief with unlocked phone or malicious app", "Android local data, keys, FCM payloads", "Android app<->Keystore/FCM", "Mobile-Android",
           "Physical access to an unlocked device or a malicious app with shared access", "n/a on-device; FCM payload review; Play Integrity (server-side)"),
 "T-ATT": ("Malicious paired peer or attachment uploader", "Attachment/media bytes; receiver disk/quota; parsers", "Attachment upload/download + Mercury media transfer", "Backend + Media",
           "A paired peer or an authenticated upload session", "Storage finalize size/hash mismatch logs; media budget/kill metrics; quarantine xattr (missing on Mercury)"),
 "T-PRV": ("Push/analytics sub-processor (Apple/Google/Sentry) or curious operator", "Metadata, push tokens, call graph, logs, crash reports", "Cloud<->APNs/FCM/Sentry/search-index", "Backend (Privacy)",
           "Access to push payloads / crash SaaS / Firestore metadata / query logs", "DLP on push payloads; Sentry event review; log-field audit; search-index access logs"),
 "T-SC": ("Supply-chain attacker, malicious PR, or insider operator", "Build/release artifacts, CI secrets, deploy credentials", "Repo<->CI<->prod deploy / artifact registry", "CI/CD",
          "Ability to land a PR, compromise an action/dep, or operator access", "CI run logs; action-pin/diff gates; provenance/SBOM gate; CODEOWNERS review"),
}

IMPACT = {"Critical":"Critical","High":"High","Medium":"Medium","Low":"Low","Info":"Informational"}
PRIORITY = {"Critical":"P0 (must-fix before audit)","High":"P1 (should-fix before launch)","Medium":"P2 (important hardening)","Low":"P3 (defense-in-depth)","Info":"P4 (doc/assumption)"}
SEV_ORDER = {"Critical":0,"High":1,"Medium":2,"Low":3,"Info":4}

def framework_map(category):
    toks = []
    for pat in ["STRIDE","LINDDUN","ATLAS","MASVS","ASVS","CWE-\\d+","LLM0?\\d+","OWASP LLM","Agentic","API\\d?:?","SSDF","SLSA","SCVS","GDPR","NIST"]:
        for m in re.findall(pat, category):
            if m not in toks: toks.append(m)
    # always note STRIDE if a S/T/R/I/D/E word present
    return "; ".join(toks) if toks else category[:80]

def likelihood(actor, sev, residual):
    a = (actor or "").lower(); r = (residual or "").lower()
    if "admin" in a or "cloud" in a or "supply" in a or "insider" in a: base = "Low"
    elif "injection" in a or "thief" in a or "paired peer" in a or "processor" in a: base = "Medium"
    else: base = "Medium"
    # nudge from explicit residual wording
    if r.startswith("high") or "h (" in r: base = "Medium-High"
    return base

def fam_of(tid):
    m = re.match(r"(T-[A-Z]+)-", tid)
    return m.group(1) if m else "T-CRY"

rows = []
# 88 from TSV: id, severity, category, component, title, attackPath, existingMitigation, gap, residualRisk
with open(TSV) as f:
    for line in f:
        p = line.rstrip("\n").split("\t")
        if len(p) < 9: p += [""]*(9-len(p))
        tid, sev, cat, comp, title, ap, mit, gap, res = p[:9]
        rows.append(dict(id=tid, severity=sev, category=cat, component=comp, title=title,
                         attack=ap, mitig=mit, gap=gap, residual=res))

# 18 inline ios/privacy rows (id, severity, category, component, title, attack, mitig, gap, residual)
inline = [
 ("T-IOS-01","Medium","Information Disclosure / LINDDUN Disclosure (MASVS-STORAGE-1)","BurnBarWidgetSnapshot.swift:86-92, TextExpansionInbox.swift:29-38","App Group container data not file-protected","App Group files written via Data.write(.atomic) with no protection class; keyboard/widget extensions have no data-protection entitlement; readable from a locked stolen device or Finder backup","Main-app entitlement floor; chat uses .complete","App Group container outside entitlement floor; no explicit protection class on shared-container writes","Disclosure of text-expansion snippet bodies, keyboard inbox, cost/model aggregates (not key material)"),
 ("T-IOS-02","High","Spoofing / Elevation (MASVS-AUTH-1)","AuthGateView.swift, OpenBurnBarMobileApp.swift","No app-level biometric/passcode re-auth gate","Lost-but-unlocked iPhone gives full app access: send prompts, control paired Mac, read chat, trigger panic; Firebase session persists; WhenUnlocked vault/escrow keys decrypt freely","Per-sensitive-ComputerUse-action step-up for some flows","No global Face ID/passcode gate to enter app or view chat/vault data","Full takeover of a high-trust endpoint on an unlocked unattended device"),
 ("T-IOS-03","Medium","Information Disclosure (MASVS-PLATFORM-3 screenshot/recording)","ScreenPrivacyGuard.swift; InlineAgentMirrorView.swift:222, AgentWatchView.swift:92","Mirror privacy mask is surface-scoped, not app-wide","Screen recording/AirPlay/app-switcher snapshot captures chat, revealed provider-key SecureFields, vault recovery-key entry, dashboards; only the live Mac mirror is masked","screenPrivacyGuard() on two mirror views; SecureField hides input","No app-wide app-switcher cover; sensitive non-mirror screens recordable","Leak of conversation content, provider credentials, recovery keys via recording/recents"),
 ("T-IOS-04","Medium","Information Disclosure (MASVS-NETWORK / data minimization)","AgentReplyNotificationService.swift:36-45,188-206,260","Push preview/title carried as plaintext in APNs payload","Pushes put title/preview into UNNotificationContent.body and userInfo; APNs sees them and they render on lock screen; previews 'generic today' is not a code-level guarantee","Markdown flattening; device fan-out respects auth state","No enforced redaction or mutable-content + NSE to fetch/decrypt body client-side","Sensitive agent reply text could surface on lock screen and transit APNs cleartext"),
 ("T-IOS-05","Medium","Information Disclosure (MASVS-STORAGE-2 pasteboard)","SmartHubDisplaySettingsAdapter.swift:106, HermesSettingsView.swift:2101, MercuryLiveSheet.swift:1969","Sensitive material copied to system pasteboard without expiry/local-only","UIPasteboard.general.string writes with no expirationDate/localOnly; can include bootstrap/refresh URLs, curl snippets w/ bearer tokens, Mac clipboard; readable by other apps + Universal Clipboard","Size bound on Mac-clipboard paste","No UIPasteboard expirationDate/localOnly; no clearing","Token/URL/clipboard disclosure to other apps and Handoff-paired devices"),
 ("T-IOS-06","Low","Tampering / Spoofing (MASVS-PLATFORM-1 IPC)","TextExpansionInbox.swift:42-71, KeyboardViewController.swift:76-95","App Group is a confused-deputy surface between app and extensions","Keyboard writes snippets to shared snapshot+inbox; app drains and cloud-syncs; a compromised/replaced extension or App-Group-entitled sibling could plant snippets the app later trusts and uploads; Darwin notification unauthenticated","Snippet validation in makeSnippet; dedup by id","No integrity/authenticity check on App Group payloads","Stored-text injection into outbound agent messages via auto-synced snippets"),
 ("T-IOS-07","Low","Tampering / Spoofing (MASVS-PLATFORM-2 deep links)","OpenBurnBarMobileApp.swift:137-208","Deep-link/URL-scheme handler routes attacker-influenced params","burnbar:// scheme unverified (no Universal-Link verification); any app/page can invoke burnbar://assistants?... to drive navigation/stash thread/trigger ShowAgentWatch; threadId unsanitized into Firestore-scoped view","Prompts ignored on public path; pairing-code origin-restricted; host switch allow-listed","Custom scheme not cryptographically attributable to a caller","Phishing/UI-redress and forced navigation; impact bounded to social engineering"),
 ("T-IOS-08","Low","Information Disclosure / Spoofing (MASVS-PLATFORM-1)","OpenBurnBarKeyboard/Info.plist:31-32 (RequestsOpenAccess=true)","Keyboard Open Access expands attack surface","Open Access grants App Group + potential network; no network code today but a poisoned build could exfiltrate keystrokes once Full Access granted (classic iOS keylogger risk)","No network egress in current code; no input persistence","Open Access requested broadly; no App-Group-only justification gating","Latent keylogger surface if a malicious update ships; current build benign"),
 ("T-IOS-09","Medium","Tampering / Information Disclosure (MASVS-CRYPTO-2 key protection)","CloudVaultCrypto.swift:1414-1429, iOSDeviceKeypair.swift:101-116","Vault/escrow keys not biometry- or Secure-Enclave-bound","32-byte vault key and P-256 escrow private key stored as raw kSecValueData (WhenUnlockedThisDeviceOnly), not SE-wrapped or .biometryCurrentSet-gated; any app-context code on an unlocked device reads the vault key and decrypts CloudVault","Device-only accessibility; ComputerUse uses a separate SE+biometry proof credential","Vault and escrow secrets are not SE-wrapped or biometric-gated despite an implemented pattern elsewhere","Whole-vault decryption from app context on an unlocked device"),
 ("T-IOS-10","Info","Tampering (MASVS-RESILIENCE-1)","(absence) no jailbreak/integrity checks in OpenBurnBarMobile/","No jailbreak/runtime-integrity assumption stated or enforced","On a jailbroken device Keychain ACLs and file protection can be bypassed; all keys/data become reachable","None on-device (App Attest is server-side anti-fraud)","No jailbreak detection/anti-tamper; assumption undocumented","Determined attacker with jailbroken target gets full local access (accepted-risk class)"),
 ("T-IOS-11","Low","Information Disclosure (MASVS-STORAGE-1)","MobileDataProtectionBootstrap.swift:4,41-46","Launch-time protection sweep is bounded and may miss files","Recursive sweep stops after 2000 items; large Caches/Documents tree leaves later items at default; third-party SDK caches (Firestore persistence) may land outside the swept intent","Entitlement floor applies to app container; chat self-protected","Sweep best-effort and capped; Firestore local-cache protection class not asserted","Marginal; residual is backup-exclusion gaps and App-Group SDK files"),
 ("T-PRV-01","High","LINDDUN Disclosure + Identifying; STRIDE Information Disclosure","functions/src/callables/voipPush.ts:39-87, apnsSender.ts:141-221, fcmAndroidSender.ts:57-106","VoIP/call push leaks cleartext caller display name + call graph to Apple & Google","triggerVoIPCall writes voip_outbound/fcm_outbound with cleartext displayName/caller_name + stable callId/connectionId/pairedDeviceId; APNs+FCM sub-processors receive and can log them, building a social/device graph over time","Entitlement gate; App Check; doc admits the leak","Display name unnecessary for wake-up; connection_id/paired_device_id are stable correlators","High; every call exposes caller identity + persistent device link to two external processors"),
 ("T-PRV-02","High","LINDDUN Non-compliance (right-to-erasure) + Disclosure; GDPR Art.17","functions/src/callables/voipPush.ts:57,78, accountDeletion.ts:112-113","Push-queue root collections never deleted on account erase, no TTL","eraseUserCloudData walks only users/{uid}+workspaces+secret_refs; voip_outbound/fcm_outbound are TOP-LEVEL with uid+cleartext displayName/callId/connectionId/pairedDeviceId/tokens and have no TTL; persist indefinitely after account deletion","Default-deny client reads; terminal-state docs not re-read","No TTL; no deletion in eraseUserCloudData; no scheduled purge","High; erasure contract violated for call metadata; unbounded retention of identifying push payloads"),
 ("T-PRV-03","High","LINDDUN Disclosure + Unawareness; STRIDE Information Disclosure","OpenBurnBarMobile/App/AppDelegate.swift:53-85, AgentLens/App/AgentLensApp.swift:1168-1202","Client crash reports (iOS+macOS) ship to Sentry with no scrubber/consent","Client Sentry started with no beforeSend/beforeBreadcrumb/sendDefaultPii=false; default breadcrumbs (network URLs+params, lifecycle, logs) + exception context can carry plaintext prompts/paths/peer IDs/tokens to Sentry SaaS; no consent UX; macOS user-id seed uses real name","tracesSampleRate=0; DSN absent in OSS builds; server Sentry scrubbed","Client/server scrubbing asymmetry; no client beforeSend; no consent UX","High for internal/CI-DSN builds; uncontrolled PII/prompt egress to third-party processor"),
 ("T-PRV-04","Medium","LINDDUN Disclosure; STRIDE Information Disclosure","functions/src/logging.ts:16-29,48-90","Server log scrubber is pattern-based; numeric/non-pattern PII bypasses","scrubValue only transforms strings; numbers/booleans pass through; values not matching {email,IPv4,sk-|AIza|ya29.|eyJ,16-digit CC} logged verbatim; new provider key formats not all covered; free-form String(error) may carry tokens/paths","Known-prefix + key-name redaction + 1024-char truncation","No allowlist model; numeric values unscrubbed; depends on sensitive field naming","Medium; log/Sentry secret disclosure on edge fields"),
 ("T-PRV-05","Medium","LINDDUN Linking + Detecting + Disclosure; SSE leakage","functions/src/callables/encryptedSearchIndex.ts:44-67, encryptedSearch.ts:618-757","Encrypted-search metadata: facets + posting graph + access patterns enable inference","Server observes co-occurring tokenHashes per chunk, posting fan-out, query-time hashes, result sizes/scores, and cleartext facets (provider/model/deviceId/cost/tokens/startTime); frequency+facet analysis yields providers used, spend, timeline, device, repeated query topics","Per-user HKDF keying; sealed snippets/titles; bounded hash counts","No padding/dummy-posting noise; cleartext facets; query hashes sent in clear","Medium; content-adjacent inference and behavioral profiling by curious/compromised operator"),
 ("T-PRV-06","Low","LINDDUN Linking + Disclosure + Non-compliance; data minimization","functions/src/agentNotifications.ts:300-321,494-505","Agent-notification events retain provider identity + thread graph with no TTL","Each reply writes users/{uid}/agent_notification_events with runtime/providerLabel/title/threadId/messageId/sourcePath revealing which agent answered + reply cadence; FCM data carries runtime+deep_link to Google; covered by account-erase but never expires","Generic preview; covered by account-erase tree","No TTL; provider label in title/FCM is a usage-fingerprint leak","Low/Medium; provider-usage fingerprint + reply timing"),
 ("T-PRV-07","Low","LINDDUN Non-repudiation + Linking","functions/src/voipPush.ts:79-104, agentNotifications.ts:551-562","Non-repudiation gap / push-token correlation across providers","Stable pairedDeviceId/connection_id/push tokens flow to APNs+FCM and stored in queue docs; a processor with cross-service visibility (or BurnBar) links a device across sessions and ties call events to a user; queue timestamps prove a call was attempted","Tokens rotate on reinstall; per-user scoping","Identifiers long-lived; no rotation of connectionId correlator","Low"),
]
for r in inline:
    rows.append(dict(id=r[0], severity=r[1], category=r[2], component=r[3], title=r[4],
                     attack=r[5], mitig=r[6], gap=r[7], residual=r[8]))

# sort: severity then id
rows.sort(key=lambda r:(SEV_ORDER.get(r["severity"],9), r["id"]))

cols = ["id","title","category","framework_mapping","component","data_flow","asset","threat_actor",
        "preconditions","attack_path","impact","likelihood","severity","existing_controls","gaps",
        "residual_risk","detection","tests","evidence","owner","priority","cure53_relevance"]

def clip(s, n=600):
    s = (s or "").replace("\n"," ").strip()
    return s if len(s)<=n else s[:n-1]+"…"

out_csv = os.path.join(TM,"threat-register.csv")
with open(out_csv,"w",newline="") as f:
    w = csv.writer(f, quoting=csv.QUOTE_ALL)
    w.writerow(cols)
    for r in rows:
        fam = fam_of(r["id"]); meta = FAM.get(fam, FAM["T-CRY"])
        actor, asset, dflow, owner, precond, detect = meta
        sev = r["severity"]
        cure = "HIGH — prioritize for audit" if sev in ("Critical","High") else ("Standard" if sev in ("Medium",) else "Low")
        w.writerow([
            r["id"], clip(r["title"],200), clip(r["category"],160), framework_map(r["category"]),
            clip(r["component"],200), dflow, asset, actor, precond, clip(r["attack"]),
            IMPACT.get(sev,sev), likelihood(actor,sev,r["residual"]), sev, clip(r["mitig"]),
            clip(r["gap"]), clip(r["residual"]), detect, "See security-test-plan.md ("+fam+"); automated regression recommended",
            clip(r["component"],200), owner, PRIORITY.get(sev,sev), cure,
        ])

# human-readable md grouped by severity
out_md = os.path.join(TM,"threat-register.md")
sev_groups = {}
for r in rows: sev_groups.setdefault(r["severity"], []).append(r)
with open(out_md,"w") as f:
    f.write("> **CONFIDENTIAL — BurnBar security package.** Independently code-verified at HEAD `5416ef780`. Share with Cure53 out-of-band; do not publish.\n\n")
    f.write("# BurnBar Threat Register (human-readable)\n\n")
    f.write("Machine-readable companion: [`threat-register.csv`](threat-register.csv). Per-domain raw findings: [`_evidence/`](_evidence/). ")
    f.write("Severity model in [`_evidence/_INDEX.md`](_evidence/_INDEX.md §10). Total threats: **%d** (" % len(rows))
    f.write(", ".join("%d %s" % (len(sev_groups.get(s,[])), s) for s in ["Critical","High","Medium","Low","Info"] if sev_groups.get(s)))
    f.write(").\n\n")
    for s in ["Critical","High","Medium","Low","Info"]:
        g = sev_groups.get(s)
        if not g: continue
        f.write("## %s (%d)\n\n" % (s, len(g)))
        for r in g:
            fam = fam_of(r["id"]); meta = FAM.get(fam, FAM["T-CRY"])
            actor, asset, dflow, owner, precond, detect = meta
            f.write("### %s — %s\n" % (r["id"], r["title"]))
            f.write("- **Category / framework:** %s\n" % r["category"])
            f.write("- **Component / evidence:** `%s`\n" % r["component"])
            f.write("- **Actor:** %s | **Asset:** %s | **Data flow:** %s\n" % (actor, asset, dflow))
            f.write("- **Preconditions:** %s\n" % precond)
            if r["attack"]: f.write("- **Attack path:** %s\n" % r["attack"])
            if r["mitig"]: f.write("- **Existing mitigation:** %s\n" % r["mitig"])
            f.write("- **Gap:** %s\n" % r["gap"])
            if r["residual"]: f.write("- **Residual risk:** %s\n" % r["residual"])
            f.write("- **Detection:** %s | **Owner:** %s | **Priority:** %s\n\n" % (detect, owner, PRIORITY.get(s,s)))
print("rows:", len(rows))
print("csv:", out_csv)
print("md:", out_md)
import collections
c = collections.Counter(r["severity"] for r in rows)
print("by severity:", dict(c))
