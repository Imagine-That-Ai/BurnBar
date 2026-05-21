# Mercury UX Polish Handoff

## Mission

Run a focused UX polish pass on the Mercury mirror/media experience.

This handoff is intentionally non-prescriptive. Do not treat it as a design
brief, visual direction, layout spec, or component prescription. The assigned UI
agent should inspect the live product, identify the highest-leverage polish
opportunities, and use its own product/design judgment to improve the experience.

## Scope

Polish the user-facing Mercury surfaces involved in mirror/media discovery,
request, acceptance, live viewing, interruption, error, recovery, and stop flows.

Relevant starting points:

- `OpenBurnBarMobile/Views/Media/MercuryLiveSheet.swift`
- `OpenBurnBarMobile/Views/Media/ScreenShareViewerView.swift`
- `OpenBurnBarMobile/Services/Media/MediaControlStreamCoordinator.swift`
- `AgentLens/Services/Media/MercuryRouter.swift`
- `docs/HERMES_MEDIA_TRANSPORT.md`
- `docs/runbooks/mercury-streaming-evidence-gates.md`

## Constraints

- Preserve the existing Mercury protocol contracts unless a UX issue exposes a
  real product bug that requires a small behavioral fix.
- Do not fake readiness, performance, connectivity, or benchmark claims.
- Keep the screen-share capability language tied to the live dual-stack paths;
  older peers and non-promoted call surfaces still fall back to v1.
- Preserve accessibility, reduced-motion behavior, and small-screen usability.
- Keep changes scoped to the Mercury/media experience and supporting shared UI.
- Add or update tests when behavior, state, or copy logic changes.

## Expected Output

- Implemented UI/UX polish in the repo.
- A short note explaining what changed and why.
- Verification evidence: build/test commands, simulator/device checks when
  available, and screenshots or screen recordings if the UI changed materially.

## Success Bar

The final experience should feel intentional, responsive, understandable under
failure, and production-ready. The UI agent owns the design direction.
