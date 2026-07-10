#!/usr/bin/env bash
# Validate the OpenBurnBar Windows packaging manifests on any host (macOS/Linux/CI).
#
# HARD checks (always run; non-zero exit on failure):
#   • XML well-formedness (xmllint) of Package.appxmanifest, the .wapproj, the .nuspec.
#   • YAML parse of the three winget manifests + structural rules against the winget
#     1.6.0 manifest schema (types, required keys, enums, SHA256/URL patterns).
#   • JSON parse of portable-layout.json.
#   • PowerShell parse of *.ps1 (only if `pwsh` is installed).
#
# SOFT checks (best-effort; SKIP without network/deps, never fail the run):
#   • Full JSON-Schema validation of the winget YAMLs against the published schema.
#   • JSON-Schema validation of portable-layout.json against portable-layout.schema.json.
#   • NuGet-core-subset XSD validation of the .nuspec.
#
# This is the macOS ceiling. The Windows-only gates (MakeAppx AppxManifest XSD,
# `winget validate`, `choco pack`) run on the Windows dev host / CI with the W0 cert.
set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
pkg_root="$(cd "$here/.." && pwd)"
fail=0
note() { printf '  %s\n' "$*"; }
ok()   { printf 'OK   %s\n' "$*"; }
err()  { printf 'FAIL %s\n' "$*" >&2; fail=1; }
skip() { printf 'SKIP %s\n' "$*"; }

echo "== XML well-formedness (xmllint) =="
for f in \
  "$pkg_root/msix/Package.appxmanifest" \
  "$pkg_root/msix/OpenBurnBar.Packaging.wapproj" \
  "$pkg_root/chocolatey/openburnbar.nuspec"; do
  if xmllint --noout "$f" 2>/tmp/obb_xmllint.err; then ok "$(basename "$f")"; else err "$(basename "$f"): $(cat /tmp/obb_xmllint.err)"; fi
done

echo "== WAP project-reference property isolation =="
python3 - "$pkg_root" <<'PY' || fail=1
import pathlib
import sys
import xml.etree.ElementTree as ET

project = pathlib.Path(sys.argv[1]) / "msix" / "OpenBurnBar.Packaging.wapproj"
namespace = {"msb": "http://schemas.microsoft.com/developer/msbuild/2003"}
root = ET.parse(project).getroot()
reference = root.find(".//msb:ProjectReference", namespace)
if reference is None:
    raise SystemExit("FAIL WAP app ProjectReference is missing")
removed = reference.find("msb:GlobalPropertiesToRemove", namespace)
values = set((removed.text if removed is not None and removed.text else "").split(";"))
required = {
    "GenerateAppxPackageOnBuild",
    "AppxPackageDir",
    "AppxPackageSigningEnabled",
    "AppxBundle",
    "AppxBundlePlatforms",
    "UapAppxPackageBuildMode",
    "AppxSymbolPackageEnabled",
}
missing = sorted(required - values)
if missing:
    raise SystemExit(f"FAIL WAP ProjectReference leaks package globals: {', '.join(missing)}")
print("OK   WAP package globals do not propagate into the unpackaged WinUI project")
PY

echo "== JSON parse (portable layout + schema) =="
python3 - "$pkg_root" <<'PY' || fail=1
import json, sys
root = sys.argv[1]
p = f"{root}/portable/portable-layout.json"
try:
    layout = json.load(open(p))
    print(f"OK   {p.split('/')[-1]} parsed")
except Exception as e:
    print(f"FAIL portable-layout.json: {e}", file=sys.stderr); sys.exit(1)
# structural spot checks independent of jsonschema
assert layout["entryPoint"].endswith(".exe"), "entryPoint must be an .exe"
assert layout["architectures"], "architectures must be non-empty"
print("OK   portable-layout structural checks")
PY

echo "== MSIX visual assets =="
python3 - "$pkg_root" <<'PY' || fail=1
import pathlib
import struct
import sys

root = pathlib.Path(sys.argv[1])
expected = {
    "Square44x44Logo.png": (44, 44),
    "Square150x150Logo.png": (150, 150),
    "SmallTile.png": (71, 71),
    "LargeTile.png": (310, 310),
    "Wide310x150Logo.png": (310, 150),
    "StoreLogo.png": (50, 50),
}
errors = []
for name, dimensions in expected.items():
    path = root / "msix" / "Images" / name
    if not path.is_file():
        errors.append(f"{name}: missing")
        continue
    data = path.read_bytes()
    if len(data) < 24 or not data.startswith(b"\x89PNG\r\n\x1a\n"):
        errors.append(f"{name}: not a PNG")
        continue
    width, height = struct.unpack(">II", data[16:24])
    if (width, height) != dimensions:
        errors.append(f"{name}: expected {dimensions[0]}x{dimensions[1]}, got {width}x{height}")
