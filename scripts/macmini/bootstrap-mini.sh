#!/usr/bin/env bash

set -euo pipefail

script_dir="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=scripts/macmini/lib.sh
source "$script_dir/lib.sh"

load_macmini_config

log "checking SSH reachability for $MACMINI_USER@$MACMINI_HOST"
mini_ssh "printf 'ssh-ok user=%s host=%s\n' \"\$(whoami)\" \"\$(hostname)\""

runner_root="$(mini_resolve_runner_root)"
runner_root_q="$(printf "%q" "$runner_root")"
uid="$(mini_ssh "id -u")"

log "creating runner directories under $runner_root"
mini_ssh "mkdir -p $runner_root_q/{queue,payloads,results,logs,bin} ~/Library/LaunchAgents"

log "building CUClickSmoke release binary locally"
swift build -c release --package-path "$repo_root/tools/CUClickSmoke"
cu_binary="$repo_root/tools/CUClickSmoke/.build/release/CUClickSmoke"
[[ -x "$cu_binary" ]] || die "missing built CUClickSmoke binary at $cu_binary"

plist_tmp="$(mktemp "${TMPDIR:-/tmp}/openburnbar-uitest-runner-plist.XXXXXX")"
trap 'rm -f "$plist_tmp"' EXIT
sed "s#__RUNNER_ROOT__#$runner_root#g" "$script_dir/com.openburnbar.uitest-runner.plist" > "$plist_tmp"

log "pushing runner bits to the mini"
mini_rsync "$script_dir/runner-daemon.sh" "$MACMINI_USER@$MACMINI_HOST:$runner_root/bin/runner-daemon.sh"
mini_rsync "$cu_binary" "$MACMINI_USER@$MACMINI_HOST:$runner_root/bin/CUClickSmoke"
mini_rsync "$plist_tmp" "$MACMINI_USER@$MACMINI_HOST:$runner_root/bin/com.openburnbar.uitest-runner.plist"

mini_ssh "chmod +x $runner_root_q/bin/runner-daemon.sh $runner_root_q/bin/CUClickSmoke && cp $runner_root_q/bin/com.openburnbar.uitest-runner.plist ~/Library/LaunchAgents/com.openburnbar.uitest-runner.plist"

log "installing LaunchAgent in gui/$uid"
mini_ssh "launchctl bootout gui/$uid/com.openburnbar.uitest-runner >/dev/null 2>&1 || true"
mini_ssh "launchctl bootstrap gui/$uid ~/Library/LaunchAgents/com.openburnbar.uitest-runner.plist"
mini_ssh "launchctl kickstart -k gui/$uid/com.openburnbar.uitest-runner"

log "running best-effort privileged setup; macOS may ask for the mini account password"
mini_ssh_tty "sudo pmset -a sleep 0" || warn "pmset sleep disable failed"
mini_ssh_tty "sudo DevToolsSecurity -enable" || warn "DevToolsSecurity enable failed"
mini_ssh_tty "sudo systemsetup -setrestartfreeze on" || warn "restart-freeze setting failed"

log "checking Xcode first-launch/license state"
if ! mini_ssh "xcodebuild -checkFirstLaunchStatus" >/dev/null 2>&1; then
    warn "Xcode first launch is incomplete on the mini"
    cat <<'EOF'
Run this once on the mini, then re-run bootstrap or mini-doctor:
  sudo xcodebuild -runFirstLaunch
EOF
fi

log "runner permission probe"
mini_ssh "$runner_root_q/bin/CUClickSmoke --probe-permissions" || true

cat <<EOF

Manual checklist on the Mac mini:

1. Remote Login:
   System Settings -> General -> Sharing -> Remote Login -> On.
   Ensure the configured user ($MACMINI_USER) is allowed.

2. Accessibility TCC grants:
   System Settings -> Privacy & Security -> Accessibility.
   Enable the LaunchAgent host shell (/bin/bash), xcodebuild/XCTest runner when
   it appears as OpenBurnBarUITests-Runner.app, and:
     $runner_root/bin/CUClickSmoke

3. Screen Recording TCC grants:
   System Settings -> Privacy & Security -> Screen Recording.
   Enable the same runner binaries that capture pixels:
     /bin/bash
     OpenBurnBarUITests-Runner.app when macOS prompts for it
     $runner_root/bin/CUClickSmoke

4. GUI session:
   Keep the runner user logged into the Aqua desktop. Do not rely on bare SSH.
   Recommended for a lab mini: System Settings -> Users & Groups -> Automatically
   log in as $MACMINI_USER, and System Settings -> Lock Screen -> disable fast
   sleep/lock timers. This trades physical-security hardening for automation
   reliability; use only on a controlled runner.

5. Optional operator access:
   System Settings -> General -> Sharing -> Screen Sharing -> On, so failures
   can be inspected without disturbing the LaunchAgent.

Next:
  scripts/macmini/mini-doctor.sh
  scripts/test-openburnbar-ui.sh --remote
EOF
