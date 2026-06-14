#!/usr/bin/env python3
"""Generate security-claims.md from the adversarially-verified _claims.json."""
import json, os
EV = os.path.dirname(os.path.abspath(__file__)); TM = os.path.dirname(EV)
claims = json.load(open(os.path.join(EV, "_claims.json")))
def cid(c): return c.get("claimId","?")
claims.sort(key=lambda c: int(cid(c)[1:]) if cid(c)[1:].isdigit() else 99)

CAT = {
 "C1":"Confidentiality","C2":"Confidentiality","C3":"Confidentiality","C10":"Confidentiality","C13":"Confidentiality",
 "C4":"Authentication/Authorization","C8":"Authentication/Authorization","C11":"Authentication/Authorization",
 "C5":"Authentication/Authorization","C9":"Integrity/Authenticity","C12":"Replay/Freshness",
 "C6":"Agentic AI","C7":"Agentic AI","C14":"Non-claim discipline",
}
SHORT = {
 "C1":"Cloud cannot read current Gateway message/event bodies","C2":"Cloud cannot read CloudVault at-rest content",
 "C3":"Attachments sealed client-side before upload","C4":"Gateway bearer alone insufficient (PoP required)",
 "C5":"Revoked device cannot receive newly-sealed material","C6":"Untrusted content cannot directly trigger high-impact action",
 "C7":"High-risk grants need single-use local-auth bound to op hash","C8":"Only pinned paired devices exchange Gateway msgs",
 "C9":"Iroh pairing records cannot be spoofed/replayed","C10":"Provider creds not in Firestore plaintext (KMS)",
 "C11":"Object-level authz: no cross-user access","C12":"Old messages/pairing codes cannot be replayed",
 "C13":"Logs/crash/push contain no plaintext bodies/secrets","C14":"BurnBar does NOT claim production Signal E2EE",
}
BADGE = {"Defensible":"✅ Defensible","Partial":"🟡 Partially defensible","NotDefensible":"❌ Not defensible","Unknown":"❓ Unknown"}

out = os.path.join(TM,"security-claims.md")
f = open(out,"w")
f.write("> **CONFIDENTIAL — BurnBar security package.** Independently code-verified at HEAD `5416ef780`. Share with Cure53 out-of-band; do not publish.\n\n")
f.write("# Security Claims Matrix\n\n")
f.write("Each claim below was **adversarially verified against current HEAD code** — an independent reviewer tried to *refute* it before assigning a status. Status legend: ")
f.write("**✅ Defensible** (code clearly supports it on current paths) · **🟡 Partially defensible** (true with material caveats/scope limits) · **❌ Not defensible** (code contradicts it) · **❓ Unknown** (needs deployed config/IAM/runtime evidence). ")
f.write("Raw verifier output: [`_evidence/_claims.json`](_evidence/_claims.json). Per-domain claim assessments: [`_evidence/NN-*.md`](_evidence/).\n\n")
f.write("**Headline:** of the 14 load-bearing claims, **%d Defensible, %d Partial, %d Not-defensible, %d Unknown**. " % (
    sum(1 for c in claims if c["status"]=="Defensible"), sum(1 for c in claims if c["status"]=="Partial"),
    sum(1 for c in claims if c["status"]=="NotDefensible"), sum(1 for c in claims if c["status"]=="Unknown")))
f.write("No headline claim is outright *false*, but **10 of 14 carry material caveats** — the safe wording below states each caveat. The single most important discipline: never collapse a Partial into an absolute (\"zero-knowledge\", \"end-to-end\", \"never\", \"cannot ever\").\n\n")

f.write("## Summary table\n\n")
f.write("| ID | Category | Claim | Status | Confidence |\n|---|---|---|---|---|\n")
for c in claims:
    f.write("| %s | %s | %s | %s | %s |\n" % (cid(c), CAT.get(cid(c),"—"), SHORT.get(cid(c),c["claim"][:60]), BADGE.get(c["status"],c["status"]), c.get("confidence","—")))
f.write("\n")

