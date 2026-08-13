#!/usr/bin/env python3
"""Generate the BurnBar settings-token SVG family.

These icons sit in the 28pt settings sidebar tiles. They must stay
readable at that size: one silhouette, thick shapes, no hairlines,
ember-to-gold fills on a cream plate.
"""

from __future__ import annotations

import json
import math
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
MAC_ASSETS = ROOT / "AgentLens/Resources/Assets.xcassets"
MOBILE_ASSETS = ROOT / "OpenBurnBarMobile/Resources/Assets.xcassets"

CONTENTS = {
    "images": [{"filename": None, "idiom": "universal"}],
    "info": {"author": "xcode", "version": 1},
    "properties": {
        "preserves-vector-representation": True,
        "template-rendering-intent": "original",
    },
}


def defs(name: str) -> str:
    return f"""  <defs>
    <linearGradient id="{name}-plate" x1="18" y1="6" x2="112" y2="122" gradientUnits="userSpaceOnUse">
      <stop stop-color="#FFFBF4" offset="0"/>
      <stop stop-color="#F6E2C8" offset="1"/>
    </linearGradient>
    <linearGradient id="{name}-flame" x1="64" y1="18" x2="64" y2="112" gradientUnits="userSpaceOnUse">
      <stop stop-color="#FFE27A" offset="0"/>
      <stop stop-color="#FEA41C" offset=".46"/>
      <stop stop-color="#E31B24" offset="1"/>
    </linearGradient>
    <linearGradient id="{name}-gold" x1="36" y1="16" x2="100" y2="112" gradientUnits="userSpaceOnUse">
      <stop stop-color="#FFE9A0" offset="0"/>
      <stop stop-color="#F4831F" offset="1"/>
    </linearGradient>
    <linearGradient id="{name}-ember" x1="28" y1="20" x2="104" y2="112" gradientUnits="userSpaceOnUse">
      <stop stop-color="#F67A28" offset="0"/>
      <stop stop-color="#C41422" offset="1"/>
    </linearGradient>
    <linearGradient id="{name}-deep" x1="30" y1="24" x2="102" y2="114" gradientUnits="userSpaceOnUse">
      <stop stop-color="#E74C16" offset="0"/>
      <stop stop-color="#9E1020" offset="1"/>
    </linearGradient>
    <radialGradient id="{name}-glow" cx="64" cy="40" r="70" gradientUnits="userSpaceOnUse">
      <stop stop-color="#FFFFFF" stop-opacity=".55" offset="0"/>
      <stop stop-color="#FFFFFF" stop-opacity="0" offset="1"/>
    </radialGradient>
  </defs>
  <rect width="128" height="128" rx="32" fill="url(#{name}-plate)"/>
  <rect x="4" y="4" width="120" height="120" rx="28" fill="url(#{name}-glow)"/>"""


def wrap(name: str, body: str) -> str:
    return (
        f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 128 128">\n'
        f"{defs(name)}\n"
        f"{body}\n"
        f"</svg>\n"
    )


def flame(name: str, cx: float, cy: float, w: float, h: float) -> str:
    return (
        f'  <path fill="url(#{name}-gold)" d="'
        f"M{cx:.1f},{cy - h / 2:.1f} "
        f"C{cx + w * 0.42:.1f},{cy - h * 0.18:.1f} {cx + w * 0.48:.1f},{cy + h * 0.12:.1f} {cx:.1f},{cy + h / 2:.1f} "
        f"C{cx - w * 0.48:.1f},{cy + h * 0.12:.1f} {cx - w * 0.42:.1f},{cy - h * 0.18:.1f} {cx:.1f},{cy - h / 2:.1f}Z"
        f'"/>'
    )


def gear_path(cx: float, cy: float, teeth: int, inner: float, outer: float) -> str:
    steps = teeth * 2
    pts: list[str] = []
    for i in range(steps):
        ang = -math.pi / 2 + (i / steps) * math.tau
        r = outer if i % 2 == 0 else inner
        # flatten each tooth with two points around the same radius
        spread = 0.18 if i % 2 == 0 else 0.28
        a0 = ang - (math.pi / teeth) * spread
        a1 = ang + (math.pi / teeth) * spread
        pts.append(f"{cx + r * math.cos(a0):.2f},{cy + r * math.sin(a0):.2f}")
        pts.append(f"{cx + r * math.cos(a1):.2f},{cy + r * math.sin(a1):.2f}")
    return "M" + " L".join(pts) + "Z"


