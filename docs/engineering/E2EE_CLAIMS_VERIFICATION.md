# E2EE / Signal Claim Verification (diligence follow-up #2)

> Verified 2026-07-08 against `origin/main`. **Outcome: the generated trust-page crypto claims are
> accurate and CI-gated. No public trust-page correction was warranted** — this corrects a finding in the
> 2026-07-08 diligence review that was based on the audit snapshot, not `main`.

## What the diligence review flagged

The security lane rated Security 8.5/10 but raised, as its top SERIOUS item, an **"E2EE
marketing-vs-reality gap"**: the `libsignal` packages self-describe as *"Inert/flag-off: not
imported by any app yet,"* so if user-facing materials claimed "Signal-Protocol E2EE in
production," that would be untrue. The lane reached this from the snapshot's package note and
explicitly could not confirm the live claim-rendering path.

## What is actually true on `main`

**libsignal is genuinely flag-off at runtime** (confirmed — the concern's premise is real):
- `packages/libsignal-protocol/package.json` — *"Inert/flag-off: not imported by any app yet."*
- `docs/signalification/REMAINING_SIGNAL_WORK_HANDOFF.md` — *"production Signal writes are still
  flag-OFF … Do not claim 10/10, GA-ready, or production-activated until every gate below is
  closed."*

**But the generated trust-page claims already say exactly that, and a CI gate enforces that path**
(the mitigation the snapshot didn't show):
- `website/src/data/crypto-claims.generated.ts` — the libsignal claims are caveated in the copy
  itself: device-to-device is *"built on Signal's official open-source library … **wired in today,
  not yet activated in production**; activation comes by staged rollout with instant revert,"* and
  at-rest sealing is *"**wired in, not activated in production.**"*
- `website/scripts/generate-crypto-claims.mjs:76-80` — the generator reads
  `third_party/libsignal/runtime-readiness.json` and **fails the build** if `status !== "not_ready"`,
  i.e. the "not activated in production" copy is mechanically forced to be revised the moment
  libsignal is activated. It also (`:112-117`) fails if the wiring evidence or the per-domain
  `signal_at_rest_<domain>_enabled` kill switch is missing ("wired in" must be backed), and
  (`:28`) forbids hand-typing the rollout-status phrase anywhere in `website/src` — it must come
  from the generator.
- `website/CLAIMS.md` describes the *live* at-rest mechanism (CloudVault AES-256-GCM / cloaked
  vectors) accurately, not as Signal.
- Enforcement scripts referenced by the handoff: `verify-signal-honesty-copy.sh`,
  `verify-signal-activation-parity.sh`.

## Verdict

The generated trust-page E2EE claim risk **is already mitigated on `main`, and unusually well** —
caveated copy generated from a single source of truth, with a fail-closed CI gate that forces the
generated trust-page copy to change when libsignal readiness changes. This is a diligence **asset**,
not a gap. It does not mechanically gate every possible future in-app, mobile, or external claim.

**Correction to the 2026-07-08 report:** downgrade the "E2EE marketing-vs-reality gap" from SERIOUS
to a POLISH/EXTERNAL item for the generated trust-page claims. Other in-repo, mobile, or external
claims still need to mirror this caveated language.

## Residual action (owned by Alberto — not a code change)

The only remaining exposure is **outside this repo**: ensure investor/pitch/marketing materials use
the same caveated language ("Signal library wired in, not yet activated in production; live at-rest
protection is CloudVault AES-256-GCM with keys stored through the platform key stores: Keychain and
AndroidKeyStore"). Do not claim hardware-backed Secure Enclave / StrongBox custody for CloudVault
keys unless that storage is implemented and verified. The repo cannot gate copy it doesn't contain.
When libsignal activates, the generator will force the in-repo copy to change — mirror that change in
external materials at the same time.
