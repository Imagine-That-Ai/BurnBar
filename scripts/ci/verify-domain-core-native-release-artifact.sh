#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/../.." && pwd)"
consumer="${1:-}"
artifact="${2:-}"
version="${3:-}"

if [[ "$consumer" != "apple" && "$consumer" != "android" ]]; then
  echo "usage: $0 <apple|android> <artifact> <X.Y.Z[+build]>" >&2
  exit 2
fi
if [[ ! "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+(\+[0-9A-Za-z.-]+)?$ ]]; then
  echo "invalid stable release version: $version" >&2
  exit 2
fi
if [[ -z "$artifact" || ! -f "$artifact" || -L "$artifact" ]]; then
  echo "native release artifact must be a regular non-symlink file: $artifact" >&2
  exit 1
fi

artifact="$(cd "$(dirname "$artifact")" && pwd)/$(basename "$artifact")"
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
  apple)
    expected_name="OpenBurnBar-${version}-macOS.dmg"
    ;;
  android)
    expected_name="OpenBurnBar-${version}-Android.aab"
    ;;
esac
if [[ "$(basename "$artifact")" != "$expected_name" ]]; then
  echo "unexpected $consumer artifact name: $(basename "$artifact") (expected $expected_name)" >&2
  exit 1
fi

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
  node "$repo_root/scripts/ci/verify-domain-core-build-profile-artifact.mjs" \
    --profile public-production \
    --apple-app "$app"

  local architectures
  architectures="$(lipo -archs "$executable" | xargs)"
  if [[ "$architectures" != "arm64" ]]; then
    echo "Apple release identity requires an arm64-only app, found: ${architectures:-none}" >&2
    exit 1
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

  node "$repo_root/scripts/ci/verify-domain-core-build-profile-artifact.mjs" \
    --profile public-production \
    --android-aab "$artifact"

  local abi
  for abi in arm64-v8a armeabi-v7a x86 x86_64; do
    if ! grep -Fqx "base/lib/$abi/libopenburnbar_domain_ffi.so" <<<"$signature_listing"; then
      echo "Android release bundle is missing domain-core native ABI: $abi" >&2
      exit 1
    fi
  done
}

if [[ "$consumer" == "apple" ]]; then
  verify_apple
else
  verify_android
fi

echo "verified $consumer domain-core release artifact: $expected_name"