ICONS: dict[str, str] = {}

# Home — hearth house with BurnBar bar-windows and a chimney flame
ICONS["SettingsTokenHome"] = wrap(
    "home",
    f"""  <path fill="url(#home-ember)" d="M34 58h60v46c0 4-3 8-8 8H42c-5 0-8-4-8-8V58Z"/>
  <path fill="url(#home-gold)" d="M20 64 64 24l44 40h-14L64 38 34 64H20Z"/>
  <rect x="84" y="34" width="12" height="20" rx="2" fill="url(#home-deep)"/>
{flame("home", 90, 26, 16, 22)}
  <rect x="56" y="82" width="16" height="30" rx="3" fill="#FFF6E4"/>
  <rect x="40" y="68" width="8" height="16" rx="2" fill="url(#home-gold)"/>
  <rect x="80" y="62" width="8" height="22" rx="2" fill="url(#home-gold)"/>""",
)

# Agents — robot head, cream faceplate, antenna flame
ICONS["SettingsTokenAgents"] = wrap(
    "agents",
    f"""  <path fill="url(#agents-ember)" d="M30 96c0-10 10-16 22-16h24c12 0 22 6 22 16v12H30V96Z"/>
  <rect x="36" y="32" width="56" height="54" rx="16" fill="url(#agents-flame)"/>
  <rect x="44" y="42" width="40" height="30" rx="10" fill="#FFF6E4"/>
  <circle cx="56" cy="56" r="5.5" fill="url(#agents-ember)"/>
  <circle cx="72" cy="56" r="5.5" fill="url(#agents-ember)"/>
  <rect x="61" y="18" width="6" height="16" rx="3" fill="url(#agents-deep)"/>
{flame("agents", 64, 14, 16, 18)}""",
)

# Model Proxy — hub and three routed nodes
ICONS["SettingsTokenModelProxy"] = wrap(
    "proxy",
    """  <path stroke="url(#proxy-ember)" stroke-width="10" stroke-linecap="round" fill="none" d="M64 50V34"/>
  <path stroke="url(#proxy-ember)" stroke-width="10" stroke-linecap="round" fill="none" d="M76 74 96 88"/>
  <path stroke="url(#proxy-ember)" stroke-width="10" stroke-linecap="round" fill="none" d="M52 74 32 88"/>
  <circle cx="64" cy="64" r="20" fill="url(#proxy-flame)"/>
  <circle cx="64" cy="64" r="8" fill="#FFF6E4"/>
  <circle cx="64" cy="26" r="12" fill="url(#proxy-gold)"/>
  <circle cx="100" cy="92" r="12" fill="url(#proxy-gold)"/>
  <circle cx="28" cy="92" r="12" fill="url(#proxy-gold)"/>""",
)

# General — gear with flame hub
ICONS["SettingsTokenGeneral"] = wrap(
    "general",
    f"""  <path fill="url(#general-flame)" d="{gear_path(64, 66, 8, 34, 46)}"/>
  <circle cx="64" cy="66" r="16" fill="#FFF6E4"/>
{flame("general", 64, 66, 16, 22)}""",
)

# Account — person with flame hair
ICONS["SettingsTokenAccount"] = wrap(
    "account",
    f"""  <ellipse cx="64" cy="108" rx="34" ry="20" fill="url(#account-ember)"/>
  <circle cx="64" cy="54" r="24" fill="url(#account-flame)"/>
{flame("account", 80, 30, 18, 24)}""",
)

# Cloud — sun-flame rising behind a cloud
ICONS["SettingsTokenCloud"] = wrap(
    "cloud",
    f"""{flame("cloud", 86, 36, 28, 36)}
  <path fill="url(#cloud-ember)" d="M38 84c-12 0-18-10-16-20 2-8 10-12 18-10 3-14 20-22 32-14 8-8 24-6 28 6 12-2 22 8 20 18-2 12-12 18-24 16H38Z"/>
  <path fill="#FFF6E4" d="M42 78c-8 0-12-6-11-12 1-5 7-8 12-6 2-9 14-14 22-9 5-5 16-4 19 4 8-1 15 5 14 11-1 8-8 12-16 11H42Z"/>""",
)

