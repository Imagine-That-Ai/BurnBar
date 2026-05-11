#!/usr/bin/env python3
"""Generate 8x8 TC001/AWTRIX provider logo constants from bundled assets."""

from __future__ import annotations

import os
import re
import shutil
import subprocess
from dataclasses import dataclass
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[1]
ASSET_ROOTS = [
    REPO_ROOT / "AgentLens" / "Resources" / "Assets.xcassets",
    REPO_ROOT / "OpenBurnBarMobile" / "Resources" / "Assets.xcassets",
]
OUTPUT = (
    REPO_ROOT
    / "OpenBurnBarCore"
    / "Sources"
    / "OpenBurnBarCore"
    / "PixelClockProviderLogoAssets.generated.swift"
)


@dataclass(frozen=True)
class LogoSource:
    property_name: str
    asset_name: str
    source_label: str
    light_backdrop: bool = False
    pixel_rows: tuple[str, ...] | None = None
    pixel_colors: dict[str, str] | None = None


LOGOS = [
    LogoSource(
        # Anthropic's "Claude Crab" — chunky pixel crab matching the
        # reference art Alberto provided. Solid 6-wide coral shell
        # with two dark eyes, *little arms poking straight out to the
        # sides* a row below the shell top, and four short legs at
        # the bottom. No antennae, no joints.
        "claudeCode",
        "OpenClawLogo",
        "OpenClawLogo",
        pixel_rows=(
            "........",
            ".AAAAAA.",
            ".AEAAEA.",
            "AAAAAAAA",
            "AAAAAAAA",
            "A.A..A.A",
            "A.A..A.A",
            "........",
        ),
        pixel_colors={
            "A": "#D97757",
            "E": "#1A1208",
        },
    ),
    LogoSource(
        # Codex — left-side white staircase + right-hand horizontal
        # white bar (dropped one row from the original stencil). All
        # the negative space adjacent to the staircase is filled with
        # the body's light blue so the staircase reads as a clean
        # white stroke on a continuous silhouette rather than letting
        # the TC001's black grid bleed through.
        "codex",
        "CodexLogo",
        "CodexLogo",
        pixel_rows=(
            "..AAAA..",
            ".AAAAAA.",
            "AAAAAAAA",
            "AAWAAAAA",
            "AAAWAAAA",
            "AAWAAWWW",
            ".BBBBBB.",
            "..BBBB..",
        ),
        pixel_colors={
            "A": "#8EA0FF",
            "B": "#4258FF",
            "W": "#FFFFFF",
        },
    ),
    LogoSource("copilot", "CopilotLogo", "CopilotLogo"),
    LogoSource(
        # MiniMax — three interleaved ribbon strands. Outer strands are
        # magenta (#EC1970), the middle strand is coral (#FF5B3F).
        # Two visible weave bands cross the legs: the magenta strand
        # passes over the coral one, and the coral strand passes over
        # the magenta, producing a clear over/under braid even at 8×8.
        "miniMax",
        "MiniMaxLogo",
        "MiniMaxLogo",
        pixel_rows=(
            "PP.OO.PP",
            "PP.OO.PP",
            "PPOOOPPP",
            "PP.OO.PP",
            "PP.OO.PP",
            "PPOOOPPP",
            "PP.OO.PP",
            "PP.OO.PP",
        ),
        pixel_colors={
            "P": "#EC1970",
            "O": "#FF5B3F",
        },
    ),
    LogoSource(
        # Z.ai — slanted bold "Z" matching the brand mark: thick top
        # bar, 3-pixel diagonal stem running top-right to bottom-left,
        # thick bottom bar. The bottom edge of each bar is shaded with
        # the brand lavender (#C9B6FF) so the silhouette reads with a
        # subtle drop shadow on the TC001 grid.
        "zai",
        "ZaiLogo",
        "ZaiLogo",
        pixel_rows=(
            "ZZZZZZZ.",
            "zzzzzzz.",
            "....ZZZ.",
            "...ZZZ..",
            "..ZZZ...",
            ".ZZZ....",
            ".ZZZZZZZ",
            ".zzzzzzz",
        ),
        pixel_colors={
            "Z": "#FFFFFF",
            "z": "#C9B6FF",
        },
    ),
    LogoSource(
        # Factory — the brand's sunburst mark: eight rounded petals
        # radiating from a central hub. Petals are white; the inner
        # 2×2 hub is a soft grey (#B8B8B8) so the centre reads as a
        # distinct knob even at 8×8, matching the negative-space
        # treatment of the real black-on-white brand mark.
        "factory",
        "FactoryLogo",
        "FactoryLogo",
        pixel_rows=(
            "F..FF..F",
            ".F.FF.F.",
            "..FFFF..",
            "FFFGGFFF",
            "FFFGGFFF",
            "..FFFF..",
            ".F.FF.F.",
            "F..FF..F",
        ),
        pixel_colors={
            "F": "#FFFFFF",
            "G": "#B8B8B8",
        },
    ),
    LogoSource("cursor", "CursorLogo", "CursorLogo", light_backdrop=True),
    LogoSource("warp", "WarpLogo", "WarpLogo", light_backdrop=True),
    LogoSource(
        # Ollama — keep the simple white llama silhouette from the brand
        # mark, but replace only the eyes with saturated blue pixels so it
        # reads on the physical TC001 without turning into a generic block.
        "ollama",
        "OllamaLogo",
        "OllamaLogo",
        pixel_rows=(
            ".O....O.",
            ".OO..OO.",
            "OOOOOOOO",
            "OOB..BOO",
            "OOOOOOOO",
            "OGGOOGGO",
            ".OOOOOO.",
            "..OOOO..",
        ),
        pixel_colors={
            "O": "#F6F8FF",
            "B": "#1EA7FF",
            "G": "#AEB7C2",
        },
    ),
    LogoSource("kimi", "KimiLogo", "KimiLogo"),
]


