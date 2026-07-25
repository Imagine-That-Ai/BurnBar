#!/usr/bin/env bash
set -euo pipefail

for variable in REQUIREMENT_ID ENVIRONMENT_ID CANDIDATE_RUN_ID CANDIDATE_ARTIFACT_DIGEST \
  TARGET_HEAD PACKAGE_VERSION MANIFEST_SHA256 MANIFEST_SIGNATURE_SHA256 \
  PREVIOUS_VERSION PREVIOUS_TAG RUNNER_TEMP GITHUB_REPOSITORY; do
  test -n "${!variable:-}" || {
    echo "P-25 prerequisite missing: $variable" >&2
    exit 1
  }
done

input_root="docs/linux-port/evidence/product-parity-inputs/${REQUIREMENT_ID}/${ENVIRONMENT_ID}"
evidence_root="$(mktemp -d "${RUNNER_TEMP}/openburnbar-p25-evidence.XXXXXX")"
previous_root="$evidence_root/previous"
mkdir -p "$previous_root"
cleanup() {
  status=$?
  rm -rf "$evidence_root" || status=1
  exit "$status"
}
trap cleanup EXIT
chmod 700 "$evidence_root" "$previous_root"

if pgrep -f '^/usr/bin/openburnbar-linux-desktop([[:space:]]|$)' >/dev/null; then
  echo "P-25 requires no pre-existing installed desktop process" >&2
  exit 1
fi
case "$ENVIRONMENT_ID" in
  *-aarch64) architecture=aarch64 ;;
  *-x86_64) architecture=x86_64 ;;
  *) echo "P-25 prerequisite missing: unsupported architecture in $ENVIRONMENT_ID" >&2; exit 1 ;;
esac

case "$ENVIRONMENT_ID" in
  ubuntu-*)
    package_channel=deb
    native_arch="$(test "$architecture" = aarch64 && echo arm64 || echo amd64)"
    candidate_package=""
    while IFS= read -r candidate; do
      test "$(dpkg-deb -f "$candidate" Package)" = open-burn-bar || continue
      test "$(dpkg-deb -f "$candidate" Architecture)" = "$native_arch" || continue
      candidate_package="$candidate"
      break
    done < <(find "$input_root" -type f -name '*.deb' -print | sort)
    previous_pattern="OpenBurnBar_${PREVIOUS_VERSION}_${native_arch}.deb"
    ;;
  fedora-*)
    package_channel=rpm
    candidate_package=""
    while IFS= read -r candidate; do
      test "$(rpm -qp --qf '%{NAME}' "$candidate")" = open-burn-bar || continue
      test "$(rpm -qp --qf '%{ARCH}' "$candidate")" = "$architecture" || continue
      candidate_package="$candidate"
      break
    done < <(find "$input_root" -type f -name '*.rpm' -print | sort)
    previous_pattern='*.rpm'
    ;;
  arch-*)
    package_channel=arch
    candidate_package="$(find "$input_root" -type f -name "*-${architecture}.pkg.tar.zst" -print | sort | head -1)"
    previous_pattern="openburnbar-${PREVIOUS_VERSION}-*-${architecture}.pkg.tar.zst"
    ;;
  *) echo "P-25 prerequisite missing: unsupported package environment $ENVIRONMENT_ID" >&2; exit 1 ;;
esac
test -n "$candidate_package" || {
  echo "P-25 prerequisite missing: exact same-architecture candidate package" >&2
  exit 1
}

manifest_name="openburnbar-${PREVIOUS_VERSION}-${package_channel}-${architecture}.installed-manifest.json"
manifest_signature_name="openburnbar-${PREVIOUS_VERSION}-${package_channel}-${architecture}.installed-manifest.ed25519"
if ! gh release download "$PREVIOUS_TAG" \
  --repo "$GITHUB_REPOSITORY" \
  --pattern "$previous_pattern" \
  --pattern "$manifest_name" \
  --pattern "$manifest_signature_name" \
  --pattern 'product-proof-closure.json' \
  --pattern 'product-proof-closure.json.ed25519.sig' \
  --dir "$previous_root"; then
  echo "P-25 prerequisite missing: authenticated same-architecture public release assets" >&2
  exit 1
fi