# Devices & Sync — laptop + phone + ember arc
ICONS["SettingsTokenDevices"] = wrap(
    "devices",
    """  <rect x="20" y="36" width="64" height="46" rx="6" fill="url(#devices-flame)"/>
  <rect x="26" y="42" width="52" height="32" rx="3" fill="#FFF6E4"/>
  <path fill="url(#devices-deep)" d="M16 86h72c4 0 6 4 4 7H14c-2-3 0-7 2-7Z"/>
  <rect x="84" y="52" width="28" height="44" rx="6" fill="url(#devices-ember)"/>
  <rect x="89" y="58" width="18" height="28" rx="2" fill="#FFF6E4"/>
  <rect x="95" y="89" width="6" height="3" rx="1.5" fill="#FFE27A"/>
  <path fill="none" stroke="url(#devices-gold)" stroke-width="5" stroke-linecap="round" d="M78 28c12 2 22 10 26 22"/>""",
)

# Alerts — bell with flame clapper
ICONS["SettingsTokenAlerts"] = wrap(
    "alerts",
    f"""  <path fill="url(#alerts-flame)" d="M40 60c0-16 10-30 24-30s24 14 24 30c0 14 8 22 8 22H32s8-8 8-22Z"/>
  <path fill="url(#alerts-deep)" d="M36 84h56c-4 8-16 14-28 14S40 92 36 84Z"/>
  <rect x="60" y="26" width="8" height="10" rx="4" fill="url(#alerts-gold)"/>
{flame("alerts", 64, 100, 14, 16)}""",
)

# Notifications — tray / chat bubble with ember spark
ICONS["SettingsTokenNotifications"] = wrap(
    "notes",
    f"""  <path fill="url(#notes-flame)" d="M28 36h72c6 0 10 4 10 10v36c0 6-4 10-10 10H58l-16 16v-16H28c-6 0-10-4-10-10V46c0-6 4-10 10-10Z"/>
  <rect x="40" y="52" width="40" height="7" rx="3.5" fill="#FFF6E4"/>
  <rect x="40" y="66" width="26" height="7" rx="3.5" fill="#FFF6E4"/>
{flame("notes", 96, 32, 18, 22)}""",
)

# Engine Room — engine block with pistons and exhaust flame
ICONS["SettingsTokenEngineRoom"] = wrap(
    "engine",
    f"""  <rect x="32" y="26" width="24" height="36" rx="8" fill="url(#engine-ember)"/>
  <rect x="60" y="20" width="24" height="42" rx="8" fill="url(#engine-ember)"/>
  <rect x="18" y="54" width="82" height="50" rx="16" fill="url(#engine-flame)"/>
  <rect x="30" y="68" width="16" height="14" rx="4" fill="#FFF6E4"/>
  <rect x="52" y="68" width="16" height="14" rx="4" fill="#FFF6E4"/>
  <rect x="74" y="68" width="16" height="14" rx="4" fill="#FFF6E4"/>
{flame("engine", 108, 56, 18, 26)}""",
)

# Updates — incoming ember download
ICONS["SettingsTokenUpdates"] = wrap(
    "updates",
    """  <circle cx="64" cy="66" r="38" fill="url(#updates-flame)"/>
  <circle cx="64" cy="66" r="24" fill="#FFF6E4"/>
  <path fill="url(#updates-ember)" d="M64 46v28"/>
  <path fill="url(#updates-ember)" d="M64 80 48 62h32L64 80Z"/>
  <rect x="60" y="44" width="8" height="26" rx="4" fill="url(#updates-ember)"/>
  <path fill="url(#updates-ember)" d="M46 66l18 20 18-20H46Z"/>""",
)

# Data & Privacy — shield + lock
ICONS["SettingsTokenData"] = wrap(
    "data",
    """  <path fill="url(#data-flame)" d="M64 20 96 32v30c0 22-14 36-32 44-18-8-32-22-32-44V32L64 20Z"/>
  <path fill="#FFF6E4" d="M64 32 86 40v22c0 16-10 26-22 32-12-6-22-16-22-32V40L64 32Z"/>
  <path fill="url(#data-ember)" d="M56 66v-8c0-5 3-9 8-9s8 4 8 9v8h4c2 0 4 2 4 4v12c0 2-2 4-4 4H52c-2 0-4-2-4-4V70c0-2 2-4 4-4h4Zm6 0h4v-8c0-2-1-4-2-4s-2 2-2 4v8Z"/>""",
)

