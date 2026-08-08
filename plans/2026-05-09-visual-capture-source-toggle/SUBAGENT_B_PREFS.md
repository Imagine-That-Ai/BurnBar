# Subagent B — Data Model & Persistence
**Goal:** Global + per-provider VisualCaptureSource pref, UserDefaults, flag.
**Deliverable:** PR titled `prefs: visual capture source per provider`
**Files:** SettingsManager or VisualCapturePreferences.swift, VisualCapturePreferencesTests.swift
**Acceptance:** Unit tests round-trip, CLI-only override, defaults to cliPTY, no DB migration.
