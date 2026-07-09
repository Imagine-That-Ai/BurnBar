#!/usr/bin/env bash

set -euo pipefail

macmini_script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export repo_root
repo_root="$(cd "$macmini_script_dir/../.." && pwd)"

log() {
    printf '>>> %s\n' "$*"
}

warn() {
    printf 'warning: %s\n' "$*" >&2
}

die() {
    printf 'error: %s\n' "$*" >&2
    exit 1
}

load_macmini_config() {
    local config_path="${MACMINI_CONFIG:-$macmini_script_dir/config.env}"
    if [[ ! -f "$config_path" ]]; then
        die "missing $config_path; copy scripts/macmini/config.env.example to scripts/macmini/config.env and fill it in"
    fi

    # shellcheck source=/dev/null
    source "$config_path"

    MACMINI_HOST="${MACMINI_HOST:-}"
    MACMINI_USER="${MACMINI_USER:-}"
    MACMINI_SSH_KEY="${MACMINI_SSH_KEY:-$HOME/.ssh/openburnbar_mini}"
    MACMINI_RUNNER_ROOT="${MACMINI_RUNNER_ROOT:-$HOME/OpenBurnBarUIRunner}"
    MACMINI_SSH_OPTS="${MACMINI_SSH_OPTS:-}"

    [[ -n "$MACMINI_HOST" ]] || die "MACMINI_HOST is required in $config_path"
    [[ -n "$MACMINI_USER" ]] || die "MACMINI_USER is required in $config_path"
}

macmini_ssh_args() {
    local opts=()
    if [[ -n "${MACMINI_SSH_OPTS:-}" ]]; then
        # Intentionally shell-like: config.env owns this local developer string.
        read -r -a opts <<< "$MACMINI_SSH_OPTS"
    fi
    if [[ -n "${MACMINI_SSH_KEY:-}" ]]; then
        opts+=(-i "$MACMINI_SSH_KEY")
    fi
    printf '%s\0' "${opts[@]}"
}

mini_ssh() {
    local opts=()
    while IFS= read -r -d '' opt; do
        opts+=("$opt")
    done < <(macmini_ssh_args)
    ssh "${opts[@]}" -- "$MACMINI_USER@$MACMINI_HOST" "$@"
}

mini_ssh_tty() {
    local opts=()
    while IFS= read -r -d '' opt; do
        opts+=("$opt")
    done < <(macmini_ssh_args)
    ssh -t "${opts[@]}" -- "$MACMINI_USER@$MACMINI_HOST" "$@"
}

mini_rsync() {
    local opts=()
    while IFS= read -r -d '' opt; do
        opts+=("$opt")
    done < <(macmini_ssh_args)
    rsync -az --delete -e "ssh $(printf '%q ' "${opts[@]}")" "$@"
}

# Same transport as mini_rsync but callers supply their own flags/paths (e.g.
# --exclude). Kept separate so the common path stays terse.
mini_rsync_opts() {
    local opts=()
    while IFS= read -r -d '' opt; do
        opts+=("$opt")
    done < <(macmini_ssh_args)
    rsync -az -e "ssh $(printf '%q ' "${opts[@]}")" "$@"
}

# Products are built with CODE_SIGNING_ALLOWED=NO, leaving linker ad-hoc
# signatures without entitlements. testmanagerd on the runner SIGKILLs test
# runners lacking get-task-allow, and the mini's LaunchAgent context cannot
# re-sign bundles itself (App Management TCC). Sign here on the controller so
# payloads arrive ready to execute.
adhoc_sign_products() {
    local products_dir="$1"
    local ents
    ents="$(mktemp "${TMPDIR:-/tmp}/openburnbar-gta.XXXXXX.plist")"
    cat > "$ents" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>com.apple.security.get-task-allow</key>
    <true/>
</dict>
</plist>
PLIST

    xattr -cr "$products_dir" 2>/dev/null || true

    log "ad-hoc signing build products (deepest-first, get-task-allow on apps)"
    local item
    while IFS= read -r item; do
        codesign --force --sign - "$item" 2>/dev/null || true
    done < <(find "$products_dir" \( -name '*.framework' -o -name '*.xctest' -o -name '*.dylib' -o -name '*.bundle' \) | awk '{ print length, $0 }' | sort -rn | cut -d' ' -f2-)

    local app helper
    while IFS= read -r app; do
        while IFS= read -r helper; do
            codesign --force --sign - --entitlements "$ents" "$helper" 2>/dev/null || true
        done < <(find "$app/Contents/Helpers" -type f -perm +111 2>/dev/null)
        codesign --force --sign - --entitlements "$ents" "$app" ||
            die "controller-side ad-hoc signing failed for $app"
        codesign --verify --strict "$app" ||
            die "signature verification failed for $app"
    done < <(find "$products_dir" -maxdepth 2 -name '*.app')

    rm -f "$ents"
}

mini_resolve_runner_root() {
    mini_ssh "python3 -c 'import os,sys; print(os.path.expandvars(os.path.expanduser(sys.argv[1])))' $(printf "%q" "$MACMINI_RUNNER_ROOT")"
}

json_quote() {
    python3 -c 'import json,sys; print(json.dumps(sys.argv[1]))' "$1"
}

utc_now() {
    date -u +%Y-%m-%dT%H:%M:%SZ
}
