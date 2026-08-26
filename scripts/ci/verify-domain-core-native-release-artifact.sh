#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/../.." && pwd)"
consumer="${1:-}"
artifact="${2:-}"
version="${3:-}"
profile_name="${4:-}"
candidate_commit="${5:-}"
selected_profile="${6:-}"
observed_identity="${7:-}"
candidate_bundle="${8:-}"
android_abi_manifest="${9:-}"
rust_active="${RUST_ACTIVE:-}"
apple_signing_policy="$repo_root/config/apple-release-signing-policy.json"

if [[ "$consumer" != "apple" && "$consumer" != "android" ]]; then
  echo "usage: $0 <apple|android> <artifact> <version> <profile> <candidate-commit> <selected-profile.json> <observed-identity.json> [candidate-bundle.json android-abi-manifest.json]" >&2
  exit 2
fi
if [[ ! "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z]+([.-][0-9A-Za-z]+)*)?(\+[0-9A-Za-z]+([.-][0-9A-Za-z]+)*)?$ ]]; then
  echo "invalid native release version: $version" >&2
  exit 2
fi
if [[ "$profile_name" != "public-production" && "$profile_name" != "public-production-rollback" ]]; then
  echo "invalid native release profile: $profile_name" >&2
  exit 2
fi
if [[ ! "$candidate_commit" =~ ^[0-9a-f]{40}$ ]]; then
  echo "invalid native release candidate commit" >&2
  exit 2
fi
for pair in "$artifact:native release artifact" "$selected_profile:selected public profile"; do
  path="${pair%%:*}"
  label="${pair#*:}"
  if [[ -z "$path" || ! -f "$path" || -L "$path" || ! -s "$path" ]]; then
    echo "$label must be a nonempty regular non-symlink file: $path" >&2
    exit 1
  fi
done
if [[ "$consumer" == "android" || "$consumer" == "apple" ]]; then
  if [[ -z "$rust_active" ]]; then
    rust_active="$(node -e '
      const fs = require("node:fs");
      const profile = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
      const modes = Object.values(profile.modes ?? {});
      process.stdout.write(String(modes.some((mode) => mode === "rust")));
    ' "$selected_profile")"
  fi
  case "$rust_active" in
    true | false) ;;
    *)
      echo "RUST_ACTIVE must be true or false for $consumer release verification: $rust_active" >&2
      exit 1
      ;;
  esac
  if [[ "$consumer" == "android" && "$rust_active" == "true" && ( -z "$observed_identity" || ! -f "$observed_identity" || -L "$observed_identity" || ! -s "$observed_identity" ) ]]; then
    echo "observed Rust identity must be a nonempty regular non-symlink file: $observed_identity" >&2
    exit 1
  fi
