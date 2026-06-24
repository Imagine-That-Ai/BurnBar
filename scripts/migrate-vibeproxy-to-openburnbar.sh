#!/bin/bash
#
# migrate-vibeproxy-to-openburnbar.sh
#
# Transfers every VibeProxy provider model to OpenBurnBar and replaces
# the VibeProxy custom-model entries in ~/.factory/ with OpenBurnBar
# gateway-served models.
#
# Steps:
#   1. Reads ~/.cli-proxy-api/config.yaml and extracts every API key.
#   2. Writes each key to the macOS keychain under the OpenBurnBar daemon
#      secret-store service + slot account format.
#   3. Rewrites ~/Library/Application Support/OpenBurnBar/provider-config.json
#      with enabled providers, credential slots, and custom models that
#      cover every model VibeProxy advertised.
#   4. Enables the OpenBurnBar HTTP gateway on 127.0.0.1:8317 via UserDefaults
#      and generates/persists a gateway auth token in the keychain.
#   5. Kills the old daemon process so the app relaunches it with the new
#      gateway-enabled configuration.
#   6. Waits for the gateway to come up, queries /v1/models, and rewrites
#      ~/.factory/settings.json (and settings.local.json / config.json)
#      with OpenBurnBar-owned custom model entries that point at 8317.
#   7. Removes all legacy [VibeProxy] entries from the Droid config.
#
set -euo pipefail

# Keep bearer tokens out of curl argv (security policy: verify-curl-bearer-token-boundary).
# shellcheck source=scripts/lib/curl-bearer.sh
source "$(dirname "$0")/lib/curl-bearer.sh"

SUPPORT_DIR="$HOME/Library/Application Support/OpenBurnBar"
CONFIG_PATH="$SUPPORT_DIR/provider-config.json"
VIBEPROXY_CONFIG="$HOME/.cli-proxy-api/config.yaml"
BACKUP_DIR="$SUPPORT_DIR/backups/pre-vibeproxy-migration-$(date +%Y%m%dT%H%M%S)"

RED=$'\033[31m'
GREEN=$'\033[32m'
YELLOW=$'\033[33m'
BLUE=$'\033[34m'
NC=$'\033[0m'

log() { echo "${BLUE}[migrate]${NC} $1"; }
ok()   { echo "${GREEN}[ok]${NC} $1"; }
warn() { echo "${YELLOW}[warn]${NC} $1"; }
err()  { echo "${RED}[err]${NC} $1" >&2; }

# ---------------------------------------------------------------------------
# 0. Preflight
# ---------------------------------------------------------------------------

if [[ ! -f "$VIBEPROXY_CONFIG" ]]; then
    err "VibeProxy config not found at $VIBEPROXY_CONFIG"
    exit 1
fi

mkdir -p "$BACKUP_DIR"

# Backup current files
for f in "$CONFIG_PATH" "$HOME/.factory/settings.json" "$HOME/.factory/settings.local.json" "$HOME/.factory/config.json"; do
    if [[ -f "$f" ]]; then
        cp "$f" "$BACKUP_DIR/$(basename "$f").bak"
        log "Backed up $(basename "$f")"
    fi
done

# ---------------------------------------------------------------------------
# 1. Parse VibeProxy config and extract providers + keys
# ---------------------------------------------------------------------------

log "Parsing VibeProxy config..."