f.write("## Per-claim detail (claim · status · evidence · safe vs unsafe wording · gaps)\n\n")
for c in claims:
    f.write("### %s — %s  \n" % (cid(c), SHORT.get(cid(c), c["claim"][:80])))
    f.write("**Claim as tested:** %s  \n" % c["claim"].strip().strip('"'))
    f.write("**Status:** %s  **Confidence:** %s  **Category:** %s\n\n" % (BADGE.get(c["status"],c["status"]), c.get("confidence","—"), CAT.get(cid(c),"—")))
    ra = c.get("refutationAttempt","").strip()
    if ra and ra.lower() != "covered above":
        f.write("**Refutation attempt (what the verifier tried to break, and what held / broke):**\n\n")
        f.write("> " + ra.replace("\n","\n> ") + "\n\n")
    ev = c.get("evidence",[])
    if ev:
        f.write("**Evidence (file:line):**\n")
        for e in ev: f.write("- %s\n" % e)
        f.write("\n")
    if c.get("safeWording"):
        f.write("**✅ SAFE wording (defensible to publish):**\n\n> %s\n\n" % c["safeWording"].strip())
    if c.get("unsafeWording"):
        f.write("**⛔ UNSAFE wording (do NOT publish):**\n\n> %s\n\n" % c["unsafeWording"].strip())
    g = c.get("gaps",[])
    if g:
        f.write("**Open gaps / what would raise confidence:**\n")
        for x in g: f.write("- %s\n" % x)
        f.write("\n")
    f.write("---\n\n")

f.write("""## Non-Claims — what BurnBar explicitly does NOT guarantee

These are deliberate boundaries. Stating them is a security control (it prevents users from over-trusting the system) and they must appear in any user-facing security page.

- **Not a universal end-to-end-encrypted product.** Only specific sealed sub-flows are E2E. The cloud sees rich **metadata** by design: user/device/client/destination IDs, timestamps, sizes, counters, statuses, sequence, model/provider/cost facets, search token/semantic hashes, push tokens, routing.
- **No protection of plaintext on a compromised endpoint or local agent runtime.** Phones, Macs, Android devices, and local agents necessarily see plaintext before sealing / after opening. Endpoint compromise is intentionally outside the cryptographic boundary.
- **No forward secrecy / post-compromise security** beyond the ephemeral relay leg. The relay scheme self-documents *no static-leg PFS and no KCI protection*; the gateway ratchet has no one-time prekeys/PQXDH.
- **Provider credentials are backend-decryptable**, not zero-knowledge. Secret Manager + KMS protect against direct Firestore compromise; a service account with the right IAM/KMS can decrypt. IAM/KMS is the real boundary.
- **No production Signal / libsignal end-to-end encryption.** The Signal at-rest lane is flag-OFF and fails open to the legacy AES-256-GCM seal; the live libsignal session lane has no production callers. Do not market "Signal Protocol", Double Ratchet, PFS/PCS, or post-quantum.
- **Revocation does not claw back already-cached plaintext.** A device that cached a vault key before revocation can read pre-revocation content until rotation completes; rotation is client-driven and best-effort.
- **No anonymity, no full metadata privacy, no screenshot/shoulder-surf protection** across the whole app, and **no protection against a fully-compromised paired device**.
- **Model providers see everything routed to them.** "The assistant cannot read your messages" is false by construction for the gateway/model lane.

## Banned phrasings (enforced by the repo's own `verify-signal-honesty-copy.sh` / license-posture gates)
"zero-knowledge" (unqualified) · "server learns nothing" / "server searches without reading it" · "Signal-quality privacy" for the whole product · "semantic memory is private from us" · "revocation immediately makes old data safe" · "encrypted database" (while SQLCipher codec is absent / legacy plaintext unmigrated) · unconditional "end-to-end encrypted" / "no one in the middle, including us" / "API keys never leave the device" / "never appears anywhere you didn't put it".
""")
f.close()
print("wrote", out)
print("claims:", len(claims), {s: sum(1 for c in claims if c["status"]==s) for s in ["Defensible","Partial","NotDefensible","Unknown"]})
