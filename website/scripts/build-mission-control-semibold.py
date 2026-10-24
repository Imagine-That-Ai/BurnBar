#!/usr/bin/env python3
"""Build public/mission-control/fonts/SpaceGrotesk-SemiBold.ttf.

Upstream Space Grotesk ships static Light/Regular/Medium/Bold cuts but no
SemiBold. Mission Control's token type scale names Semibold for titles, so this
script instances the weight from the upstream variable font the same way the
upstream statics were made:

  1. instance `SpaceGrotesk[wght].ttf` at wght=600 (an interpolation between the
     variable font's masters, whose axis runs 300-700 — not an extrapolation),
  2. remove overlaps (the upstream statics are overlap-free),
  3. set SemiBold naming and OS/2 weight 600 within the "Space Grotesk" family,
  4. autohint with ttfautohint defaults (upstream statics: ttfautohint v1.8.3).

The output is byte-reproducible for a given toolchain: `head.modified` is
pinned to the variable font's own timestamp (fontTools and ttfautohint would
both otherwise stamp the build time).

The OFL copyright line declares no Reserved Font Name, so the instance may keep
the Space Grotesk name. The OFL text ships in public/mission-control/licenses/.

Requirements: fonttools, skia-pathops, ttfautohint-py.

Usage:
  git clone https://github.com/floriankarsten/space-grotesk
  git -C space-grotesk checkout 03507d024a01282884232081fc6011c09ff4e849
  python3 scripts/build-mission-control-semibold.py \\
      "space-grotesk/fonts/ttf/SpaceGrotesk[wght].ttf" \\
      public/mission-control/fonts/SpaceGrotesk-SemiBold.ttf
"""

import io
import sys

import ttfautohint
from fontTools.ttLib import TTFont
from fontTools.varLib.instancer import OverlapMode, instantiateVariableFont

WEIGHT = 600
STYLE = "SemiBold"
FAMILY = "Space Grotesk"
POSTSCRIPT = "SpaceGrotesk-SemiBold"


def build(variable_font: str, output: str) -> None:
    source = TTFont(variable_font)
    source_modified = source["head"].modified
    font = instantiateVariableFont(source, {"wght": WEIGHT}, overlap=OverlapMode.REMOVE)
    # Reproducible output: keep the source's timestamp instead of "now".
    font.recalcTimestamp = False
    font["head"].modified = source_modified
    if "STAT" in font:
        del font["STAT"]

    name = font["name"]
    version = name.getDebugName(5)
    for record in list(name.names):
        if record.nameID in (1, 2, 3, 4, 6, 16, 17, 25):
            name.removeNames(nameID=record.nameID)
    for name_id, value in {
        1: f"{FAMILY} {STYLE}",
        2: "Regular",
        3: f"{version};{POSTSCRIPT};instance wght={WEIGHT}",
        4: f"{FAMILY} {STYLE}",
        6: POSTSCRIPT,
        16: FAMILY,
        17: STYLE,
    }.items():
        name.setName(value, name_id, 3, 1, 0x409)
        name.setName(value, name_id, 1, 0, 0)

    os2 = font["OS/2"]
    os2.usWeightClass = WEIGHT
    # fsSelection: clear ITALIC (bit 0), BOLD (bit 5); set REGULAR (bit 6).
    os2.fsSelection = (os2.fsSelection & ~0b0100001) | 0b1000000
    font["head"].macStyle = 0

    unhinted = io.BytesIO()
    font.save(unhinted)
    hinted = TTFont(io.BytesIO(ttfautohint.ttfautohint(in_buffer=unhinted.getvalue())))
    # ttfautohint stamps the current time; restore the pinned timestamp.
    hinted.recalcTimestamp = False
    hinted["head"].modified = source_modified
    hinted.save(output)


if __name__ == "__main__":
    if len(sys.argv) != 3:
        sys.exit(__doc__)
    build(sys.argv[1], sys.argv[2])
