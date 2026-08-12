# Subagent E — QA, Telemetry & Rollout
**Goal:** Tests + metrics + flag rollout + perf re-measure.
**Deliverable:** PR titled `qa: visual surface telemetry + budgets`
**Files:** VisualCapturePreferencesTests.swift, AnalyticsEvent.swift, budgets/macos-idle-cpu.perf.json, runbooks
**Acceptance:** make ci + fast-feedback green, powermetrics still <0.8%/140MB, AnalyticsEvent fires, rollout flag off by default.