previous_package=""
case "$package_channel" in
  deb) previous_package="$(find "$previous_root" -maxdepth 1 -type f -name '*.deb' -print | head -1)" ;;
  rpm)
    while IFS= read -r candidate; do
      test "$(rpm -qp --qf '%{NAME}' "$candidate")" = open-burn-bar || continue
      test "$(rpm -qp --qf '%{ARCH}' "$candidate")" = "$architecture" || continue
      previous_package="$candidate"
      break
    done < <(find "$previous_root" -maxdepth 1 -type f -name '*.rpm' -print | sort)
    ;;
  arch) previous_package="$(find "$previous_root" -maxdepth 1 -type f -name '*.pkg.tar.zst' -print | head -1)" ;;
esac
test -n "$previous_package" || {
  echo "P-25 prerequisite missing: exact same-architecture previous native package" >&2
  exit 1
}
test -f "$input_root/.linux-release/product-proof-closure.json"
test -f "$input_root/.linux-release/product-proof-closure.json.ed25519.sig"
case "$ENVIRONMENT_ID" in
  *-gnome-*) compositor=Mutter ;;
  *-kde-*) compositor=KWin ;;
  *-sway-*) compositor=Sway ;;
esac

umask 077
node scripts/linux-port/run-p25-installed-update-lifecycle.mjs \
  --raw-output-dir "$evidence_root" \
  --previous-package "$previous_package" \
  --previous-manifest "$previous_root/$manifest_name" \
  --previous-manifest-signature "$previous_root/$manifest_signature_name" \
  --previous-product-closure "$previous_root/product-proof-closure.json" \
  --previous-product-closure-signature "$previous_root/product-proof-closure.json.ed25519.sig" \
  --previous-release-tag "$PREVIOUS_TAG" \
  --previous-version "$PREVIOUS_VERSION" \
  --candidate-package "$candidate_package" \
  --candidate-manifest /usr/share/openburnbar/attestation/installed-manifest.json \
  --candidate-manifest-signature /usr/share/openburnbar/attestation/installed-manifest.json.sig \
  --candidate-product-closure "$input_root/.linux-release/product-proof-closure.json" \
  --candidate-product-closure-signature "$input_root/.linux-release/product-proof-closure.json.ed25519.sig" \
  --release-public-key packaging/linux/openburnbar-linux-ed25519.pub.pem \
  --package-channel "$package_channel" \
  --architecture "$architecture" \
  --environment "$ENVIRONMENT_ID" \
  --target-head "$TARGET_HEAD" \
  --candidate-run-id "$CANDIDATE_RUN_ID" \
  --candidate-artifact-digest "$CANDIDATE_ARTIFACT_DIGEST" \
  --package-version "$PACKAGE_VERSION" \
  --manifest-sha256 "$MANIFEST_SHA256" \
  --manifest-signature-sha256 "$MANIFEST_SIGNATURE_SHA256" \
  --compositor "$compositor"

node scripts/linux-port/materialize-p25-updates-session.mjs \
  --output-root "$input_root" \
  --raw-evidence-dir "$evidence_root" \
  --environment "$ENVIRONMENT_ID" \
  --target-head "$TARGET_HEAD" \
  --candidate-run-id "$CANDIDATE_RUN_ID" \
  --candidate-artifact-digest "$CANDIDATE_ARTIFACT_DIGEST" \
  --package-version "$PACKAGE_VERSION" \
  --manifest-sha256 "$MANIFEST_SHA256" \
  --manifest-signature-sha256 "$MANIFEST_SIGNATURE_SHA256" \
  --compositor "$compositor" \
  --previous-version "$PREVIOUS_VERSION" \
  --package-channel "$package_channel"

node scripts/linux-port/capture-p25-updates-proof.mjs \
  --input-root "$input_root" \
  --session-report "$input_root/p25-installed-updates-session.json" \
  --environment "$ENVIRONMENT_ID" \
  --target-head "$TARGET_HEAD" \
  --candidate-run-id "$CANDIDATE_RUN_ID" \
  --candidate-artifact-digest "$CANDIDATE_ARTIFACT_DIGEST" \
  --package-version "$PACKAGE_VERSION" \
  --manifest-sha256 "$MANIFEST_SHA256" \
  --manifest-signature-sha256 "$MANIFEST_SIGNATURE_SHA256"
