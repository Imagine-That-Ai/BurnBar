# Security detection matrix (2026-06-01)

Maps controls to observable signals and operator gates. Complements [`PRIVILEGED_INPUT_THREAT_MODEL.md`](PRIVILEGED_INPUT_THREAT_MODEL.md).

| Control | Signal / artifact | Owner | Gate |
|---------|-------------------|-------|------|
| Google Play token reuse | `google_play_token_claims/{hash}` deny on second UID | Cloud Functions | `npm test` + Firestore rules |
| Public device-code abuse | `public_rate_limits/*` + `resource-exhausted` | Cloud Functions | `publicRateLimit.test.ts` |
| VoIP token injection | Callable requires `pairedDeviceId`; tokens from `devices/{id}` only | Cloud Functions + iOS | `voipPush` unit tests |
| Iroh pairing freshness | 180s client + `IROH_PAIRING_FRESHNESS_MS` | iOS/Android/TS | `irohPairingFreshness.test.ts` |
| Iroh inbound peer binding | `iroh_pairing_rejected` audit; allowlist from `devices.irohPeerNodeId` + `controllers/*` | Mac host | `IrohInboundPeerPolicyTests` + xcframework rebuild |
| Privileged socket P0 | `privileged_socket_peer_rejected` audit events | Mac daemons | RC runbook + `launch-evidence/privileged-redteam-rc-*.txt` |
| Capability token at leaf | `VirtualHIDBridgeCapabilityGate` deny without token | VirtualHID bridge | `VirtualHIDBridgeCapabilityGateTests` |
| Phone control TTL | `expiredAuthority` / 300s `authorityMaxLifetime` | Mac validator | `PhoneControlAuthorityValidatorAttestationTests` |
| Phone attestation fail-closed | RC `computer_use_phone_control_attestation_required` | Mac/iOS | `PhoneControlAttestationPolicyTests` + strict validator tests |
| App Check attestation bind | `obb_app_check` claim + `attestationHashBlake3` on envelopes | Mac/iOS + Functions | `npm run test:security` (golden digest) + `bindAppCheckAttestation` |
| Iroh UniFFI peer id | `remoteNodeId()` in Generated Swift | Release build | `scripts/ci/verify-iroh-remote-node-id-binding.sh` |
| RAG injection | `<UNTRUSTED_CONTENT>` wrappers in evidence + user blocks | Mac chat | `PromptInjectionHardeningTests` |
| Supply chain | OSV + `cargo-deny` + cosign on SBOM/VEX/DMG/ZIP | CI / release | `security-pr.yml`, `release.yml`, `run-ecosystem-deny-checks.sh` |
| App Check console enforcement | Firebase App Check API `enforcementMode` | Ops | `commercial-launch-gate.mjs` |

## Operator drills

```bash
# Launch gate (App Check probe + commercial readiness)
node scripts/commercial-launch-gate.mjs

# Privileged socket red-team (after installing P0+ daemons)
bash scripts/ops/run-privileged-socket-redteam.sh

# Ecosystem deny
bash scripts/supply-chain/run-ecosystem-deny-checks.sh
```