def convert_binary() -> str:
    for candidate in (
        shutil.which("magick"),
        shutil.which("convert"),
        "/opt/homebrew/bin/convert",
        "/Users/albertonunez/.homebrew/bin/convert",
        "/usr/local/bin/convert",
    ):
        if candidate and Path(candidate).exists():
            return candidate
    raise SystemExit("ImageMagick convert/magick is required to generate pixel clock logos.")


def find_asset(asset_name: str) -> Path:
    filenames = [f"{asset_name}.png", f"{asset_name}.svg", f"{asset_name}.pdf"]
    for root in ASSET_ROOTS:
        for filename in filenames:
            matches = list(root.glob(f"{asset_name}.imageset/{filename}"))
            if matches:
                return matches[0]
    raise SystemExit(f"Could not find bundled asset for {asset_name}.")


def rsvg_binary() -> str | None:
    return shutil.which("rsvg-convert")


def source_png_bytes(source: Path) -> bytes | None:
    if source.suffix.lower() != ".svg":
        return None
    rsvg = rsvg_binary()
    if rsvg is None:
        return None
    return subprocess.run(
        [rsvg, "--width", "512", "--height", "512", str(source)],
        check=True,
        stdout=subprocess.PIPE,
    ).stdout


def run_convert(binary: str, source: Path, light_backdrop: bool) -> str:
    if Path(binary).name == "magick":
        cmd = [binary]
    else:
        cmd = [binary]

    background = "white" if light_backdrop else "transparent"
    png_bytes = source_png_bytes(source)
    input_source = "png:-" if png_bytes is not None else str(source)
    first = cmd + [
        "-background",
        background,
        input_source,
        "-resize",
        "8x8",
        "-gravity",
        "center",
        "-extent",
        "8x8",
    ]
    if light_backdrop:
        first += ["-alpha", "remove", "-alpha", "off"]
    first += ["PNG32:-"]

    raster = subprocess.run(first, input=png_bytes, check=True, stdout=subprocess.PIPE).stdout
    second = cmd + ["png:-", "txt:-"]
    return subprocess.run(second, input=raster, check=True, stdout=subprocess.PIPE, text=False).stdout.decode()


def parse_pixels(txt: str, light_backdrop: bool) -> list[list[str | None]]:
    rows: list[list[str | None]] = [[None for _ in range(8)] for _ in range(8)]
    pattern = re.compile(r"^(\d+),(\d+): \(([^)]+)\)")
    for line in txt.splitlines():
        match = pattern.match(line)
        if not match:
            continue
        x = int(match.group(1))
        y = int(match.group(2))
        values = [int(float(part.strip())) for part in match.group(3).split(",")]
        if len(values) == 2:
            gray, alpha = values
            red = green = blue = gray
        elif len(values) >= 4:
            red, green, blue, alpha = values[:4]
        else:
            red, green, blue = values[:3]
            alpha = 255

        if max(red, green, blue, alpha) > 255:
            red = round(red / 257)
            green = round(green / 257)
            blue = round(blue / 257)
            alpha = round(alpha / 257)

        if not light_backdrop:
            if alpha < 32:
                rows[y][x] = None
                continue
            red = round(red * alpha / 255)
            green = round(green * alpha / 255)
            blue = round(blue * alpha / 255)
            if max(red, green, blue) < 10:
                rows[y][x] = None
                continue

        rows[y][x] = f"#{red:02X}{green:02X}{blue:02X}"
    return rows


def manual_pixels(logo: LogoSource) -> list[list[str | None]]:
    if logo.pixel_rows is None or logo.pixel_colors is None:
        raise ValueError(f"{logo.property_name} does not define manual pixel rows.")
    rows: list[list[str | None]] = []
    for row in logo.pixel_rows:
        if len(row) != 8:
            raise SystemExit(f"{logo.property_name} pixel row must be exactly 8 columns: {row}")
        rows.append([
            None if cell == "." else logo.pixel_colors[cell]
            for cell in row
        ])
    if len(rows) != 8:
        raise SystemExit(f"{logo.property_name} must define exactly 8 pixel rows.")
    return rows


def swift_pixels(pixels: list[list[str | None]]) -> str:
    rendered_rows = []
    for row in pixels:
        cells = ["nil" if value is None else f'"{value}"' for value in row]
        rendered_rows.append("            [" + ", ".join(cells) + "]")
    return ",\n".join(rendered_rows)


def main() -> None:
    binary = convert_binary()
    blocks = []
    for logo in LOGOS:
        source = find_asset(logo.asset_name)
        if logo.pixel_rows is not None:
            # Some brand marks collapse into unreadable blobs at 8x8. These
            # stencils preserve the bundled asset silhouette on the TC001 grid.
            pixels = manual_pixels(logo)
        else:
            txt = run_convert(binary, source, logo.light_backdrop)
            pixels = parse_pixels(txt, logo.light_backdrop)
        blocks.append(
            f"""    static let {logo.property_name} = PixelClockProviderLogo(
        sourceName: "{logo.source_label}",
        pixels: [
{swift_pixels(pixels)}
        ]
    )"""
        )

    OUTPUT.write_text(
        """// Generated by scripts/generate-pixel-clock-logos.py.
// Do not edit by hand; regenerate after bundled provider logo asset changes.

import Foundation

enum PixelClockProviderLogoAssets {
"""
        + "\n\n".join(blocks)
        + "\n}\n",
        encoding="utf-8",
    )


if __name__ == "__main__":
    main()