fi
# A legacy release has no attested candidate bundle, so there is nothing to
# bind the packaged domain-core library back to and no ABI manifest to emit.
# Callers omit both arguments in that case; supplying one still requires both.
if [[ "$consumer" == "android" && ( -n "$candidate_bundle" || -n "$android_abi_manifest" ) ]]; then
  if [[ -z "$candidate_bundle" || ! -f "$candidate_bundle" || -L "$candidate_bundle" || ! -s "$candidate_bundle" ]]; then
    echo "protected candidate bundle must be a nonempty regular non-symlink file: $candidate_bundle" >&2
    exit 1
  fi
  if [[ "$android_abi_manifest" != /* || -e "$android_abi_manifest" || -L "$android_abi_manifest" ]]; then
    echo "Android universal ABI manifest output must be an absent absolute non-symlink path: $android_abi_manifest" >&2
    exit 1
  fi
fi
if [[ "$consumer" == "apple" ]]; then
  if [[ "$observed_identity" != /* || -e "$observed_identity" || -L "$observed_identity" ]]; then
    echo "Apple observed Rust identity output must be an absent absolute non-symlink path: $observed_identity" >&2
    exit 1
  fi
  if [[ ! -f "$apple_signing_policy" || -L "$apple_signing_policy" || ! -s "$apple_signing_policy" ]]; then
    echo "Apple signing policy must be a nonempty regular non-symlink file: $apple_signing_policy" >&2
    exit 1
  fi
fi

artifact="$(cd "$(dirname "$artifact")" && pwd)/$(basename "$artifact")"
selected_profile="$(cd "$(dirname "$selected_profile")" && pwd)/$(basename "$selected_profile")"
if [[ -n "$observed_identity" ]]; then
  observed_identity="$(cd "$(dirname "$observed_identity")" && pwd)/$(basename "$observed_identity")"
fi
if [[ -n "$candidate_bundle" ]]; then
  candidate_bundle="$(cd "$(dirname "$candidate_bundle")" && pwd)/$(basename "$candidate_bundle")"
fi
apple_mount_point=""
bundletool_directory=""
cleanup_apple_mount() {
  if [[ -n "$apple_mount_point" ]]; then
    hdiutil detach "$apple_mount_point" -quiet >/dev/null 2>&1 || true
    rm -rf "$apple_mount_point"
  fi
}
cleanup() {
  cleanup_apple_mount
  if [[ -n "$bundletool_directory" ]]; then
    rm -rf "$bundletool_directory"
  fi
}
trap cleanup EXIT

case "$consumer" in
  apple) expected_name="OpenBurnBar-${version}-macOS.dmg" ;;
  android) expected_name="OpenBurnBar-${version}-Android.aab" ;;
esac
if [[ "$(basename "$artifact")" != "$expected_name" ]]; then
  echo "unexpected $consumer artifact name: $(basename "$artifact") (expected $expected_name)" >&2
  exit 1
fi

verify_selected_identity() {
  local binary="$1"
  node "$repo_root/scripts/ci/verify-domain-core-observed-identity.mjs" \
    --profile "$selected_profile" \
    --observed-identity "$observed_identity" \
    --binary "$binary"
}

verify_apple() {
  command -v codesign >/dev/null
  command -v hdiutil >/dev/null
  command -v lipo >/dev/null
  command -v spctl >/dev/null
  command -v xcrun >/dev/null

  codesign --verify --verbose=2 "$artifact"
  xcrun stapler validate "$artifact"

  apple_mount_point="$(mktemp -d "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/domain-core-apple.XXXXXX")"
  hdiutil attach -readonly -nobrowse -mountpoint "$apple_mount_point" "$artifact" >/dev/null
  local app="$apple_mount_point/OpenBurnBar.app"
  local executable="$app/Contents/MacOS/OpenBurnBar"
  if [[ ! -d "$app" || ! -f "$executable" || -L "$executable" ]]; then
    echo "notarized DMG does not contain the expected regular OpenBurnBar executable" >&2
    exit 1
  fi
  codesign --verify --deep --strict --verbose=2 "$app"
  spctl --assess --type execute -vv "$app"
  local dmg_signature app_signature
  dmg_signature="$(mktemp "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/domain-core-dmg-signature.XXXXXX")"
  app_signature="$(mktemp "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/domain-core-app-signature.XXXXXX")"
  codesign -d --verbose=4 "$artifact" > "$dmg_signature" 2>&1
  codesign -d --verbose=4 "$app" > "$app_signature" 2>&1
  node "$repo_root/scripts/ci/verify-domain-core-apple-signing-identity.mjs" \
    --policy "$apple_signing_policy" --signature "$dmg_signature"
  node "$repo_root/scripts/ci/verify-domain-core-apple-signing-identity.mjs" \
    --policy "$apple_signing_policy" --signature "$app_signature"
  rm -f "$dmg_signature" "$app_signature"
  node "$repo_root/scripts/ci/verify-domain-core-build-profile-artifact.mjs" \
    --profile "$profile_name" \
    --expected-candidate-commit "$candidate_commit" \
    --apple-app "$app"

  local architectures
  architectures="$(lipo -archs "$executable" | xargs)"
  if [[ "$architectures" != "arm64" ]]; then
    echo "Apple release identity requires an arm64-only app, found: ${architectures:-none}" >&2
    exit 1
  fi
  DOMAIN_CORE_CANDIDATE_COMMIT="$candidate_commit" \
    "$executable" --domain-core-release-identity-report "$observed_identity"
  if [[ ! -f "$observed_identity" || -L "$observed_identity" || ! -s "$observed_identity" ]]; then
    echo "shipped Apple app did not create a safe nonempty identity report" >&2
    exit 1
  fi
  # The embedded identity is emitted by the Rust domain core. A legacy release
  # ships no Rust slice -- every mode in the selected profile is "legacy" -- so
  # the shipped binary carries no canonical identity and this check demanded
  # something that cannot exist: "found 0". The Android path has always skipped
  # its Rust binding on a legacy release for the same reason; the Apple path was
  # never taught to. A Rust-active release still verifies exactly as before.
  if [[ "$rust_active" == "true" ]]; then
    verify_selected_identity "$executable"
  else
    echo "legacy release: no Rust slice shipped, skipping embedded identity binding"
  fi
  cleanup_apple_mount
  apple_mount_point=""
}

verify_android() {
  command -v curl >/dev/null
  command -v java >/dev/null
  command -v jarsigner >/dev/null
  command -v keytool >/dev/null
  command -v shasum >/dev/null
  command -v unzip >/dev/null

  local approved_fingerprint_file="$repo_root/config/android-upload-certificate.sha256"
  local approved_fingerprint
  approved_fingerprint="$(tr -d '[:space:]' < "$approved_fingerprint_file")"
  if [[ ! "$approved_fingerprint" =~ ^[0-9a-f]{64}$ ]]; then
    echo "approved Android upload certificate fingerprint is invalid" >&2
    exit 1
  fi

  local certificate_output signer_count signer_fingerprint
  certificate_output="$(keytool -printcert -jarfile "$artifact" 2>&1)"
  printf '%s\n' "$certificate_output"
  signer_count="$(grep -Ec '^Signer #[0-9]+:' <<<"$certificate_output" || true)"
  if [[ "$signer_count" != "1" ]]; then
    echo "Android release bundle must have exactly one JAR signer, found: $signer_count" >&2
    exit 1
  fi
  signer_fingerprint="$(awk '
    /^Signer #1:/ { in_signer = 1; next }
    /^Signer #[0-9]+:/ { in_signer = 0 }
    in_signer && /^Certificate #1:/ { in_certificate = 1; next }
    in_signer && in_certificate && /^[[:space:]]*SHA256:/ {
      sub(/^[[:space:]]*SHA256:[[:space:]]*/, "")
      print
      exit
    }
  ' <<<"$certificate_output" | tr -d ':' | tr '[:upper:]' '[:lower:]')"
  if [[ "$signer_fingerprint" != "$approved_fingerprint" ]]; then
    echo "Android release bundle signer does not match the approved upload certificate" >&2
    exit 1
  fi

  local signature_listing
  signature_listing="$(unzip -Z1 "$artifact")"
  if ! grep -Eq '^META-INF/[^/]+\.SF$' <<<"$signature_listing"; then
    echo "Android release bundle is missing a JAR signature manifest" >&2
    exit 1
  fi
  if ! grep -Eq '^META-INF/[^/]+\.(RSA|DSA|EC)$' <<<"$signature_listing"; then
    echo "Android release bundle is missing a JAR signer block" >&2
    exit 1
  fi
  local verify_output
  verify_output="$(jarsigner -verify -verbose -certs "$artifact" 2>&1)"
  printf '%s\n' "$verify_output"
  if ! grep -Fq "jar verified." <<<"$verify_output"; then
    echo "Android release bundle signature verification did not succeed" >&2
    exit 1
  fi

  local bundletool_version="1.18.3"
  local bundletool_sha256="a099cfa1543f55593bc2ed16a70a7c67fe54b1747bb7301f37fdfd6d91028e29"
  local bundletool
  bundletool_directory="$(mktemp -d "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/domain-core-bundletool.XXXXXX")"
  bundletool="$bundletool_directory/bundletool-all-${bundletool_version}.jar"
  curl --fail --location --proto '=https' --tlsv1.2 --silent --show-error \
    --output "$bundletool" \
    "https://github.com/google/bundletool/releases/download/${bundletool_version}/bundletool-all-${bundletool_version}.jar"
  printf '%s  %s\n' "$bundletool_sha256" "$bundletool" | shasum -a 256 -c -
  java -jar "$bundletool" validate --bundle="$artifact"
  local embedded_version
  embedded_version="$(java -jar "$bundletool" dump manifest --bundle="$artifact" --xpath=/manifest/@android:versionName)"
  if [[ "$embedded_version" != "$version" ]]; then
    echo "Android artifact version mismatch: embedded '$embedded_version', expected '$version'" >&2
    exit 1
  fi

  node "$repo_root/scripts/ci/verify-domain-core-build-profile-artifact.mjs" \
    --profile "$profile_name" \
    --expected-candidate-commit "$candidate_commit" \
    --android-aab "$artifact"

  if [[ -n "$candidate_bundle" ]]; then
    node "$repo_root/scripts/ci/verify-domain-core-android-universal-artifact.mjs" \
      --aab "$artifact" \
      --candidate-aar "$repo_root/Vendor/openburnbar-domain-core.aar" \
      --candidate-bundle "$candidate_bundle" \
      --output "$android_abi_manifest"
  fi

  local packaged_library="$bundletool_directory/libopenburnbar_domain_ffi.so"
  unzip -p "$artifact" base/lib/arm64-v8a/libopenburnbar_domain_ffi.so > "$packaged_library"
  if [[ ! -s "$packaged_library" || -L "$packaged_library" ]]; then
    echo "unable to extract packaged Android domain-core native library" >&2
    exit 1
  fi
  if [[ "$rust_active" == "true" ]]; then
    verify_selected_identity "$packaged_library"
  else
    echo "Android release uses legacy domain-core modes; no loaded Rust identity is required."
  fi
}

if [[ "$consumer" == "apple" ]]; then
  verify_apple
else
  verify_android
fi

if [[ "$consumer" == "android" && "$rust_active" != "true" ]]; then
  echo "verified $consumer domain-core release artifact with legacy domain-core modes: $expected_name"
else
  echo "verified $consumer domain-core release artifact and loaded Rust identity: $expected_name"
fi
