#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
worker_dir="$repo_root/workers/linux-repository-router"
worker_config="$worker_dir/wrangler.jsonc"
upload_worker_config="$worker_dir/wrangler-upload.jsonc"
control_worker_config="$worker_dir/wrangler-control.jsonc"
feed_worker_config="$worker_dir/wrangler-feed.jsonc"
worker_package="$worker_dir/package.json"
worker_lock="$worker_dir/package-lock.json"

usage() {
  cat <<'EOF'
Usage: scripts/setup-linux-downloads-r2.sh --provision-only|--deploy-only|--feed-only

Creates or inspects the production R2 bucket and branded custom domain, then
deploys the pinned Linux repository Workers.

Required environment:
  CLOUDFLARE_API_TOKEN
  CLOUDFLARE_ACCOUNT_ID
  OPENBURNBAR_R2_BUCKET
  OPENBURNBAR_R2_CUSTOM_DOMAIN
  OPENBURNBAR_R2_ZONE_ID
  OPENBURNBAR_LINUX_REPOSITORY_UPLOAD_TOKEN (provision-only)
  OPENBURNBAR_LINUX_REPOSITORY_ACTIVATION_TOKEN (provision-only)
EOF
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi
case "${1:-}" in
  --provision-only) mode="provision" ;;
  --deploy-only) mode="deploy" ;;
  --feed-only) mode="feed" ;;
  *) echo "setup-linux-downloads-r2.sh accepts only --provision-only, --deploy-only, or --feed-only" >&2; usage >&2; exit 2 ;;