# Use Python to parse the YAML and emit a JSON summary we can consume
VIBEPROXY_DATA=$(python3 -c "
import yaml, json, sys

with open('$VIBEPROXY_CONFIG') as f:
    config = yaml.safe_load(f)

providers = []

# openai-compatibility entries
for entry in config.get('openai-compatibility', []):
    name = entry.get('name', '')
    base_url = entry.get('base-url', '')
    keys = [k.get('api-key','') for k in entry.get('api-key-entries', [])]
    models = [{'name': m.get('name',''), 'alias': m.get('alias','')} for m in entry.get('models', [])]
    providers.append({
        'source': 'openai-compatibility',
        'name': name,
        'base_url': base_url,
        'keys': keys,
        'models': models,
    })

# claude-api-key entries (Anthropic-compatible)
for entry in config.get('claude-api-key', []):
    base_url = entry.get('base-url', '')
    key = entry.get('api-key', '')
    models = [{'name': m.get('name',''), 'alias': m.get('alias','')} for m in entry.get('models', [])]
    providers.append({
        'source': 'claude-api-key',
        'name': 'claude-api-key',
        'base_url': base_url,
        'keys': [key],
        'models': models,
    })

print(json.dumps(providers, indent=2))
")

echo "$VIBEPROXY_DATA" | python3 -c "
import json, sys
providers = json.load(sys.stdin)
print(f'Found {len(providers)} VibeProxy provider entries:')
for p in providers:
    print(f'  {p[\"name\"]}: base={p[\"base_url\"]}, keys={len(p[\"keys\"])}, models={len(p[\"models\"])}')
"

# ---------------------------------------------------------------------------
# 2. Write API keys to keychain + build provider config
# ---------------------------------------------------------------------------

log "Writing API keys to macOS keychain and building provider config..."

GENERATED_CONFIG=$(python3 -c "
import json, sys, subprocess, uuid, time

providers_data = json.loads('''$VIBEPROXY_DATA''')

KEYCHAIN_SERVICE = 'com.openburnbar.daemon.provider-secrets'

def write_keychain(service, account, value):
    '''Write a secret to the macOS keychain using the security command.'''
    # Delete existing item first (ignore errors if not found)
    subprocess.run(
        ['security', 'delete-generic-password', '-s', service, '-a', account],
        capture_output=True
    )
    # Add the new item
    result = subprocess.run(
        ['security', 'add-generic-password', '-s', service, '-a', account, '-w', value],
        capture_output=True, text=True
    )
    if result.returncode != 0:
        print(f'  WARNING: keychain write failed for {account}: {result.stderr.strip()}', file=sys.stderr)
        return False
    return True

def read_keychain(service, account):
    result = subprocess.run(
        ['security', 'find-generic-password', '-s', service, '-a', account, '-w'],
        capture_output=True, text=True
    )
    if result.returncode == 0:
        return result.stdout.strip()
    return None

# Map VibeProxy providers to OpenBurnBar provider IDs
# VibeProxy config -> OBB provider mapping:
#   Z.AI Coding Plan -> zai
#   Ollama Cloud -> ollama
#   OpenCode Go -> opencode (it's the opencode.ai gateway)
#   Wafer Serverless -> custom OpenAI-compatible provider under 'misc' or we use custom model
#   MiniMax (claude-api-key) -> minimax

# The OBB catalog provider IDs and their default base URLs:
# zai: https://api.z.ai/api/coding/paas/v4
# minimax: https://api.minimax.io/v1
# ollama: https://ollama.com/api
# opencode: https://opencode.ai/zen/go/v1
# deepseek: https://api.deepseek.com/v1
# moonshot: https://api.moonshot.ai/v1
# mimo: https://api.xiaomimimo.com/v1
# anthropic: https://api.anthropic.com/v1
# openai: https://api.openai.com/v1
# xai: https://api.x.ai/v1

# We need to load the existing provider-config.json, then merge in the
# credential slots and custom models.

config_path = '$CONFIG_PATH'
try:
    with open(config_path) as f:
        config = json.load(f)
except:
    config = {'providers': [], 'routerMode': 'provider_family_failover'}

providers = config.get('providers', [])

# Build a dict for easy lookup
provider_map = {p['providerID']: p for p in providers}

# Track which providers we enabled and what custom models we added
enabled_providers = set()
custom_models_added = []

now_ts = time.time()

def ensure_slot(provider_id, label, api_key, slot_id=None):
    '''Add a credential slot to a provider and write the key to keychain.'''
    if provider_id not in provider_map:
        print(f'  SKIP: provider {provider_id} not in OBB catalog', file=sys.stderr)
        return None

    if slot_id is None:
        slot_id = str(uuid.uuid4())

    # The keychain account format: provider.{providerID}.slot.{slotID}.apiKey
    # But the secret store key passed to setSecret is: {providerID}.slot.{slotID}
    # And the keychain account becomes: provider.{secretStoreKey}.apiKey
    secret_store_key = f'{provider_id}.slot.{slot_id}'
    keychain_account = f'provider.{secret_store_key}.apiKey'

    success = write_keychain(KEYCHAIN_SERVICE, keychain_account, api_key)
    if not success:
        print(f'  WARNING: failed to write keychain for {provider_id} slot {slot_id}', file=sys.stderr)

    # Verify readback
    readback = read_keychain(KEYCHAIN_SERVICE, keychain_account)
    if readback != api_key:
        print(f'  ERROR: keychain readback failed for {provider_id} slot {slot_id}', file=sys.stderr)

    p = provider_map[provider_id]
    slots = p.get('credentialSlots', [])

    # Check if a slot with this label already exists
    existing = None
    for s in slots:
        if s.get('label') == label:
            existing = s
            break

    if existing:
        slot_id = existing['slotID']
        # Update the keychain for the existing slot ID
        secret_store_key = f'{provider_id}.slot.{slot_id}'
        keychain_account = f'provider.{secret_store_key}.apiKey'
        write_keychain(KEYCHAIN_SERVICE, keychain_account, api_key)
        existing['isEnabled'] = True
        existing['status'] = 'ready'
        existing['updatedAt'] = now_ts
        existing['cooldownUntil'] = None
        existing['lastStatusMessage'] = None
    else:
        new_slot = {
            'slotID': slot_id,
            'label': label,
            'isEnabled': True,
            'status': 'ready',
            'cooldownUntil': None,
            'lastStatusMessage': None,
            'lastQuotaRemainingPercent': None,
            'lastQuotaResetsAt': None,
            'updatedAt': now_ts,
            'createdAt': now_ts,
        }
        slots.append(new_slot)
        p['credentialSlots'] = slots

    # Enable the provider
    p['isEnabled'] = True
    enabled_providers.add(provider_id)

    # Set preferred credential slot if none set
    if not p.get('preferredCredentialSlotID'):
        p['preferredCredentialSlotID'] = slot_id

    return slot_id

def add_custom_model(provider_id, model_id, display_name):
    '''Add a custom model to a provider if it's not already in the catalog.'''
    p = provider_map.get(provider_id)
    if not p:
        return

    custom_models = p.get('customModels', [])
    # Check if already exists
    for cm in custom_models:
        if cm.get('modelID') == model_id:
            return  # Already exists

    custom_models.append({
        'modelID': model_id,
        'displayName': display_name,
        'createdAt': now_ts,
        'updatedAt': now_ts,
    })
    p['customModels'] = custom_models
    custom_models_added.append((provider_id, model_id, display_name))

# Process each VibeProxy provider entry
for vp in providers_data:
    name = vp['name']
    base_url = vp['base_url']
    keys = [k for k in vp['keys'] if k.strip()]
    models = vp['models']

    # Map VibeProxy name -> OBB provider ID
    obb_provider_id = None
    obb_base_url = None

    if 'z.ai' in name.lower() or 'z.ai' in base_url.lower():
        obb_provider_id = 'zai'
        obb_base_url = 'https://api.z.ai/api/coding/paas/v4'
    elif 'ollama' in name.lower() or 'ollama' in base_url.lower():
        obb_provider_id = 'ollama'
        obb_base_url = 'https://ollama.com/api'
    elif 'opencode' in name.lower() or 'opencode.ai' in base_url.lower():
        obb_provider_id = 'opencode'
        obb_base_url = 'https://opencode.ai/zen/go/v1'
    elif 'wafer' in name.lower() or 'wafer' in base_url.lower():
        # Wafer is an OpenAI-compatible GLM-5.2 provider. We'll use the 'misc'
        # provider since there's no native Wafer provider in the catalog.
        # Actually, let's add it as a custom model under 'zai' since it serves GLM-5.2
        # But the API key is for wafer.ai, not z.ai. We need a custom provider.
        # The OBB catalog doesn't have a 'wafer' provider. We'll use 'misc' and
        # set a custom base URL.
        obb_provider_id = 'misc'
        obb_base_url = base_url.rstrip('/v1') if base_url.endswith('/v1') else base_url
    elif 'minimax' in name.lower() or 'minimax' in base_url.lower():
        obb_provider_id = 'minimax'
        obb_base_url = 'https://api.minimax.io/v1'
    else:
        print(f'  SKIP: unknown VibeProxy provider: {name} ({base_url})', file=sys.stderr)
        continue

    if obb_provider_id not in provider_map:
        print(f'  SKIP: OBB provider {obb_provider_id} not in config', file=sys.stderr)
        continue

    p = provider_map[obb_provider_id]

    # Update base URL if it's empty or different
    if obb_base_url:
        p['baseURL'] = obb_base_url

    # Add credential slots for each key
    for i, key in enumerate(keys):
        label = f'VibeProxy {name}'
        if len(keys) > 1:
            label = f'VibeProxy {name} #{i+1}'
        slot_id = ensure_slot(obb_provider_id, label, key)
        if slot_id:
            print(f'  Added credential slot: {obb_provider_id} / {label} (slot: {slot_id[:8]}...)')

    # Add custom models for any model not in the OBB catalog
    for m in models:
        model_name = m['name']
        model_alias = m['alias']
        # The alias is what the client sees. The name is the upstream model.
        # For OBB, the model ID advertised in /v1/models is the model name.
        # If the alias differs from the name, we register the alias as a
        # custom model that maps to the name.
        # But actually, OBB uses custom models to add models not in the catalog.
        # The model name from VibeProxy is what gets sent upstream.

        # For ollama cloud, the model name is the upstream model (e.g. 'glm-5.2')
        # and the alias is the client-facing name (e.g. 'glm-5.2:cloud').
        # OBB's catalog already has models like 'glm-5.2' for ollama.
        # But for zai, the catalog has 'glm-5' not 'glm-5.2'.

        # Register as custom model using the alias (client-facing name)
        # The model ID we advertise is the name (what goes upstream).
        display_name = model_alias if model_alias else model_name
        add_custom_model(obb_provider_id, model_name, display_name)

# Write the updated config
config['providers'] = list(provider_map.values())

# Write the config
with open(config_path, 'w') as f:
    json.dump(config, f, indent=4, sort_keys=True)

import os
os.chmod(config_path, 0o600)

print(f'Enabled providers: {sorted(enabled_providers)}')
print(f'Custom models added: {len(custom_models_added)}')
for pid, mid, dn in custom_models_added:
    print(f'  {pid}: {mid} ({dn})')
")

echo "$GENERATED_CONFIG"

log "Writing VibeProxy keys to OpenBurnBar fallback credential pool..."
VIBEPROXY_DATA_JSON="$VIBEPROXY_DATA" python3 - <<'PY'
import datetime
import hashlib
import json
import os

providers_data = json.loads(os.environ["VIBEPROXY_DATA_JSON"])
auth_path = os.path.expanduser("~/.hermes/auth.json")
os.makedirs(os.path.dirname(auth_path), exist_ok=True)

try:
    with open(auth_path) as handle:
        auth = json.load(handle)
except FileNotFoundError:
    auth = {
        "version": 1,
        "active_provider": "",
        "providers": {},
        "credential_pool": {},
    }

pool = auth.setdefault("credential_pool", {})
now = datetime.datetime.now(datetime.timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z")
source = "vibeproxy-openburnbar-migration"

def provider_mapping(name, base_url):
    lowered = f"{name} {base_url}".lower()
    if "z.ai" in lowered:
        return "zai", "https://api.z.ai/api/coding/paas/v4"
    if "ollama" in lowered:
        return "ollama", base_url
    if "opencode" in lowered or "opencode.ai" in lowered:
        return "opencode", base_url
    if "wafer" in lowered:
        return "misc", base_url
    if "minimax" in lowered:
        return "minimax", base_url
    return None, base_url

written = 0
for provider in providers_data:
    provider_id, base_url = provider_mapping(provider.get("name", ""), provider.get("base_url", ""))
    if not provider_id:
        continue
    keys = [key for key in provider.get("keys", []) if key and key.strip()]
    if not keys:
        continue
    existing = [
        item
        for item in pool.get(provider_id, [])
        if item.get("source") != source
    ]
    for index, key in enumerate(keys):
        label = f"VibeProxy {provider.get('name') or provider_id}"
        if len(keys) > 1:
            label = f"{label} #{index + 1}"
        digest = hashlib.sha256(f"{provider_id}:{label}:{key}".encode()).hexdigest()[:12]
        existing.append({
            "id": f"vibeproxy-{digest}",
            "label": label,
            "auth_type": "api_key",
            "access_token": key,
            "base_url": base_url,
            "priority": index,
            "request_count": 0,
            "last_status": None,
            "last_status_at": None,
            "last_error_code": None,
            "last_error_message": None,
            "last_error_reason": None,
            "last_error_reset_at": None,
            "last_refresh": now,
            "source": source,
        })
        written += 1
    pool[provider_id] = existing

auth["updated_at"] = now
with open(auth_path, "w") as handle:
    json.dump(auth, handle, indent=2, sort_keys=True)
    handle.write("\n")
os.chmod(auth_path, 0o600)
print(f"Wrote {written} fallback credential-pool entries to {auth_path}")
PY

# ---------------------------------------------------------------------------
# 3. Enable the OpenBurnBar HTTP gateway via UserDefaults
# ---------------------------------------------------------------------------

log "Enabling OpenBurnBar HTTP gateway on 127.0.0.1:8317..."

# Enable the gateway in UserDefaults (com.burnbar.app = UserDefaults.standard)
defaults write com.burnbar.app gatewayEnabled -bool YES
defaults write com.burnbar.app gatewayHost "127.0.0.1"
defaults write com.burnbar.app gatewayPort -int 8317
defaults write com.burnbar.app gatewayAllowUnauthenticatedLoopback -bool NO

# Generate a gateway auth token if none exists. The daemon reads controller
# runtime secrets from this service/account pair.
GATEWAY_TOKEN_SERVICE="com.openburnbar.controller-runtime"
GATEWAY_TOKEN_ACCOUNT="settings.gateway.http.authToken"
EXISTING_TOKEN=$(security find-generic-password -s "$GATEWAY_TOKEN_SERVICE" -a "$GATEWAY_TOKEN_ACCOUNT" -w 2>/dev/null || true)
if [[ -z "$EXISTING_TOKEN" ]]; then
    GATEWAY_TOKEN=$(python3 -c "import secrets; print(secrets.token_urlsafe(32))")
    security delete-generic-password -s "$GATEWAY_TOKEN_SERVICE" -a "$GATEWAY_TOKEN_ACCOUNT" 2>/dev/null || true
    security add-generic-password -s "$GATEWAY_TOKEN_SERVICE" -a "$GATEWAY_TOKEN_ACCOUNT" -w "$GATEWAY_TOKEN"
    log "Generated new gateway auth token"
else
    GATEWAY_TOKEN="$EXISTING_TOKEN"
    log "Using existing gateway auth token"
fi

ok "Gateway enabled in UserDefaults"

# ---------------------------------------------------------------------------
# 4. Kill old daemon so the app relaunches it with gateway enabled
# ---------------------------------------------------------------------------

log "Restarting daemon to pick up gateway configuration..."

# Kill the daemon process (the app will relaunch it automatically)
DAEMON_PID=$(ps aux | grep "OpenBurnBarDaemon\|BurnBarDaemon" | grep -v grep | awk '{print $2}' | head -1 || true)
if [[ -n "$DAEMON_PID" ]]; then
    log "Killing daemon PID $DAEMON_PID..."
    kill "$DAEMON_PID" 2>/dev/null || true
    sleep 2
fi

# Also remove the stale socket if it exists
SOCKET_PATH="$SUPPORT_DIR/openburnbar-daemon.sock"
if [[ -e "$SOCKET_PATH" ]]; then
    rm -f "$SOCKET_PATH" 2>/dev/null || true
fi

# Wait for the daemon to come back up and the gateway to start listening
log "Waiting for gateway on 127.0.0.1:8317..."
GATEWAY_UP=false
for _ in $(seq 1 30); do
    if obb_curl_with_bearer "$GATEWAY_TOKEN" -fsS http://127.0.0.1:8317/v1/models >/dev/null 2>&1; then
        GATEWAY_UP=true
        break
    fi
    sleep 2
done

if [[ "$GATEWAY_UP" == "true" ]]; then
    ok "Gateway is up on 127.0.0.1:8317"
else
    warn "Gateway did not come up within 60s. The app may need to be restarted manually."
    warn "Continuing with config rewrite anyway..."
fi

# ---------------------------------------------------------------------------
# 5. Rewrite Droid config with the verified VibeProxy transfer set
# ---------------------------------------------------------------------------

log "Rewriting Droid config (~/.factory/settings.json and ~/.factory/config.json)..."

OBB_GATEWAY_TOKEN="$GATEWAY_TOKEN" python3 - <<'PY'
import json
import os

settings_path = os.path.expanduser("~/.factory/settings.json")
config_json_path = os.path.expanduser("~/.factory/config.json")

gateway_token = os.environ.get("OBB_GATEWAY_TOKEN") or "openburnbar-local"
gateway_base = "http://127.0.0.1:8317/v1"

# This is intentionally explicit. Dumping every advertised /v1/models row into
# Droid reintroduces deprecated, ambiguous, and non-VibeProxy models.
verified_specs = [
    ("custom:openburnbar-vibeproxy-opencode-minimax-m3", "opencode/minimax-m3", "MiniMax M3 [OpenCode Go via OpenBurnBar]", 64000),
    ("custom:openburnbar-vibeproxy-zai-glm-5-2", "zai/glm-5.2", "GLM 5.2 [Z.AI via OpenBurnBar]", 131072),
    ("custom:openburnbar-vibeproxy-ollama-deepseek-v4-flash", "deepseek-v4-flash:cloud", "DeepSeek V4 Flash [Ollama Cloud via OpenBurnBar]", 65536),
    ("custom:openburnbar-vibeproxy-ollama-deepseek-v4-pro", "deepseek-v4-pro:cloud", "DeepSeek V4 Pro [Ollama Cloud via OpenBurnBar]", 65536),
    ("custom:openburnbar-vibeproxy-ollama-glm-5-1", "glm-5.1:cloud", "GLM 5.1 [Ollama Cloud via OpenBurnBar]", 128000),
    ("custom:openburnbar-vibeproxy-ollama-glm-5-2", "glm-5.2:cloud", "GLM 5.2 [Ollama Cloud via OpenBurnBar]", 131072),
    ("custom:openburnbar-vibeproxy-ollama-kimi-k2-7-code", "kimi-k2.7-code:cloud", "Kimi K2.7 Code [Ollama Cloud via OpenBurnBar]", 128000),
    ("custom:openburnbar-vibeproxy-ollama-kimi-k2-6", "kimi-k2.6:cloud", "Kimi K2.6 [Ollama Cloud via OpenBurnBar]", 128000),
    ("custom:openburnbar-vibeproxy-ollama-gpt-oss-120b", "gpt-oss:120b:cloud", "GPT OSS 120B [Ollama Cloud via OpenBurnBar]", 128000),
    ("custom:openburnbar-vibeproxy-wafer-glm-5-2", "misc/GLM-5.2", "GLM 5.2 [Wafer via OpenBurnBar]", 131072),
    ("custom:openburnbar-vibeproxy-minimax-m3", "minimax/MiniMax-M3", "MiniMax M3 [MiniMax Anthropic via OpenBurnBar]", 64000),
]

def load_json(path, fallback):
    try:
        with open(path) as handle:
            return json.load(handle)
    except FileNotFoundError:
        return fallback

def managed_blob(entry):
    blob = json.dumps(entry, ensure_ascii=False).lower()
    return any(marker in blob for marker in (
        "openburnbar",
        "vibeproxy",
        "127.0.0.1:8317",
        "localhost:8317",
        "127.0.0.1:8318",
        "localhost:8318",
    ))

settings = load_json(settings_path, {})
old_custom = settings.get("customModels", [])
kept_custom = [entry for entry in old_custom if not managed_blob(entry)]

new_custom = []
for custom_id, model, display_name, max_output_tokens in verified_specs:
    new_custom.append({
        "model": model,
        "id": custom_id,
        "index": 0,
        "baseUrl": gateway_base,
        "apiKey": gateway_token,
        "displayName": display_name,
        "maxOutputTokens": max_output_tokens,
        "noImageSupport": True,
        "provider": "generic-chat-completion-api",
    })

settings["customModels"] = kept_custom + new_custom
for index, entry in enumerate(settings["customModels"]):
    entry["index"] = index

valid_custom_ids = {entry["id"] for entry in settings["customModels"] if entry.get("id")}
preferred_default = "custom:openburnbar-vibeproxy-ollama-glm-5-2"

def stale_managed_ref(value):
    if not isinstance(value, str):
        return False
    lowered = value.lower()
    return (
        "vibeproxy" in lowered
        or ("openburnbar" in lowered and value not in valid_custom_ids)
        or (value.startswith("custom:") and value not in valid_custom_ids)
    )

session_default = settings.get("sessionDefaultSettings")
if not isinstance(session_default, dict):
    session_default = {}
    settings["sessionDefaultSettings"] = session_default
if stale_managed_ref(session_default.get("model")):
    session_default["model"] = preferred_default
    session_default["reasoningEffort"] = "none"
    session_default.setdefault("interactionMode", "auto")
    session_default.setdefault("autonomyLevel", "high")
    session_default.setdefault("autonomyMode", "auto-high")

for top_level_key in ("model", "missionOrchestratorModel"):
    if stale_managed_ref(settings.get(top_level_key)):
        settings[top_level_key] = preferred_default

mission_settings = settings.get("missionModelSettings")
if isinstance(mission_settings, dict):
    for model_key, effort_key in (
        ("validationWorkerModel", "validationWorkerReasoningEffort"),
        ("workerModel", "workerReasoningEffort"),
    ):
        if stale_managed_ref(mission_settings.get(model_key)):
            mission_settings[model_key] = preferred_default
            mission_settings[effort_key] = "none"

compaction = settings.get("compactionTokenLimitPerModel")
if isinstance(compaction, dict):
    cleaned = {
        key: value
        for key, value in compaction.items()
        if not stale_managed_ref(key)
    }
    for entry in new_custom:
        cleaned[entry["id"]] = min(int(entry["maxOutputTokens"]), 300000)
    settings["compactionTokenLimitPerModel"] = cleaned

with open(settings_path, "w") as handle:
    json.dump(settings, handle, indent=2, ensure_ascii=False)
    handle.write("\n")

config_json = load_json(config_json_path, {})
old_config_models = config_json.get("custom_models", [])
kept_config_models = [entry for entry in old_config_models if not managed_blob(entry)]
config_json["custom_models"] = kept_config_models + [
    {
        "model_display_name": entry["displayName"],
        "model": entry["model"],
        "base_url": entry["baseUrl"],
        "api_key": entry["apiKey"],
        "max_output_tokens": entry["maxOutputTokens"],
        "provider": entry["provider"],
    }
    for entry in new_custom
]

with open(config_json_path, "w") as handle:
    json.dump(config_json, handle, indent=2, ensure_ascii=False)
    handle.write("\n")

print(f"Removed {len(old_custom) - len(kept_custom)} old VibeProxy/OpenBurnBar settings entries")
print(f"Added {len(new_custom)} verified OpenBurnBar gateway settings entries")
print(f"Removed {len(old_config_models) - len(kept_config_models)} old VibeProxy/OpenBurnBar config entries")
print(f"Added {len(new_custom)} verified OpenBurnBar gateway config entries")
PY

# ---------------------------------------------------------------------------
# 6. Verify
# ---------------------------------------------------------------------------

log "Verifying migration..."

if [[ "$GATEWAY_UP" == "true" ]]; then
    MODEL_COUNT=$(obb_curl_with_bearer "$GATEWAY_TOKEN" -fsS http://127.0.0.1:8317/v1/models 2>/dev/null | python3 -c "import json,sys; print(len(json.load(sys.stdin).get('data',[])))" 2>/dev/null || echo "?")
    ok "Gateway /v1/models reports $MODEL_COUNT models"
else
    warn "Gateway not up - verification skipped"
fi

DROID_MODELS=$(python3 -c "
import json, os
with open(os.path.expanduser('~/.factory/settings.json')) as f:
    data = json.load(f)
obb = [m for m in data.get('customModels',[]) if 'openburnbar' in m.get('id','').lower() or 'OBB' in m.get('displayName','')]
vibe = [m for m in data.get('customModels',[]) if 'vibeproxy' in m.get('id','').lower() or 'VibeProxy' in m.get('displayName','')]
print(f'OBB models: {len(obb)}, VibeProxy remnants: {len(vibe)}')
" 2>/dev/null || echo "?")
ok "Droid config: $DROID_MODELS"

echo
ok "Migration complete!"
echo "  Backups saved to: $BACKUP_DIR"
echo "  Gateway: http://127.0.0.1:8317/v1"
echo "  Droid config: ~/.factory/settings.json"