if errors:
    for error in errors:
        print(f"FAIL msix asset {error}", file=sys.stderr)
    sys.exit(1)
print("OK   MSIX manifest PNG assets exist with expected scale-100 dimensions")
PY

echo "== winget manifests (YAML + structural schema rules) =="
python3 - "$pkg_root" <<'PY' || fail=1
import sys, re, glob
root = sys.argv[1]
try:
    import yaml
except Exception as e:
    print(f"FAIL pyyaml not available: {e}", file=sys.stderr); sys.exit(1)

d = f"{root}/winget/manifests/i/ImagineThat/OpenBurnBar/0.1.0"
SHA = re.compile(r"^[A-Fa-f0-9]{64}$")
URL = re.compile(r"^[Hh][Tt][Tt][Pp][Ss]?://.+$")
ARCH = {"x86", "x64", "arm", "arm64", "neutral"}
MV = re.compile(r"^\d+\.\d+\.\d+$")
errs = []

def load(name):
    with open(f"{d}/{name}") as fh:
        return yaml.safe_load(fh)

ver = load("ImagineThat.OpenBurnBar.yaml")
inst = load("ImagineThat.OpenBurnBar.installer.yaml")
loc = load("ImagineThat.OpenBurnBar.locale.en-US.yaml")

# version manifest
for k in ("PackageIdentifier", "PackageVersion", "DefaultLocale", "ManifestType", "ManifestVersion"):
    if k not in ver: errs.append(f"version: missing {k}")
if ver.get("ManifestType") != "version": errs.append("version: ManifestType must be 'version'")

# installer manifest
for k in ("PackageIdentifier", "PackageVersion", "Installers", "ManifestType", "ManifestVersion"):
    if k not in inst: errs.append(f"installer: missing {k}")
if inst.get("ManifestType") != "installer": errs.append("installer: ManifestType must be 'installer'")
for it in inst.get("InstallerType") and [inst["InstallerType"]] or []:
    if it not in {"msix","msi","appx","exe","zip","inno","nullsoft","wix","burn","pwa","portable"}:
        errs.append(f"installer: bad InstallerType {it}")
for i, ins in enumerate(inst.get("Installers", [])):
    for k in ("Architecture", "InstallerUrl", "InstallerSha256"):
        if k not in ins: errs.append(f"installer[{i}]: missing {k}")
    if ins.get("Architecture") not in ARCH: errs.append(f"installer[{i}]: bad Architecture {ins.get('Architecture')}")
    if not URL.match(str(ins.get("InstallerUrl",""))): errs.append(f"installer[{i}]: InstallerUrl not http(s)")
    if not SHA.match(str(ins.get("InstallerSha256",""))): errs.append(f"installer[{i}]: InstallerSha256 not 64-hex")
# ReleaseDate must stay a string YYYY-MM-DD (an unquoted date loads as a date object,
# which the winget schema rejects — catch that here without needing jsonschema).
if "ReleaseDate" in inst:
    rd = inst["ReleaseDate"]
    if not isinstance(rd, str) or not re.match(r"^\d{4}-\d{2}-\d{2}$", rd):
        errs.append(f"installer: ReleaseDate must be a quoted YYYY-MM-DD string (got {type(rd).__name__}: {rd!r})")

# defaultLocale manifest
for k in ("PackageIdentifier","PackageVersion","PackageLocale","Publisher","PackageName","License","ShortDescription","ManifestType","ManifestVersion"):
    if k not in loc: errs.append(f"locale: missing {k}")
if loc.get("ManifestType") != "defaultLocale": errs.append("locale: ManifestType must be 'defaultLocale'")

# cross-manifest consistency
ids = {ver.get("PackageIdentifier"), inst.get("PackageIdentifier"), loc.get("PackageIdentifier")}
if len(ids) != 1: errs.append(f"PackageIdentifier mismatch across manifests: {ids}")
vers = {str(ver.get("PackageVersion")), str(inst.get("PackageVersion")), str(loc.get("PackageVersion"))}
if len(vers) != 1: errs.append(f"PackageVersion mismatch across manifests: {vers}")
for m,name in ((ver,"version"),(inst,"installer"),(loc,"locale")):
    if str(m.get("ManifestVersion")) != "1.6.0": errs.append(f"{name}: ManifestVersion must be 1.6.0")

if errs:
    for e in errs: print(f"FAIL winget {e}", file=sys.stderr)
    sys.exit(1)
print("OK   winget version/installer/locale: required keys, enums, SHA256/URL patterns, cross-manifest consistency")
PY

echo "== SOFT: full JSON-Schema validation (jsonschema, if available) =="
if python3 -c "import jsonschema" 2>/dev/null; then
  if ! python3 - "$pkg_root" <<'PY'
