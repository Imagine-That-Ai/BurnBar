#!/usr/bin/env python3
"""Build the Afar logo rasters served by the /mission-control page.

The owner's official master (brand/afar/afar-logo-master.svg) is 5.5 MB with
644 paths and 9 Gaussian-blur filters: far too heavy to inline or to rasterize
in a visitor's browser. Its provenance designates afar-logo-1024.png, the
owner-reviewed render, as the raster source for frontend preparation. This
script:

  1. verifies every imported original against brand/afar/import-receipt.json
     (exactly the three required files, bare names inside brand/afar, no
     symlinks, well-formed hashes) and the hash chain in
     afar-logo-master.provenance.json (master -> 1024 PNG), then checks the PNG
     header is 1024 x 1024 before decoding any pixels,
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
import re
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


REQUIRED_SOURCES = frozenset(
    {"afar-logo-master.svg", "afar-logo-1024.png", "afar-logo-master.provenance.json"}
)
SHA256_HEX = re.compile(r"^[0-9a-f]{64}$")
RASTER_SIZE = (1024, 1024)


def brand_file(name: object) -> Path:
    """Resolve a receipt path to a regular file directly inside BRAND, or exit.

    Rejects anything but a bare required filename: separators, '..', absolute
    paths and symlinks never reach a read.
    """
    if not isinstance(name, str) or name not in REQUIRED_SOURCES or Path(name).name != name:
        sys.exit(f"import-receipt.json names an unexpected file: {name!r}")
    path = BRAND / name
    if path.is_symlink() or not path.is_file():
        sys.exit(f"{name} must be a regular file in website/brand/afar (not a symlink)")
    if path.resolve().parent != BRAND.resolve():
        sys.exit(f"{name} resolves outside website/brand/afar")
    return path


def verify_sources() -> bytes:
    receipt = json.loads((BRAND / "import-receipt.json").read_text())
    entries = receipt.get("files") if isinstance(receipt, dict) else None
    if not isinstance(entries, list) or not all(isinstance(e, dict) for e in entries):
        sys.exit("import-receipt.json must list its files")
    names = [entry.get("path") for entry in entries]
    if len(names) != len(set(map(str, names))) or set(names) != REQUIRED_SOURCES:
        sys.exit(f"import-receipt.json must list exactly {sorted(REQUIRED_SOURCES)}, once each")

    verified: dict[str, bytes] = {}
    for entry in entries:
        path = brand_file(entry["path"])
        expected_sha, expected_bytes = entry.get("sha256"), entry.get("bytes")
        if not isinstance(expected_sha, str) or not SHA256_HEX.fullmatch(expected_sha):
            sys.exit(f"{entry['path']}: receipt sha256 must be 64 lowercase hex characters")
        if type(expected_bytes) is not int or expected_bytes <= 0:
            sys.exit(f"{entry['path']}: receipt bytes must be a positive integer")
        data = path.read_bytes()
        if len(data) != expected_bytes or sha256(data) != expected_sha:
            sys.exit(f"{entry['path']} does not match import-receipt.json")
        verified[entry["path"]] = data

    provenance = json.loads(verified["afar-logo-master.provenance.json"])
    master_sha = sha256(verified["afar-logo-master.svg"])
    png = verified["afar-logo-1024.png"]
    derivatives = provenance.get("derivatives") if isinstance(provenance, dict) else None
    derivative = next(
        (d for d in derivatives or [] if isinstance(d, dict) and d.get("path") == "afar-logo-1024.png"),
        None,
    )
    if derivative is None:
        sys.exit("provenance does not record afar-logo-1024.png as a derivative")
    if provenance.get("sourceSHA256") != master_sha or derivative.get("sourceSHA256") != master_sha:
        sys.exit("provenance master SHA-256 does not match afar-logo-master.svg")
    if derivative.get("sha256") != sha256(png):
        sys.exit("provenance derivative SHA-256 does not match afar-logo-1024.png")
    return png


def open_raster(png: bytes) -> Image.Image:
    """Open the verified PNG and check its header before decoding any pixels."""
    # Image.open reads only the header; refuse anything but the expected
    # 1024 px PNG before load() allocates and decodes the bitmap.
    image = Image.open(io.BytesIO(png), formats=["PNG"])
    if image.size != RASTER_SIZE:
        sys.exit(f"expected a {RASTER_SIZE[0]} px source, got {image.size}")
    image.load()
    return image


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
    source = open_raster(verify_sources())
    # Fully opaque by construction (studio field); drop alpha and all metadata.
    base = source.convert("RGB")

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
