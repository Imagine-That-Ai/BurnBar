#!/usr/bin/env python3
"""Build the Afar logo rasters served by the /mission-control page.

The owner's official master (brand/afar/afar-logo-master.svg) is 5.5 MB with
644 paths and 9 Gaussian-blur filters: far too heavy to inline or to rasterize
in a visitor's browser. Its provenance designates afar-logo-1024.png, the
owner-reviewed render, as the raster source for frontend preparation. This
script:

  1. verifies every imported original against brand/afar/import-receipt.json
     and the hash chain in afar-logo-master.provenance.json (master -> 1024 PNG),
  2. downsamples the reviewed 1024 PNG (Lanczos, opaque sRGB, no metadata) to
     each responsive width as AVIF and WebP, plus one PNG fallback,
  3. writes public/afar/* and src/data/afar-icons.json, which lists every file
     with its width, bytes and SHA-256 so the page builds srcsets from data.

The artwork is never redrawn, cropped or recolored. Output is deterministic for
a given Pillow/libavif/libwebp build.

Usage (from website/):
  python3 scripts/build-afar-icons.py          # write outputs
  python3 scripts/build-afar-icons.py --check  # verify outputs match, exit 1 if not
"""

import hashlib
import io
import json
import sys
from pathlib import Path

from PIL import Image, features

WEBSITE = Path(__file__).resolve().parent.parent
BRAND = WEBSITE / "brand" / "afar"
PUBLIC_DIR = WEBSITE / "public" / "afar"
MANIFEST = WEBSITE / "src" / "data" / "afar-icons.json"

WIDTHS = (32, 64, 96, 128, 192, 256, 384, 512)
FALLBACK_WIDTH = 256
ALT = (
    "Afar app icon: a clear glass crescent holding a pink, orange and yellow glow, "
    "with a small chrome sphere beside it"
)


def sha256(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def verify_sources() -> bytes:
    receipt = json.loads((BRAND / "import-receipt.json").read_text())
    for entry in receipt["files"]:
        data = (BRAND / entry["path"]).read_bytes()
        if sha256(data) != entry["sha256"] or len(data) != entry["bytes"]:
            sys.exit(f"{entry['path']} does not match import-receipt.json")

    provenance = json.loads((BRAND / "afar-logo-master.provenance.json").read_text())
    master_sha = sha256((BRAND / "afar-logo-master.svg").read_bytes())
    png = (BRAND / "afar-logo-1024.png").read_bytes()
    derivative = next(d for d in provenance["derivatives"] if d["path"] == "afar-logo-1024.png")
    if provenance["sourceSHA256"] != master_sha or derivative["sourceSHA256"] != master_sha:
        sys.exit("provenance master SHA-256 does not match afar-logo-master.svg")
    if derivative["sha256"] != sha256(png):
        sys.exit("provenance derivative SHA-256 does not match afar-logo-1024.png")
    return png


def encode(image: Image.Image, fmt: str) -> bytes:
    out = io.BytesIO()
    if fmt == "avif":
        image.save(out, "AVIF", quality=72, speed=4)
    elif fmt == "webp":
        image.save(out, "WEBP", quality=86, method=6)
    else:
        image.save(out, "PNG", optimize=True)
    return out.getvalue()


def build() -> dict[str, bytes]:
    for codec in ("avif", "webp"):
        if not features.check(codec):
            sys.exit(f"Pillow was built without {codec} support")
    source = Image.open(io.BytesIO(verify_sources()))
    source.load()
    # Fully opaque by construction (studio field); drop alpha and all metadata.
    base = source.convert("RGB")
    if source.size != (1024, 1024):
        sys.exit(f"expected a 1024 px source, got {source.size}")

    files: dict[str, bytes] = {}
    manifest = {
        "schemaVersion": 1,
        "generator": "website/scripts/build-afar-icons.py",
        "source": {
            "receipt": "website/brand/afar/import-receipt.json",
            "masterSHA256": sha256((BRAND / "afar-logo-master.svg").read_bytes()),
            "rasterSHA256": sha256((BRAND / "afar-logo-1024.png").read_bytes()),
        },
        "alt": ALT,
        "intrinsicSize": 1024,
        "formats": {"avif": [], "webp": []},
        "fallback": None,
    }
    for width in WIDTHS:
        image = base.resize((width, width), Image.Resampling.LANCZOS)
        for fmt in ("avif", "webp"):
            name = f"afar-icon-{width}.{fmt}"
            data = encode(image, fmt)
            files[name] = data
            manifest["formats"][fmt].append(
                {"width": width, "path": f"/afar/{name}", "bytes": len(data), "sha256": sha256(data)}
            )
        if width == FALLBACK_WIDTH:
            name = f"afar-icon-{width}.png"
            data = encode(image, "png")
            files[name] = data
            manifest["fallback"] = {
                "width": width,
                "path": f"/afar/{name}",
                "bytes": len(data),
                "sha256": sha256(data),
            }
    files["__manifest__"] = (json.dumps(manifest, indent=2) + "\n").encode()
    return files


def main() -> None:
    check = "--check" in sys.argv[1:]
    files = build()
    stale = []
    for name, data in files.items():
        target = MANIFEST if name == "__manifest__" else PUBLIC_DIR / name
        if check:
            if not target.exists() or target.read_bytes() != data:
                stale.append(str(target.relative_to(WEBSITE)))
        else:
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_bytes(data)
    expected = {name for name in files if name != "__manifest__"}
    extra = sorted(p.name for p in PUBLIC_DIR.glob("*") if p.name not in expected) if PUBLIC_DIR.exists() else []
    if check:
        if stale or extra:
            sys.exit(f"Afar icons are stale: {stale + extra}; run scripts/build-afar-icons.py")
        print(f"afar-icons: {len(expected)} rasters and manifest match the verified originals")
    else:
        for name in extra:
            (PUBLIC_DIR / name).unlink()
        print(f"afar-icons: wrote {len(expected)} rasters and {MANIFEST.relative_to(WEBSITE)}")


if __name__ == "__main__":
    main()