esac
[[ $# -le 1 ]] || { echo "setup-linux-downloads-r2.sh accepts at most one mode" >&2; exit 2; }

require_env() {
  local name="$1"
  if [[ -z "${!name:-}" ]]; then
    echo "required environment variable is missing: $name" >&2
    exit 1
  fi
}

for name in \
  CLOUDFLARE_API_TOKEN \
  CLOUDFLARE_ACCOUNT_ID \
  OPENBURNBAR_R2_BUCKET \
  OPENBURNBAR_R2_CUSTOM_DOMAIN \
  OPENBURNBAR_R2_ZONE_ID; do
  require_env "$name"
done
if [[ "$mode" == "provision" ]]; then
  require_env OPENBURNBAR_LINUX_REPOSITORY_UPLOAD_TOKEN
  require_env OPENBURNBAR_LINUX_REPOSITORY_ACTIVATION_TOKEN
fi

bucket="$OPENBURNBAR_R2_BUCKET"
custom_domain="$OPENBURNBAR_R2_CUSTOM_DOMAIN"
zone_id="$OPENBURNBAR_R2_ZONE_ID"
upload_token="${OPENBURNBAR_LINUX_REPOSITORY_UPLOAD_TOKEN:-}"
activation_token="${OPENBURNBAR_LINUX_REPOSITORY_ACTIVATION_TOKEN:-}"
unset OPENBURNBAR_LINUX_REPOSITORY_UPLOAD_TOKEN || true
unset OPENBURNBAR_LINUX_REPOSITORY_ACTIVATION_TOKEN || true

if [[ ! "$CLOUDFLARE_ACCOUNT_ID" =~ ^[A-Fa-f0-9]{32}$ ]]; then
  echo "CLOUDFLARE_ACCOUNT_ID must be a 32-character hexadecimal account ID" >&2
  exit 1
fi
if [[ ! "$zone_id" =~ ^[A-Fa-f0-9]{32}$ ]]; then
  echo "OPENBURNBAR_R2_ZONE_ID must be a 32-character hexadecimal zone ID" >&2
  exit 1
fi
if [[ ! "$bucket" =~ ^[a-z0-9][a-z0-9-]{1,61}[a-z0-9]$ ]]; then
  echo "OPENBURNBAR_R2_BUCKET is not a canonical R2 bucket name" >&2
  exit 1
fi
if [[ "$custom_domain" != "downloads.burnbar.ai" ]]; then
  echo "OPENBURNBAR_R2_CUSTOM_DOMAIN must be downloads.burnbar.ai" >&2
  exit 1
fi
validate_token() {
  local name="$1"
  local token="$2"
  if ! printf '%s' "$token" | node -e \
      'const fs=require("node:fs");process.exit(/^[A-Za-z0-9._~+/=-]{32,4096}$/.test(fs.readFileSync(0,"utf8"))?0:1)'; then
    echo "$name must contain 32 to 4096 characters from the approved token alphabet" >&2
    exit 1
  fi
}
if [[ "$mode" == "provision" ]]; then
  validate_token OPENBURNBAR_LINUX_REPOSITORY_UPLOAD_TOKEN "$upload_token"
  validate_token OPENBURNBAR_LINUX_REPOSITORY_ACTIVATION_TOKEN "$activation_token"
  if [[ "$upload_token" == "$activation_token" ]]; then
    echo "upload and activation tokens must be distinct" >&2
    exit 1
  fi
fi

for required in "$worker_config" "$upload_worker_config" "$control_worker_config" "$feed_worker_config" "$worker_package" "$worker_lock"; do
  if [[ ! -f "$required" ]]; then
    echo "required pinned Worker deployment file is missing: $required" >&2
    exit 1
  fi
done

expected_wrangler_version="$(node - "$worker_package" "$worker_lock" "$worker_config" "$upload_worker_config" "$control_worker_config" "$feed_worker_config" "$bucket" "$custom_domain" <<'NODE'
const fs = require('node:fs');

const [packagePath, lockPath, configPath, uploadConfigPath, controlConfigPath, feedConfigPath, expectedBucket, expectedDomain] = process.argv.slice(2);
const packageJson = JSON.parse(fs.readFileSync(packagePath, 'utf8'));
const lock = JSON.parse(fs.readFileSync(lockPath, 'utf8'));
const config = JSON.parse(fs.readFileSync(configPath, 'utf8'));
const uploadConfig = JSON.parse(fs.readFileSync(uploadConfigPath, 'utf8'));
const controlConfig = JSON.parse(fs.readFileSync(controlConfigPath, 'utf8'));
const feedConfig = JSON.parse(fs.readFileSync(feedConfigPath, 'utf8'));
const wranglerVersion = packageJson.devDependencies?.wrangler;
if (!/^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$/.test(wranglerVersion ?? '')) {
  throw new Error('Worker package must pin Wrangler to an exact semantic version');
}
if (lock.lockfileVersion !== 3
    || lock.packages?.['']?.devDependencies?.wrangler !== wranglerVersion
    || lock.packages?.['node_modules/wrangler']?.version !== wranglerVersion) {
  throw new Error('Worker package-lock does not pin the configured Wrangler version');
}
const allowedTopLevelKeys = ['$schema', 'compatibility_date', 'main', 'name', 'r2_buckets', 'routes', 'vars', 'workers_dev'];
function validateConfig(value, expectedName, expectedRouteSuffixes, expectedRole, label) {
  if (JSON.stringify(Object.keys(value).sort()) !== JSON.stringify(allowedTopLevelKeys)) {
    throw new Error(`${label} Worker config has an unexpected top-level key`);
  }
  if (value.$schema !== './node_modules/wrangler/config-schema.json'
      || value.name !== expectedName || value.main !== 'src/index.mjs'
      || value.compatibility_date !== '2026-07-10' || value.workers_dev !== false) {
    throw new Error(`${label} Worker identity or runtime contract drifted`);
  }
  if (JSON.stringify(value.vars) !== JSON.stringify({ WORKER_ROLE: expectedRole })) {
    throw new Error(`${label} Worker role drifted`);
  }
  const bindings = (value.r2_buckets ?? []).filter((binding) => binding.binding === 'REPOSITORY_BUCKET');
  if (bindings.length !== 1 || value.r2_buckets.length !== 1 || bindings[0].bucket_name !== expectedBucket
      || JSON.stringify(Object.keys(bindings[0]).sort()) !== JSON.stringify(['binding', 'bucket_name'])) {
    throw new Error(`${label} Worker REPOSITORY_BUCKET binding does not match OPENBURNBAR_R2_BUCKET`);
  }
  const routes = value.routes ?? [];
  if (routes.length !== expectedRouteSuffixes.length
      || routes.some((route) => JSON.stringify(Object.keys(route).sort()) !== JSON.stringify(['pattern', 'zone_name']))) {
    throw new Error(`${label} Worker route set does not match the fail-closed contract`);
  }
  for (const suffix of expectedRouteSuffixes) {
    const expected = `${expectedDomain}${suffix}`;
    if (!routes.some((route) => route.pattern === expected && route.zone_name === 'burnbar.ai')) {
      throw new Error(`${label} Worker route is missing or not bound to burnbar.ai: ${expected}`);
    }
  }
}
validateConfig(config, 'openburnbar-linux-repository-router',
  ['/linux/apt/*', '/linux/rpm/*'], 'serving', 'production repository');
validateConfig(uploadConfig, 'openburnbar-linux-repository-uploader',
  ['/linux/repository-upload/*', '/linux/repository-preview/*'], 'upload', 'immutable upload control plane');
validateConfig(controlConfig, 'openburnbar-linux-repository-control',
  ['/linux/repository-admin/*', '/linux/repository-activations/*', '/linux/update-feed-activation.json',
    '/linux/update-feed-activations/*'],
  'control', 'activation control plane');
validateConfig(feedConfig, 'openburnbar-linux-update-feed',
  ['/latest-linux.json', '/latest-linux.json.ed25519.sig', '/linux/update/*'],
  'feed', 'update feed serving plane');
process.stdout.write(wranglerVersion);
NODE
)"

echo "Installing locked Linux repository Worker dependencies"
npm ci --prefix "$worker_dir" --ignore-scripts --no-audit --no-fund

wrangler="$worker_dir/node_modules/.bin/wrangler"
if [[ ! -x "$wrangler" ]]; then
  echo "locked Wrangler executable was not installed: $wrangler" >&2
  exit 1
fi
installed_wrangler_version="$($wrangler --version | sed -nE 's/.*(^|[[:space:]])([0-9]+\.[0-9]+\.[0-9]+)([[:space:]]|$).*/\2/p' | tail -n 1)"
if [[ "$installed_wrangler_version" != "$expected_wrangler_version" ]]; then
  echo "installed Wrangler version mismatch: expected $expected_wrangler_version, found ${installed_wrangler_version:-unknown}" >&2
  exit 1
fi

export CI=1
export WRANGLER_SEND_METRICS=false

temporary="$(mktemp -d)"
cleanup() {
  rm -rf "$temporary"
}
trap cleanup EXIT

secret_dir="$temporary/secrets"
mkdir -p "$secret_dir"
chmod 700 "$secret_dir"
write_secret_file() {
  local secret_name="$1"
  local secret_value="$2"
  local output="$3"
  node - "$output" "$secret_name" 3< <(printf '%s' "$secret_value") <<'NODE'
const fs = require('node:fs');
const output = process.argv[2];
const secretName = process.argv[3];
const token = fs.readFileSync(3, 'utf8');
fs.writeFileSync(output, `${JSON.stringify({ [secretName]: token })}\n`, { mode: 0o600 });
NODE
  if [[ ! -s "$output" || "$(stat -f '%Lp' "$output" 2>/dev/null || stat -c '%a' "$output")" != "600" ]]; then
    echo "failed to create the protected Worker secret file" >&2
    exit 1
  fi
}

if [[ "$mode" == "provision" ]]; then
  echo "Inspecting R2 bucket: $bucket"
  if ! "$wrangler" r2 bucket info "$bucket" --json --config "$worker_config" >/dev/null 2>&1; then
    echo "Creating R2 bucket: $bucket"
    "$wrangler" r2 bucket create "$bucket" --config "$worker_config"
  fi
  "$wrangler" r2 bucket info "$bucket" --json --config "$worker_config" >/dev/null

  upload_secret_file="$secret_dir/uploader-secrets.json"
  write_secret_file OPENBURNBAR_LINUX_REPOSITORY_UPLOAD_TOKEN "$upload_token" "$upload_secret_file"
  unset upload_token
  echo "Deploying authenticated immutable-upload control plane"
  "$wrangler" deploy \
    --config "$upload_worker_config" \
    --secrets-file "$upload_secret_file" \
    --strict

  activation_secret_file="$secret_dir/control-secrets.json"
  write_secret_file OPENBURNBAR_LINUX_REPOSITORY_ACTIVATION_TOKEN "$activation_token" "$activation_secret_file"
  unset activation_token
  echo "Deploying authenticated repository activation control plane"
  "$wrangler" deploy \
    --config "$control_worker_config" \
    --secrets-file "$activation_secret_file" \
    --strict

  domain_info="$temporary/domain-info"
  echo "Inspecting branded R2 custom domain: $custom_domain"
  if ! "$wrangler" r2 bucket domain get "$bucket" \
    --domain "$custom_domain" \
    --config "$worker_config" >"$domain_info" 2>/dev/null; then
    echo "Attaching branded R2 custom domain: $custom_domain"
    "$wrangler" r2 bucket domain add "$bucket" \
      --domain "$custom_domain" \
      --zone-id "$zone_id" \
      --min-tls 1.2 \
      --force \
      --config "$worker_config"
    "$wrangler" r2 bucket domain get "$bucket" \
      --domain "$custom_domain" \
      --config "$worker_config" >"$domain_info"
  fi
  if ! grep -Fq "$custom_domain" "$domain_info"; then
    echo "R2 custom-domain inspection did not confirm $custom_domain" >&2
    exit 1
  fi

  guard_probe_count=0
  probe_control_guard() {
    local path="$1"
    local body
    local status
    guard_probe_count=$((guard_probe_count + 1))
    body="$temporary/control-guard-$guard_probe_count.json"
    if ! status="$(curl --disable --proto '=https' \
        --retry 30 --retry-all-errors --retry-delay 5 --retry-max-time 180 \
        --connect-timeout 10 --max-time 20 --max-redirs 0 \
        --silent --show-error \
        --header 'Cache-Control: no-cache' \
        --output "$body" \
        --write-out '%{http_code}' \
        "https://$custom_domain$path")"; then
      echo "control guard probe could not reach https://$custom_domain$path after DNS/route propagation retries" >&2
      exit 1
    fi
    if [[ "$status" != "404" ]] || ! node - "$body" <<'NODE'
const fs = require('node:fs');
const value = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'));
const expected = 'repository route is unavailable for this worker role';
if (JSON.stringify(Object.keys(value).sort()) !== JSON.stringify(['error']) || value.error !== expected) process.exit(1);
NODE
    then
      echo "control guard probe did not receive the Worker-owned 404 for https://$custom_domain$path" >&2
      exit 1
    fi
  }
  for guarded_path in \
    /linux/repository-activations/stable.json \
    /linux/repository-activations/prerelease.json \
    /linux/repository-activations/nightly.json \
    /linux/update-feed-activation.json \
    /linux/update-feed-activations/stable.json \
    /linux/update-feed-activations/prerelease.json \
    /linux/update-feed-activations/nightly.json; do
    probe_control_guard "$guarded_path"
  done

  echo "Linux R2 storage and authenticated repository control planes are ready."
  exit 0
fi

if [[ "$mode" == "feed" ]]; then
  echo "Deploying Linux update feed serving routes"
  "$wrangler" deploy \
    --config "$feed_worker_config" \
    --strict
  echo "Linux update feed serving routes are configured."
  exit 0
fi

echo "Deploying Linux repository serving routes"
"$wrangler" deploy \
  --config "$worker_config" \
  --strict

echo "Linux apt/RPM serving routes are configured."
