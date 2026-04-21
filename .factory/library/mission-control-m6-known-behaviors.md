## Mission Control m6 known behavior notes (2026-04-19)

- `mission.approve` currently **does not** reject outside `awaiting_approval`; it stamps approval metadata and keeps `status` unchanged when status is `cancelled` (store path: `MissionControlStore.approveMission`).
- `mission.cancel` currently has **no non-terminal guard** and sets status to `cancelled` whenever the mission exists (store path: `MissionControlStore.missionCancel`).
- Treat these as current daemon behavior during validation/review unless and until contracts and implementation are aligned.
