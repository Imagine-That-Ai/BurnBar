/**
 * Licensing + encryption trust data for burnbar.ai — the /trust surface.
 *
 * Copy rule for this file (and everywhere it renders): say what it means for
 * the person, in plain language, and never overclaim. Internal jargon, library
 * internals, and protocol names stay out of rendered fields.
 *
 * Facts that can drift are not hand-typed here: the SPDX id comes from
 * `SITE.license`, the Signal-library pin and claim lines come from
 * `crypto-claims.generated.ts` (CI drift-gated against the crypto registry).
 * `evidence` fields are internal only — never rendered. They trace each claim
 * to the repo so a reviewer can audit the sentence.
 *
 * The brand name lives in one place (`HORCRUX.name`) so it can be changed in a
 * single edit — same pattern as `FLOO.name` in capabilities.ts.
 */
import { SITE } from "./site";
import { LIBSIGNAL_PIN, LIBSIGNAL_ROLLOUT_STATUS } from "./crypto-claims.generated";

/** The sealed-envelope gateway layer. One constant, referenced everywhere. */
export const HORCRUX = {
  /** Marketing name. Change here, changes everywhere. */
  name: "Horcrux",
  /** The straight-faced expansion. */
  expansion: "Hermetic Object Relay Crypto — Re-keyed Untrusted eXchange",
  /**
   * The wink. Surface it as an aside, never as the headline — and note it is
   * true on its face: the relay in the middle can't read a thing.
   */
  expansionWhimsical: "Honestly, Our Relay Can't Read User eXchanges",
  /** One-line value prop. */
  tagline: "Our own seal, so the open upstreams stay clean.",
  /**
   * The approved descriptive family — use this wherever the name needs no
   * mystique, or alongside the name on first mention.
   */
  descriptiveFallback:
    "our own sealed-envelope layer — a hardened, forward-secret encrypted gateway",
  /**
   * The honest boundary, stated everywhere the seal is praised: the gateway
   * decrypts to run the model. The seal is phone ⇄ gateway, not you ⇄ model.
   */
  honestBoundary:
    "The seal protects the path: your phone to our gateway, past every relay in between. " +
    "At the gateway it is opened to run the model — we don't say “the assistant can't read " +
    "your messages,” because that would be false.",
  href: "/trust"
};

/** License posture. Rendered on /trust, the homepage, and /legal/source. */
export const LICENSING = {
  /** SPDX id — single source of truth is SITE.license; never redeclare it. */
  spdx: SITE.license,
  /** The MIT→AGPL relicense commit. Internal traceability — never rendered. */
  relicenseCommit: "abd54d180",
  /** The past stays open the way it shipped. */
  mitHistoryLine:
    "Historical MIT snapshots stay MIT — the relicense changes the future, not the past.",
  /** Official Signal library pin (CI-enforced; see crypto-claims.generated.ts). */
  libsignalPin: LIBSIGNAL_PIN,
  /**
   * Honest rollout posture for every Signal-library lane — interpolated from
   * the generated module so a readiness flip updates it everywhere at once.
   */
  libsignalStatus: LIBSIGNAL_ROLLOUT_STATUS,
  sourceOfferHref: "/legal/source",
  githubHref: SITE.github
};

export interface ClaimPair {
  /** What we claim — plain language, present tense, true at HEAD. */
  claim: string;
  /** What we don't claim — the matching honest boundary. */
  not: string;
  /** Internal only — never rendered. Traces the pair to repo evidence. */
  evidence: string;
}

/** The "what we claim / what we don't" ledger for the license + seal story. */
export const CLAIM_PAIRS: ClaimPair[] = [
  {
    claim:
      "The product is AGPL-3.0-only at HEAD. Run it, read it, fork it — and if you serve it " +
      "over a network, your users get the source too.",
    not: "We don't relicense the past. Every shipped MIT snapshot stays MIT.",
    evidence: "LICENSE; LICENSES/MIT-legacy.txt; NOTICE; commit abd54d180"
  },
  {
    claim:
      "The official Signal library is pinned and wired in for device-to-device lanes and " +
      "at-rest sealing.",
    not:
      "We don't claim it's live. It is wired in but off by default — per-domain flag, " +
      "staged rollout, instant revert — behind a fail-closed readiness gate.",
    evidence: "packages/libsignal-bridge/package.json; third_party/libsignal/runtime-readiness.json"
  },
  {
    claim:
      "Phone ⇄ gateway traffic rides a hardened encrypted gateway: keys pinned to your " +
      "devices, safety-code pairing, forward secrecy, downgrade attempts refused.",
    not:
      "We don't say “the assistant can't read your messages.” The gateway decrypts to run " +
      "the model — that is what running a model means.",
    evidence: "docs/security/ADR-001-crypto-architecture.md §5–6; gateway adapter suites"
  },
  {
    claim:
      "These claims are wired to the crypto registry: the encryption claim lines are " +
      "generated, and the build goes red the moment they drift from it.",
    not:
      "We don't claim an external audit. The gates are ours; an independent audit will be " +
      "linked here when it happens.",
    evidence:
      "website/scripts/generate-crypto-claims.mjs; packages/data-domains/codegen.mjs; " +
      ".github/workflows/fast-feedback.yml"
  }
];
