## Summary

Split `AgentLens/Views/Settings/ProxyModelCatalogPanel.swift` from one 1,886-line god file into single-responsibility Settings files without changing layout, behavior, or data flow.

The remaining panel file owns state, sheets, lifecycle, and top-level actions. The extracted files hold the already-distinct route log views, provider section, model row, provider logo, custom-model sheet, rename sheet, and provider grouping helper. `OpenBurnBar.xcodeproj/project.pbxproj` was regenerated with XcodeGen after adding the files.

## Review Map

1. `ProxyModelCatalogPanel.swift`: top-level panel, state, toolbar, lifecycle, and action wiring only.
2. `ProxyRouteLogViews.swift`: route-log sheet, log row, detail view, and formatting helpers.
3. `ProxyModelProviderSection.swift` and `ProxyModelCatalogRow.swift`: provider grouping UI and per-model row/actions.
4. `ProxyAddCustomModelSheet.swift` and `ProxyModelRenameSheet.swift`: sheet views moved out intact.
5. `ProxyProviderLogoView.swift` and `ProxyModelProviderGroup.swift`: small support views/types.
6. `OpenBurnBar.xcodeproj/project.pbxproj`: XcodeGen-only project update for the new source files.

## Losslessness Evidence

Proof was generated against the post-merge pre-refactor HEAD `8b2a11ccc9f742de5e0dc54d23e3d5cee2778449` using `git show HEAD:AgentLens/Views/Settings/ProxyModelCatalogPanel.swift`.

- Reconstructed split output matches the original after stripping only the new per-file imports and normalizing the three file-boundary visibility relaxations back to `private`.
- Empty diff: `.lane-logs/gf10-proxy-catalog/losslessness.diff`
- Matching SHA-256:
  - original: `b5f63099743c891b319eb95b0e650c7aa020f1320192cd3a73dc80c422e44da1`
  - reconstructed: `b5f63099743c891b319eb95b0e650c7aa020f1320192cd3a73dc80c422e44da1`

## File Size / Basename Checks

Line counts after split:

- `ProxyModelCatalogPanel.swift`: 520
- `ProxyModelCatalogRow.swift`: 436
- `ProxyRouteLogViews.swift`: 398
- `ProxyModelRenameSheet.swift`: 186
- `ProxyAddCustomModelSheet.swift`: 134
- `ProxyModelProviderSection.swift`: 126
- `ProxyProviderLogoView.swift`: 91
- `ProxyModelProviderGroup.swift`: 9

All files are under the 800-line lane limit. New basenames were checked against the repo basename set and produced no duplicate hits.

## Minimal Visibility Relaxations

Required only so moved top-level views remain visible across file boundaries:

- `private struct ProxyRouteLogSheet` -> `struct ProxyRouteLogSheet`
- `private struct AddCustomModelSheet` -> `struct AddCustomModelSheet`
- `private struct ModelRenameSheet` -> `struct ModelRenameSheet`

No lint suppressions were added.

## Validation Matrix

- `git fetch origin main && git merge origin/main`: passed; branch fast-forwarded to `8b2a11ccc9f742de5e0dc54d23e3d5cee2778449`.
- `xcodegen`: passed; project file regenerated.
- `bash scripts/debt/check-swift-file-size-budget.sh`: passed (`Swift file-size budget: target=2000 baselined=0 live-over-target=0`).
- `git diff --cached --check`: passed.
- `OPENBURNBAR_APP_TEST_FILTER=AgentLensTests/ConnectionsViewModelTests OPENBURNBAR_APP_TEST_ATTEMPTS=1 ./scripts/test-openburnbar-app.sh`: passed, 44 tests, 0 failures.
- Requested exact build command was run:
  `xcodebuild build -project OpenBurnBar.xcodeproj -scheme OpenBurnBar -destination platform=macOS,arch=arm64 -clonedSourcePackagesDirPath ./.spm-cache-new -disableAutomaticPackageResolution`

The exact build is locally blocked after module-cache cleanup by Xcode DerivedData/index/temp-directory and entitlement/codesign artifacts outside this refactor surface:

- `error: Mkdtemp(.../OpenBurnBarDaemon.build/Objects-normal/arm64/swbuild.tmp...): No such file or directory (2)`
- `error: writing index record file: failed to create directory .../Index.noindex/DataStore/v5/records/9T`
- `OpenBurnBarPrivilegedInputExecution.xcent: cannot read entitlement data`
- `Command CodeSign failed with a nonzero exit code`

The filtered app-test wrapper built the moved Settings sources successfully and executed the proxy-catalog-adjacent `ConnectionsViewModelTests` suite cleanly.

## Risks

- The XcodeGen regeneration includes normal project-file UUID/product reference churn in addition to the new Swift files.
- The only Swift visibility changes are file-boundary relaxations listed above.
- Clean CI/factory build should validate the exact build surface because the local requested build is blocked by DerivedData/index/codesign environment artifacts, not moved Settings code.

## Rollback

Revert this commit. That restores the monolithic `ProxyModelCatalogPanel.swift` and the previous generated project file.