# Text Expansion — snippet card bursting into an ember spark
ICONS["SettingsTokenTextExpansion"] = wrap(
    "text",
    f"""  <rect x="20" y="32" width="58" height="64" rx="12" fill="url(#text-flame)"/>
  <rect x="30" y="46" width="38" height="8" rx="4" fill="#FFF6E4"/>
  <rect x="30" y="60" width="30" height="8" rx="4" fill="#FFF6E4"/>
  <rect x="30" y="74" width="20" height="8" rx="4" fill="#FFF6E4"/>
{flame("text", 98, 56, 20, 28)}
  <path fill="none" stroke="url(#text-gold)" stroke-width="6" stroke-linecap="round" d="M86 40l12-12"/>
  <path fill="none" stroke="url(#text-gold)" stroke-width="6" stroke-linecap="round" d="M102 66h14"/>
  <path fill="none" stroke="url(#text-gold)" stroke-width="6" stroke-linecap="round" d="M86 90l12 12"/>""",
)

# Media & Sharing — shared play window (screen in front of a second frame)
ICONS["SettingsTokenMedia"] = wrap(
    "media",
    """  <rect x="36" y="44" width="70" height="52" rx="12" fill="url(#media-deep)"/>
  <rect x="20" y="30" width="74" height="58" rx="12" fill="url(#media-flame)"/>
  <path fill="#FFF6E4" d="M46 46v26l24-13-24-13Z"/>""",
)

# Computer Use — Mac window with a classic ember cursor
ICONS["SettingsTokenComputerUse"] = wrap(
    "cu",
    f"""  <rect x="18" y="24" width="72" height="54" rx="10" fill="url(#cu-ember)"/>
  <rect x="24" y="36" width="60" height="36" rx="4" fill="#FFF6E4"/>
  <path fill="url(#cu-flame)" d="M54 50 54 108 70 90 80 116 92 110 82 84 104 84Z"/>
{flame("cu", 100, 34, 16, 20)}""",
)

# Pets — bean paw pad + four toe pads
ICONS["SettingsTokenPets"] = wrap(
    "pets",
    """  <ellipse cx="36" cy="48" rx="11" ry="14" fill="url(#pets-ember)"/>
  <ellipse cx="52" cy="34" rx="12" ry="15" fill="url(#pets-ember)"/>
  <ellipse cx="76" cy="34" rx="12" ry="15" fill="url(#pets-ember)"/>
  <ellipse cx="92" cy="48" rx="11" ry="14" fill="url(#pets-ember)"/>
  <path fill="url(#pets-flame)" d="M38 68c0-12 11-20 26-20s26 8 26 20-11 36-26 36-26-24-26-36Z"/>
  <ellipse cx="56" cy="72" rx="8" ry="5" fill="#FFE9A0" fill-opacity=".45"/>""",
)

# AI Inbox — tray with standing ember letter
ICONS["SettingsTokenAIInbox"] = wrap(
    "inbox",
    f"""  <path fill="url(#inbox-ember)" d="M22 70h84l-8 32H30L22 70Z"/>
  <path fill="url(#inbox-deep)" d="M22 70 36 52h56l14 18H22Z"/>
  <rect x="44" y="28" width="40" height="36" rx="4" fill="url(#inbox-flame)"/>
  <path fill="#FFF6E4" d="M48 32h32v8L64 50 48 40v-8Z"/>
{flame("inbox", 64, 24, 14, 16)}""",
)


def write_imageset(catalog: Path, name: str, svg: str) -> None:
    folder = catalog / f"{name}.imageset"
    folder.mkdir(parents=True, exist_ok=True)
    svg_name = f"{name}.svg"
    (folder / svg_name).write_text(svg, encoding="utf-8")
    payload = json.loads(json.dumps(CONTENTS))
    payload["images"][0]["filename"] = svg_name
    (folder / "Contents.json").write_text(json.dumps(payload, indent=2) + "\n", encoding="utf-8")


def main() -> None:
    for catalog in (MAC_ASSETS, MOBILE_ASSETS):
        for name, svg in ICONS.items():
            write_imageset(catalog, name, svg)
    print(f"wrote {len(ICONS)} tokens to Mac and mobile catalogs")
    for name in ICONS:
        print(f"  {name}")


if __name__ == "__main__":
    main()
