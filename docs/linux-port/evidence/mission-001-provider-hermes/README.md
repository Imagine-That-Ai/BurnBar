# W04 Provider / Hermes lane evidence

Lane: **W04ProviderHermesEngine** (worktree `/private/tmp/openburnbar-linux-mission-001`).

## Refresh

```bash
./scripts/linux-port/run-provider-hermes-evidence.sh
```

On macOS hosts this re-executes inside `openburnbar-linux-toolchain:mission-001` with the worktree mounted at `/workspace`.

## Artifacts

| File | Purpose |
|------|---------|
| `provider-log-path-matrix.json` | VAL-PROVIDER-001 logical path matrix |
| `provider-discovery-edge-fixture.json` | Symlink / partial-file / readability edge matrix |
| `provider-discovery-edge-transcript.txt` | `swift test --filter AgentProviderLogDiscoveryLinuxTests` |
| `llmsafe-content-linux-fixture.json` | VAL-HERMES-003 prompt-injection fixture |
| `cli-hermes-transcript.txt` | index / search / recall + run list persistence |
| `contract-status.json` | Honest per-contract status (no false passes) |
| `fixtures/` | Attack text + dual-envelope notes |

IPC gateway transcripts are copied from `mission-001-ipc-cli-gateway/` after `run-ipc-cli-gateway-evidence.sh`.