#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
ARTIFACT_DIR="${OPENBURNBAR_IMPAIRMENT_ARTIFACT_DIR:-"$ROOT_DIR/artifacts/mercury-impairment"}"
MODE="dry-run"
RUN_COMMAND=()

usage() {
  cat <<'USAGE'
Usage:
  scripts/e2e/mercury-mirror-network-impairment.sh [--dry-run]
  scripts/e2e/mercury-mirror-network-impairment.sh --run -- <command...>

Runs the Mercury Mirror impairment matrix before any quality/latency claim.

Matrix:
  packet loss: 0, 1, 3, 5, 10 percent
  RTT:         30, 100, 300 ms

Environment hooks:
  OPENBURNBAR_IMPAIRMENT_APPLY_CMD
    Optional command run before each scenario. It receives:
      OBB_PACKET_LOSS_PERCENT
      OBB_RTT_MILLIS

  OPENBURNBAR_IMPAIRMENT_CLEAR_CMD
    Optional command run after each scenario and once at exit.

  OPENBURNBAR_IMPAIRMENT_ARTIFACT_DIR
    Output directory. Defaults to artifacts/mercury-impairment.

The script is intentionally dry-run by default. Use --run with a test command
only after the apply/clear commands are configured for the host OS.
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run)
      MODE="dry-run"
      shift
      ;;
    --run)
      MODE="run"
      shift
      if [[ "${1:-}" == "--" ]]; then
        shift
      fi
      RUN_COMMAND=("$@")
      break
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage >&2
      exit 64
      ;;
  esac
done

if [[ "$MODE" == "run" && "${#RUN_COMMAND[@]}" -eq 0 ]]; then
  echo "--run requires a command after --" >&2
  exit 64
fi

mkdir -p "$ARTIFACT_DIR"
RESULTS_CSV="$ARTIFACT_DIR/results.csv"
RUN_LOG="$ARTIFACT_DIR/run.log"

cleanup() {
  if [[ -n "${OPENBURNBAR_IMPAIRMENT_CLEAR_CMD:-}" ]]; then
    OBB_PACKET_LOSS_PERCENT="" OBB_RTT_MILLIS="" bash -lc "$OPENBURNBAR_IMPAIRMENT_CLEAR_CMD" >>"$RUN_LOG" 2>&1 || true
  fi
}
trap cleanup EXIT

printf 'timestamp_utc,mode,packet_loss_percent,rtt_millis,status,duration_seconds\n' >"$RESULTS_CSV"

losses=(0 1 3 5 10)
rtts=(30 100 300)

for loss in "${losses[@]}"; do
  for rtt in "${rtts[@]}"; do
    started="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    start_seconds="$(date +%s)"
    status="dry_run"
    echo "scenario loss=${loss}% rtt=${rtt}ms mode=$MODE" | tee -a "$RUN_LOG"

    if [[ "$MODE" == "run" ]]; then
      if [[ -n "${OPENBURNBAR_IMPAIRMENT_APPLY_CMD:-}" ]]; then
        OBB_PACKET_LOSS_PERCENT="$loss" OBB_RTT_MILLIS="$rtt" bash -lc "$OPENBURNBAR_IMPAIRMENT_APPLY_CMD" >>"$RUN_LOG" 2>&1
      fi

      if OBB_PACKET_LOSS_PERCENT="$loss" OBB_RTT_MILLIS="$rtt" "${RUN_COMMAND[@]}" >>"$RUN_LOG" 2>&1; then
        status="passed"
      else
        status="failed"
      fi

      cleanup
    fi

    end_seconds="$(date +%s)"
    duration="$((end_seconds - start_seconds))"
    printf '%s,%s,%s,%s,%s,%s\n' "$started" "$MODE" "$loss" "$rtt" "$status" "$duration" >>"$RESULTS_CSV"
  done
done

echo "Wrote $RESULTS_CSV"
