# P12 — Mercury media surfaces

**Wave 2 (after P04's event-stream idiom) · Surface: media section (initially under `support`; route promotion via P15).**

## Mission

Surface Mercury media on Linux: paired-device list, media session status (screen-share/file-transfer/call state), and the media-control staging readout that backs the `media.control.stage` perf sample. v1 is **observe + stage**: full call UX is gated on W5 (Computer Use/Mercury engine) reaching Linux; render real engine state, never a demo call UI.

## Read first

- README §1–§2; P04 packet (Tauri event-stream pattern).
- macOS oracle: Mercury media views (search `Mercury` under `AgentLens/Views/`); `AgentLens/Views/Chat/MercuryShimmerModifier.swift` for the shimmer idiom.
- Engine reality: master plan §9.6 (W5) — media transport lands separately; this packet consumes whatever `media.control` RPC the daemon exposes today (`BurnBarDaemonServer+RPCObservability.swift` names `media.control.stage`).
- Evidence: `preserved-qemu-portal-mobile/` notes under `docs/linux-port/evidence/mission-001-computer-use-media-mobile/`.

## Data contract

1. Bridge: `media_status` → `{ pairedDevices: {id,name,platform,lastSeenAt}[], activeSession?: {kind:'screen-share'|'file'|'call', state, peer} }`; stage events via Tauri events `mercury://stage` if the daemon streams them.
2. If the daemon lacks a method, the surface renders the **capability-absent** state ("Media engine not yet available on this Linux build") — a named honest state, not an error.
3. Fixtures: 2 paired devices + one active screen-share session.

## W5-F5 outbound Linux capture

The Linux shell media socket is bidirectional: daemon-origin frames still flow to the shell viewer, and shell-origin capture frames now flow back to the daemon as the same `[u32 length][kind][flags][ptsMs][payload]` protocol. During an accepted mirror session, the daemon wraps shell-origin frames with `MediaPacketCodec` and forwards them to the phone as `media.stream.frame`.

The Tauri shell auto-starts outbound capture when `daemon.media.session.state` reports a streaming mirror session and the media socket is connected. For deterministic evidence use `OPENBURNBAR_MEDIA_CAPTURE_TEST=1` and optionally `OPENBURNBAR_MEDIA_CAPTURE_TEST_BUFFERS=<n>`. For real PipeWire capture, provide `OPENBURNBAR_MEDIA_PIPEWIRE_FD` and `OPENBURNBAR_MEDIA_PIPEWIRE_NODE_ID`; optional knobs are `OPENBURNBAR_MEDIA_CAPTURE_CODEC=vp9|av1` and `OPENBURNBAR_MEDIA_CAPTURE_BITRATE_BPS=<bps>`.

Manual QA can call the Tauri commands `media_capture_start_test`, `media_capture_start_pipewire`, `media_capture_stop`, and `media_capture_status`. The shell emits `media-capture-started`, `media-capture-stopped`, and `media-capture-unavailable` events for evidence capture.

## Files

`src/state/mediaStore.ts`; `src/surfaces/media/` (`MediaSection.tsx`, `DeviceRow.tsx`, `SessionStatusCard.tsx`) + tests; mount inside `SupportSurface` below diagnostics (coordinate with P09; Cross-agent receipt); `app.css` `/* ---- P12 media ---- */`.

## Build steps

1. `DeviceRow`: platform glyph, name, last-seen relative time; no actions in v1 beyond "Forget" **only if** the daemon exposes an unpair method.
2. `SessionStatusCard`: kind badge, peer, state timeline (staged → connecting → active → ended) rendered as the step-rail idiom from onboarding.
3. Shimmer for connecting state: CSS gradient sweep, killed by reduced motion.
4. Keep `media.control.stage` measurement untouched (it flows through the existing support-route perf path).

## Required states

Populated / capability-absent / loading / empty ("No paired devices — pair from the mobile app") / error / offline; session sub-states staged/connecting/active/ended.

## A11y / Perf / Tests

- Session state changes announced politely; timeline steps are text, not color-only.
- Tests: capability-absent detection, device list, session timeline transitions from fixture events, five states.

## Done / Forbidden

README §4. Forbidden: fake call controls; WebRTC/library additions (transport is engine-side); renaming `media.control.stage`.
