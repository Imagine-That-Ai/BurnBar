#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/../.." && pwd)"
fixture="$(mktemp -d "${TMPDIR:-/tmp}/domain-core-native-artifact-test.XXXXXX")"
trap 'rm -rf "$fixture"' EXIT
fake_bin="$fixture/bin"
mkdir -p "$fake_bin"

cat > "$fake_bin/node" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
[[ "$*" == *"verify-domain-core-build-profile-artifact.mjs --profile public-production"* ]]
SH
cat > "$fake_bin/jarsigner" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
echo 'jar verified.'
SH
cat > "$fake_bin/keytool" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
cat <<'EOF'
Signer #1:

Certificate #1:
Owner: CN=OpenBurnBar Upload
SHA256: F5:B2:F0:A3:A7:9D:96:F5:01:E7:5A:20:F7:6B:77:98:9F:32:48:40:F6:88:77:9F:7C:8E:CD:1E:9A:1B:9A:38
EOF
SH
cat > "$fake_bin/curl" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
output=""
while (($#)); do
  if [[ "$1" == --output ]]; then
    shift
    output="$1"
  fi
  shift || true
done
[[ -n "$output" ]]
printf 'pinned bundletool test bytes\n' > "$output"
SH
cat > "$fake_bin/shasum" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
[[ "$*" == '-a 256 -c -' ]]
cat >/dev/null
SH
cat > "$fake_bin/java" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
[[ "$1" == -jar ]]
[[ "$2" == *bundletool-all-1.18.3.jar ]]
[[ "$3" == validate ]]
[[ "$4" == --bundle=* ]]
SH
cat > "$fake_bin/unzip" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
cat <<'EOF'
META-INF/OPENBURN.SF
META-INF/OPENBURN.RSA
base/assets/domain-core-build-profile.json
base/lib/arm64-v8a/libopenburnbar_domain_ffi.so
base/lib/armeabi-v7a/libopenburnbar_domain_ffi.so
base/lib/x86/libopenburnbar_domain_ffi.so
base/lib/x86_64/libopenburnbar_domain_ffi.so
EOF
SH
cat > "$fake_bin/codesign" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
SH
cat > "$fake_bin/xcrun" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
[[ "$1 $2" == 'stapler validate' ]]
SH
cat > "$fake_bin/spctl" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
SH
cat > "$fake_bin/lipo" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
echo arm64
SH
cat > "$fake_bin/hdiutil" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
if [[ "$1" == attach ]]; then
  while (($#)); do
    if [[ "$1" == -mountpoint ]]; then
      shift
      mkdir -p "$1/OpenBurnBar.app/Contents/MacOS"
      : > "$1/OpenBurnBar.app/Contents/MacOS/OpenBurnBar"
      exit 0
    fi
    shift
  done
fi
[[ "$1" == detach ]]
SH
chmod +x "$fake_bin"/*

android="$fixture/OpenBurnBar-1.2.3-Android.aab"
apple="$fixture/OpenBurnBar-1.2.3-macOS.dmg"
: > "$android"
: > "$apple"

PATH="$fake_bin:$PATH" bash "$repo_root/scripts/ci/verify-domain-core-native-release-artifact.sh" \
  android "$android" 1.2.3
PATH="$fake_bin:$PATH" bash "$repo_root/scripts/ci/verify-domain-core-native-release-artifact.sh" \
  apple "$apple" 1.2.3

cat > "$fake_bin/lipo" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
echo 'arm64 x86_64'
SH
chmod +x "$fake_bin/lipo"
if PATH="$fake_bin:$PATH" bash "$repo_root/scripts/ci/verify-domain-core-native-release-artifact.sh" \
  apple "$apple" 1.2.3; then
  echo "universal Apple artifact unexpectedly passed the arm64 identity gate" >&2
  exit 1
fi

cat > "$fake_bin/keytool" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
cat <<'EOF'
Signer #1:
Certificate #1:
SHA256: AA:AA:AA:AA:AA:AA:AA:AA:AA:AA:AA:AA:AA:AA:AA:AA:AA:AA:AA:AA:AA:AA:AA:AA:AA:AA:AA:AA:AA:AA:AA:AA
EOF
SH
chmod +x "$fake_bin/keytool"
if PATH="$fake_bin:$PATH" bash "$repo_root/scripts/ci/verify-domain-core-native-release-artifact.sh" \
  android "$android" 1.2.3; then
  echo "Android artifact signed by an unapproved certificate unexpectedly passed" >&2
  exit 1
fi

cat > "$fake_bin/keytool" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
cat <<'EOF'
Signer #1:
Certificate #1:
SHA256: F5:B2:F0:A3:A7:9D:96:F5:01:E7:5A:20:F7:6B:77:98:9F:32:48:40:F6:88:77:9F:7C:8E:CD:1E:9A:1B:9A:38
EOF
SH
cat > "$fake_bin/java" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
exit 1
SH
chmod +x "$fake_bin/keytool" "$fake_bin/java"
if PATH="$fake_bin:$PATH" bash "$repo_root/scripts/ci/verify-domain-core-native-release-artifact.sh" \
  android "$android" 1.2.3; then
  echo "Android artifact rejected by bundletool unexpectedly passed" >&2
  exit 1
fi

cat > "$fake_bin/java" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
[[ "$1" == -jar ]]
[[ "$2" == *bundletool-all-1.18.3.jar ]]
[[ "$3" == validate ]]
[[ "$4" == --bundle=* ]]
SH
chmod +x "$fake_bin/java"

cat > "$fake_bin/unzip" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
cat <<'EOF'
META-INF/OPENBURN.SF
META-INF/OPENBURN.RSA
base/lib/arm64-v8a/libopenburnbar_domain_ffi.so
EOF
SH
chmod +x "$fake_bin/unzip"
if PATH="$fake_bin:$PATH" bash "$repo_root/scripts/ci/verify-domain-core-native-release-artifact.sh" \
  android "$android" 1.2.3; then
  echo "incomplete Android ABI set unexpectedly passed" >&2
  exit 1
fi

echo "native release artifact verifier tests passed"
