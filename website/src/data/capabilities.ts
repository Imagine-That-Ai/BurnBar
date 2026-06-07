/**
 * Capability decks for the two flagship companion experiences:
 *
 *   • Floo        — your phone and your Mac, joined.
 *   • Agent Control — let an agent use the computer, only when you say so.
 *
 * Copy rule for this file (and everywhere it renders): say what it does for
 * the person and why it is safe. Never name the transport, the codec, the
 * protocol, or any internal subsystem. People want the feature and the
 * promise that it is private — not the plumbing.
 *
 * The brand name lives in one place (`FLOO.name`) so it can be changed in a
 * single edit and stay consistent across the homepage, product page, the
 * dedicated page, navigation, and the claims matrix.
 */

/** The phone ⇄ Mac experience. One constant, referenced everywhere. */
export const FLOO = {
  /** Marketing name. Change here, changes everywhere. */
  name: "Floo",
  /** The straight-faced expansion. */
  expansion: "File & Live Object Overlay",
  /** The wink. Surface it as an aside, never as the headline. */
  expansionWhimsical: "Fast Link Over Owl",
  /** One-line value prop. */
  tagline: "Your phone and your Mac, joined.",
  /** Honest shipping posture — mirrors the surfaces matrix. */
  status: "rolling-out" as const,
  statusLabel: "Built · rolling out",
  href: "/floo"
};

export interface Capability {
  id: string;
  /** Verb-first, benefit-first. No nouns-as-features. */
  title: string;
  /** One or two plain sentences. What the person gets. */
  blurb: string;
  /** Internal only — never rendered. Traces the claim to the app. */
  evidence: string;
}

/** What Floo does, in the order a person would discover it. */
export const FLOO_CAPABILITIES: Capability[] = [
  {
    id: "see",
    title: "See your Mac from your phone",
    blurb:
      "Open a live view of your Mac on your iPhone or iPad — the whole desktop, or just the one window you care about. Watch a long agent run from the couch.",
    evidence: "AgentLens/Services/Media/ScreenCapturePipeline.swift; AgentWatch surfaces"
  },
  {
    id: "control",
    title: "Reach in and take over",
    blurb:
      "Tap, scroll, and type on your Mac straight from your phone. Touch a text field and your keyboard rises and zooms to it — no pinching, no hunting.",
    evidence: "ComputerUse phone-as-controller; SmartZoomContextProvider.swift"
  },
  {
    id: "files",
    title: "Send a file in a tap",
    blurb:
      "Move a file, a screenshot, or a photo between Mac and phone instantly — in either direction. It picks up where it left off if your signal drops.",
    evidence: "AgentLens/Services/Media/ (file transfer); MediaFileTransferServiceFactory"
  },
  {
    id: "call",
    title: "Call your Mac",
    blurb:
      "Start a voice or video call between your devices. Your phone rings like any call; answer and you are connected — even when the app was closed.",
    evidence: "VoIPCallTrigger.swift; CallKit + push wake"
  },
  {
    id: "clipboard",
    title: "One clipboard across both",
    blurb:
      "Copy on your Mac, paste on your phone. Copy on your phone, paste on your Mac. Whatever you just grabbed is already on the other screen.",
    evidence: "AgentLens/Services/ComputerUse/Mac/RemoteClipboardController.swift"
  },
  {
    id: "unlock",
    title: "Unlock your Mac from your phone",
    blurb:
      "Walk up to a locked Mac and unlock it from your phone with Face ID or Touch ID. Public rollout stays gated on runtime evidence, and the flow is designed so passwords never belong in logs or server-side storage.",
    evidence: "RemoteUnlock* (sealed credential, biometric-gated)"
  }
];

/** Floo's safety promises — the part that earns the feature. */
export const FLOO_PROMISES: string[] = [
  "It only ever connects your own devices — the ones you've paired and trust.",
  "Public rollout stays gated until runtime evidence proves the paired-device encryption boundary.",
  "Every connection asks first. Decline and it backs off.",
  "One tap ends it — the screen view, the call, the control, all of it, instantly."
];

/** The agent-uses-the-computer experience. */
export const CONTROL = {
  name: "Agent Control",
  tagline: "Let an agent use the computer — only when you say so.",
  status: "rolling-out" as const,
  statusLabel: "Direct download · behind your grant",
  href: "/control"
};

export const CONTROL_CAPABILITIES: Capability[] = [
  {
    id: "watch",
    title: "Watch it work",
    blurb:
      "See exactly what your agent is doing as it does it — every click, every step — live on your Mac or mirrored to your phone. Nothing happens out of sight.",
    evidence: "Agent Watch (read-only mirror + action log)"
  },
  {
    id: "browser",
    title: "Let it run the browser for you",
    blurb:
      "Hand off the busywork — fill the form, pull the data, click through the flow. The agent drives a real browser while you keep your hands free.",
    evidence: "Browser computer-use (7 tool kinds, evidence screenshots)"
  },
  {
    id: "mac",
    title: "Let it use the Mac",
    blurb:
      "Beyond the browser, the agent can use your apps the way you would — when you grant it that reach, and never before.",
    evidence: "Mac system input + accessibility inspector (direct-download build only)"
  },
  {
    id: "approve",
    title: "Approve each step — or trust it within your lines",
    blurb:
      "Run it tap-by-tap, approving every action. Or set the boundaries once and let it move freely inside them. You choose how much rope, per task.",
    evidence: "Trust modes (manual / step / trusted) + scope rules"
  },
  {
    id: "boundaries",
    title: "Draw the off-limits zones",
    blurb:
      "Mark windows, sites, and screen areas the agent may never touch — password fields, your banking tab, anything private. Deny always wins.",
    evidence: "Scope rules + deny registry + on-screen deny regions"
  },
  {
    id: "record",
    title: "A tamper-proof record of everything",
    blurb:
      "Every action the agent takes is written to a record that can't be quietly edited after the fact. You can always see precisely what happened.",
    evidence: "Content-addressed audit chain on disk"
  }
];

export const CONTROL_PROMISES: string[] = [
  "It does nothing until you grant it — and you grant powers per task, not forever.",
  "Grants expire on their own; switch tasks and the reach resets to zero.",
  "Stop it instantly — a keyboard shortcut, a gesture on your phone, or the moment the lock screen appears.",
  "Prefer it never have this reach? The Mac App Store build ships without it entirely. This lives only in the direct download."
];
