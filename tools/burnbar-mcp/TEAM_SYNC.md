# Live Agent Fleet — team sync (OpenBurnBar)

Local RPC / `fleet-snapshot.json` stays the serving path. This MCP does not write the daemon.

## Now (local overlay)

Set `BURNBAR_FLEET_PEER_DIR` to a directory of extra `*.json` snapshots (one file per host, stem = host id). `burnbar_fleet_snapshot` lists them; `burnbar_fleet_can_launch` notes that peers exist. Copy or rsync files yourself. No SSH requirement for cloud Duty Officer.

Presence until Droid M5: sidecar `~/Library/Application Support/BurnBar/fleet-presence.json` via `burnbar_fleet_presence_record`. Daemon probes stay the source of liveness. TTL default 300s.

## After Droid M5

Replace the sidecar with additive `daemon.fleet.presence.record` (TTL on the snapshot). Do not implement that RPC in this MCP folder.

## After Droid M6 (CloudSync follow-on)

Opt-in CloudSync merge of per-machine snapshots (`fleet_machine_snapshot` or whatever M6 names) for OpenBurnBar teams. **Do not** put CloudSync, Firestore, or Firebase on the fleet serving path (CROSS-018). Local `daemon.fleet.snapshot` / the JSON file remains what agents read.

Until that ships, keep using `BURNBAR_FLEET_PEER_DIR`.
