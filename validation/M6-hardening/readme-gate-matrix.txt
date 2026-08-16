M6 README claim-to-command matrix
generated_at=2026-08-16T18:15:16.545061+00:00
binary=/Users/dewclaw/Developer/AgentLens/BurnBarDaemon/.build/arm64-apple-macosx/debug/BurnBarDaemon
scope=hermetic temp dirs only; no real agent roots

[default-support-and-socket]
claim=non-overridden support derives socket, fleet-snapshot.json, fleet.sqlite
command=BURNBAR_DAEMON_SUPPORT_DIR=<tmp>/support BURNBAR_FLEET_ROOTS_DIR=<tmp>/roots BURNBAR_FLEET_CADENCE_SECONDS=1 BurnBarDaemon (no --socket-path; no socket env)
observed_socket=/tmp/burnbar-m6-readme-default-iq80kk55/support/burnbar-daemon.sock
response=protocolVersion=1 schemaVersion=1 agents=10 cadenceSeconds=1
files=burnbar-daemon.sock,fleet-snapshot.json,fleet.sqlite,fleet.sqlite.initialized

[per-agent-root-override]
claim=BURNBAR_FLEET_ROOT_CLAUDE_CODE overrides BURNBAR_FLEET_ROOTS_DIR for one provider
command=base roots empty + BURNBAR_FLEET_ROOT_CLAUDE_CODE=<tmp>/override-claude with synthetic live pid and epoch-ms updatedAt
observed=claude-code status=running confidence=exactProcess projectName=/tmp/m6-fixture-repo signalPath=/tmp/burnbar-m6-readme-agent-rc71r51j/override-claude/sessions/14160.json

[event-retention]
claim=BURNBAR_FLEET_EVENT_RETENTION_SECONDS overrides 24-hour retention for accelerated validation
command=BURNBAR_FLEET_EVENT_RETENTION_SECONDS=1; create first transition; wait >1s; create second transition; sqlite3 read-only fleet_events
observed_event_rows_after_window=['claude-code|status_changed|stale->running', 'claude-code|confidence_changed|activeSessionFile->exactProcess']
database=/tmp/burnbar-m6-readme-retention-3cqg7zxs/support/fleet.sqlite

[socket-precedence]
claim=--socket-path wins over non-empty BURNBAR_DAEMON_SOCKET_PATH
command=BURNBAR_DAEMON_SOCKET_PATH=<tmp>/env.sock BurnBarDaemon --socket-path <tmp>/cli.sock
observed_cli_socket_response={'socketPath': '/tmp/burnbar-m6-readme-precedence-pobci_26/cli.sock', 'protocolVersion': 1, 'ok': True, 'daemonVersion': '0.1.0'}; env_socket_exists=False

[empty-socket-env]
claim=empty BURNBAR_DAEMON_SOCKET_PATH falls back to support-derived socket
command=BURNBAR_DAEMON_SOCKET_PATH="" BURNBAR_DAEMON_SUPPORT_DIR=<tmp>/support BurnBarDaemon
observed_socket=/tmp/burnbar-m6-readme-empty-wiw39ve0/support/burnbar-daemon.sock
response={'protocolVersion': 1, 'daemonVersion': '0.1.0', 'socketPath': '/tmp/burnbar-m6-readme-empty-wiw39ve0/support/burnbar-daemon.sock', 'ok': True}