import json, sys, urllib.request, glob
root = sys.argv[1]
import jsonschema, yaml
def fetch(u):
    with urllib.request.urlopen(u, timeout=15) as r: return json.load(r)
try:
    schemas = {t: fetch(f"https://aka.ms/winget-manifest.{t}.1.6.0.schema.json") for t in ("version","installer","defaultLocale")}
except Exception as e:
    print(f"SKIP winget JSON-Schema (fetch failed: {e})"); sys.exit(0)
d = f"{root}/winget/manifests/i/ImagineThat/OpenBurnBar/0.1.0"
pairs = [("ImagineThat.OpenBurnBar.yaml","version"),
         ("ImagineThat.OpenBurnBar.installer.yaml","installer"),
         ("ImagineThat.OpenBurnBar.locale.en-US.yaml","defaultLocale")]
bad=0
for fn,t in pairs:
    doc = yaml.safe_load(open(f"{d}/{fn}"))
    try:
        jsonschema.validate(doc, schemas[t]); print(f"OK   jsonschema {fn}")
    except jsonschema.ValidationError as e:
        print(f"FAIL jsonschema {fn}: {e.message} at {'/'.join(map(str,e.path))}", file=sys.stderr); bad=1
# portable layout against its own schema
lp = json.load(open(f"{root}/portable/portable-layout.json"))
ls = json.load(open(f"{root}/portable/portable-layout.schema.json"))
try:
    jsonschema.validate(lp, ls); print("OK   jsonschema portable-layout.json")
except jsonschema.ValidationError as e:
    print(f"FAIL jsonschema portable-layout: {e.message}", file=sys.stderr); bad=1
sys.exit(bad)
PY
  then
    fail=1
  fi
else
  skip "jsonschema not importable (structural rules above already ran as the hard gate)"
fi

echo "== SOFT: nuspec NuGet-core XSD validation =="
xsd_tmp="$(mktemp)"
if curl -fsSL --max-time 15 -o "$xsd_tmp" "https://raw.githubusercontent.com/NuGet/NuGet.Client/dev/src/NuGet.Core/NuGet.Packaging/compiler/resources/nuspec.xsd" 2>/dev/null && [ -s "$xsd_tmp" ]; then
  ns="http://schemas.microsoft.com/packaging/2015/06/nuspec.xsd"
  sed "s|{0}|$ns|g" "$xsd_tmp" > "${xsd_tmp}.ns"
  core_tmp="$(mktemp).nuspec"
  python3 - "$pkg_root/chocolatey/openburnbar.nuspec" "$core_tmp" "$ns" <<'PY'
import sys, xml.etree.ElementTree as ET
src, dst, ns = sys.argv[1], sys.argv[2], sys.argv[3]
ET.register_namespace('', ns)
tree = ET.parse(src); root = tree.getroot()
meta = root.find(f'{{{ns}}}metadata')
# Drop Chocolatey-superset elements the base NuGet 2015 xsd doesn't model.
choco_only = {'packageSourceUrl','projectSourceUrl','docsUrl','bugTrackerUrl','mailingListUrl'}
for el in list(meta):
    tag = el.tag.split('}')[-1]
    if tag in choco_only: meta.remove(el)
tree.write(dst, xml_declaration=True, encoding='utf-8')
PY
  if xmllint --noout --schema "${xsd_tmp}.ns" "$core_tmp" 2>/tmp/obb_nuspec.err; then
    ok "nuspec NuGet-core subset valid against nuspec.xsd (choco-superset elements gated by 'choco pack')"
  else
    err "nuspec core XSD: $(cat /tmp/obb_nuspec.err)"
  fi
else
  skip "nuspec.xsd fetch failed (well-formedness already passed above)"
fi

echo "== SOFT: PowerShell parse (pwsh, if available) =="
if command -v pwsh >/dev/null 2>&1; then
  for ps in "$pkg_root"/portable/New-PortableZip.ps1 "$pkg_root"/chocolatey/tools/*.ps1; do
    if pwsh -NoProfile -NonInteractive -Command "\$e=\$null;[void][System.Management.Automation.Language.Parser]::ParseFile('$ps',[ref]\$null,[ref]\$e); if(\$e){\$e|%{Write-Error \$_.Message}; exit 1} else { exit 0 }" 2>/tmp/obb_ps.err; then
      ok "pwsh parse $(basename "$ps")"
    else
      err "pwsh parse $(basename "$ps"): $(cat /tmp/obb_ps.err)"
    fi
  done
else
  skip "pwsh not installed (PowerShell syntax gated on the Windows/CI runner)"
fi

echo
if [ "$fail" -ne 0 ]; then echo "PACKAGING VERIFY: FAILED" >&2; exit 1; fi
echo "PACKAGING VERIFY: PASSED (macOS ceiling; Windows-only gates deferred)"
