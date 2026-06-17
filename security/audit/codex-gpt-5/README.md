# Codex GPT-5 Security Audit - OpenBurnBar

Run date: 2026-06-16

Run mode: FULL_BASELINE

Model/run namespace: `codex-gpt-5`

Commit reviewed: `0e0b063b27e39ad8cd1210ee829c2c7de28db620`

Branch basis: `origin/main` in a detached clean worktree

## Executive Summary

OpenBurnBar is a multi-surface local-first and cloud-assisted developer productivity product. It includes a macOS app, local daemon, iOS app, Android app, Firebase Functions and Firestore/Storage backend, hosted MCP service, local MCP shim, VS Code extension, Rust transport libraries, CI/CD, billing, privacy tooling, and agentic Computer Use workflows.

Current implemented security readiness is **59/100 final** with **74/100 raw**. The highest applied cap is the **Major Claim Cap**. The codebase has a strong implemented security base: endpoint authorization inventory, high-risk owner-action proof, Firestore owner-scoped rules, Functions App Check fail-closed behavior, AES-GCM Cloud Vault envelopes with AAD, hosted MCP short-lived scoped tokens, daemon socket-token and code-signature peer gates, structured logging scrubbers, privacy invariants, and broad CI gates.

The score is capped because some high-impact local agent and privacy claims are stronger than the current implementation can prove. The highest priority issue is daemon Computer Use local-auth proof: the verifier and tests exist, but the production executable wires `localAuthProofVerifier` to `nil`, making that proof optional on the daemon RPC path.

## Current Score

| Metric | Value |
|---|---:|
| Raw score | 74 |
| Final score after caps | 59 |
| Confidence | Medium |
| Auditor readiness | Focused security review ready; not full external audit ready |
| Highest applied cap | Major Claim Cap, max 59 |
| Critical findings | 0 |
| High findings | 1 |
| Medium findings | 5 |
| Low findings | 3 |

## Top Blockers

1. Wire daemon `DaemonLocalAuthProofVerifier` in the production executable.
2. Replace daemon synthetic Computer Use entitlement and kill-switch context with live state.
3. Fix `boundedHttpsURL` and add exact Stripe redirect regression tests.
4. Add deploy verification for Firestore App Check enforcement.
5. Make irreversible data deletion produce durable audit evidence.

## Safe Claims Today

- Protected callable APIs generally require Firebase Auth and App Check, with explicit public/webhook/platform exceptions.
- Firestore rules are owner-scoped and server-only for sensitive secret collections.
- Hosted MCP uses scoped short-lived tokens, client/entitlement/rate checks, and local decryption for sealed bodies.
- Cloud Vault sealed fields use AES-GCM with context-bound AAD.
- Stripe webhooks are signature verified and idempotency protected.
- Data export requires high-risk owner proof and fail-closed audit append.

## Claims to Avoid Today

- All Computer Use daemon actions require independent local-auth proof.
- All Computer Use daemon actions are live kill-switch and entitlement gated.
- Firestore App Check production enforcement is proven by repository state.
- All sensitive user data has Signal-quality E2EE.
- Billing redirects are HTTPS-only.
- Production deploy is WIF-only.

