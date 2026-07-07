## Summary

- Decomposes `AgentLens/Views/Chat/ChatSessionController.swift` from 1951 lines to 433 lines.
- Adds seven focused `ChatSessionController...` extension files, all under 800 lines.
- Regenerates `OpenBurnBar.xcodeproj/project.pbxproj` with XcodeGen so the new files are in the app target.
- Leaves budget/gateway behavior as a pure move; no `BudgetBlockedError` handling was edited.

## Review Map

1. `ChatSessionController.swift`: retained controller state, nested state types, persisted keys, init, and teardown.
2. `ChatSessionControllerBackendGatewayRouting.swift`: moved backend/model selection, gateway availability, Hermes/OpenClaw/Pi auth helpers, and backend switching.
3. `ChatSessionControllerDesktopControlAccess.swift`: moved desktop-control grants, broker wiring, and privileged-action approval.
4. `ChatSessionControllerMemoryExtraction.swift`: moved memory extraction context and drain kick.
5. `ChatSessionControllerPromptSections.swift`: moved prompt section builders and hosted-search auth headers.
6. `ChatSessionControllerRetrievalOracleHelpers.swift`: moved search reconfiguration, local-oracle/retrieval helpers, transcript chunk helpers, attachment byte collection, and `SearchService: ChatSessionSearchProviding`.
7. `ChatSessionControllerTextExpansionDrafts.swift`: moved text-expansion lookup, preview, and rewrite gateway logic.
8. `ChatSessionControllerThreadLifecycle.swift`: moved workspace directory helpers, panel geometry persistence, thread resolution, thread lifecycle, and history refresh.
9. `OpenBurnBar.xcodeproj/project.pbxproj`: XcodeGen-only update adding the new Swift files; sibling-lane pbxproj conflicts are expected to be handled by the orchestrator.

## Losslessness Evidence

- Local proof compared the result against `git show HEAD:AgentLens/Views/Chat/ChatSessionController.swift`.
- Main file code lines equal `HEAD` minus moved ranges; only blank-line cleanup differs.
- Moved bodies are byte-for-byte verbatim:
  - `ChatSessionControllerPromptSections.swift`: 91 original lines, `sha256=831d436a4078210f`
  - `ChatSessionControllerMemoryExtraction.swift`: 25 original lines, `sha256=7e6169c82c7e1633`
  - `ChatSessionControllerDesktopControlAccess.swift`: 105 original lines, `sha256=9d8b9b3f78ae6fe5`
  - `ChatSessionControllerBackendGatewayRouting.swift`: 654 original lines, `sha256=18f13df5fd66d641`
  - `ChatSessionControllerTextExpansionDrafts.swift`: 175 original lines, `sha256=f176bd60bd346deb`
  - `ChatSessionControllerThreadLifecycle.swift`: 282 original lines, `sha256=64aa49a698da276a`
  - `ChatSessionControllerRetrievalOracleHelpers.swift`: 170 original lines, `sha256=5a5a787a69b3d7e1`
  - `SearchService` conformance: `sha256=ce4a945d06d4f19b`

## Visibility Relaxations

- `hermesCatalogWarmTask`: `private` -> internal so the moved backend/gateway extension can access the stored task across file boundaries.
- `hermesEnvFallbackBearerToken`: `private` -> internal for the same cross-file extension access.

## Validation Matrix

- `xcodegen`: passed.
- `xcodebuild build -project OpenBurnBar.xcodeproj -scheme OpenBurnBar -destination platform=macOS,arch=arm64 -clonedSourcePackagesDirPath ./.spm-cache-new -disableAutomaticPackageResolution`: passed.
- `rg -n "ChatSession" AgentLensTests`: found dedicated ChatSession suites.
- `OPENBURNBAR_APP_TEST_FILTERS='AgentLensTests/ChatSessionControllerOMPTests,AgentLensTests/ChatSessionControllerSearchStateTests,AgentLensTests/ChatSessionControllerAttachmentTests,AgentLensTests/ChatSessionControllerPaneModeTests,AgentLensTests/ChatSessionControllerPiAgentTests' ./scripts/test-openburnbar-app.sh`: passed, 30 tests.
- `bash scripts/debt/check-swift-file-size-budget.sh`: passed (`OK: no new oversized files and no baselined file grew`).
- `git diff --check` and `git diff --cached --check`: passed.
- Suppression scan over touched `ChatSessionController*.swift`: no matches.
- Repo-duplicate basename scan for new `ChatSessionController...` files: no duplicates.

## Risks

- XcodeGen regenerated some temporary package product identifiers in `project.pbxproj`; this is normal XcodeGen churn and may conflict with sibling pbxproj lanes.
- The change relies on extension wrappers/imports plus two stored-property visibility relaxations; moved method bodies are otherwise unchanged.

## Rollback

- Revert commit `37387ab11a761046c882c89a16ea82fa63e287b0` to restore the single-file controller and prior project file.
