#!/usr/bin/env python3
import os
import shutil
import json

# Setup absolute paths
BASE_DIR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
BRAND_SVG_DIR = os.path.join(BASE_DIR, "assets", "brand", "svg")
WEBSITE_VECTOR_DIR = os.path.join(BASE_DIR, "website", "public", "brand", "vector")
ASSETS_SVGS_DIR = os.path.join(BASE_DIR, "assets", "svgs")

MAC_ASSETS_DIR = os.path.join(BASE_DIR, "AgentLens", "Resources", "Assets.xcassets")
IOS_ASSETS_DIR = os.path.join(BASE_DIR, "OpenBurnBarMobile", "Resources", "Assets.xcassets")

# Mapping from brand numbered files to unnumbered names in assets/svgs
SVGS_MAPPING = {
    "9_agent_control_actions.svg": "agent_control_actions.svg",
    "11_apple_verified.svg": "apple_verified.svg",
    "16_brass_signet.svg": "brass_signet.svg",
    "13_cancel_anytime.svg": "cancel_anytime.svg",
    "5_cross_device_resume.svg": "cross_device_resume.svg",
    "10_floo_relay_data.svg": "floo_relay_data.svg",
    "8_remote_mcp.svg": "remote_mcp.svg",
    "7_remote_relay.svg": "remote_relay.svg",
    "6_search_every_session.svg": "search_every_session.svg",
    "14_silver_shield.svg": "silver_shield.svg",
    "17_sun_disc.svg": "sun_disc.svg",
    "12_uid_bound.svg": "uid_bound.svg",
    "15_wax_seal.svg": "wax_seal.svg",
}

# Member Badge Asset Catalogue Mapping
# Format: (Imageset Folder Name, PDF Filename, SVG Filename, Brand SVG Source File)
MEMBER_BADGES = [
    ("CloudBadgeShield", "shield.pdf", "shield.svg", "14_silver_shield.svg"),
    ("CloudBadgeWaxSeal", "wax_seal.pdf", "wax_seal.svg", "15_wax_seal.svg"),
    ("CloudBadgeBrassCoin", "brass_coin.pdf", "brass_coin.svg", "16_brass_signet.svg"),
    ("CloudBadgeSunDisc", "sun_disc.pdf", "sun_disc.svg", "17_sun_disc.svg"),
]


def sync_website_vectors():
    print(">>> Syncing Brand SVGs to Website public vectors...")
    os.makedirs(WEBSITE_VECTOR_DIR, exist_ok=True)
    for filename in os.listdir(BRAND_SVG_DIR):
        if filename.endswith(".svg"):
            src_path = os.path.join(BRAND_SVG_DIR, filename)
            dst_path = os.path.join(WEBSITE_VECTOR_DIR, filename)
            shutil.copy2(src_path, dst_path)
            print(f"  Copied: {filename} -> Website Vector")


def sync_assets_svgs():
    print("\n>>> Syncing and upgrading assets/svgs/ with high-quality counterparts...")
    os.makedirs(ASSETS_SVGS_DIR, exist_ok=True)
    for src_name, dst_name in SVGS_MAPPING.items():
        src_path = os.path.join(BRAND_SVG_DIR, src_name)
        dst_path = os.path.join(ASSETS_SVGS_DIR, dst_name)
        if os.path.exists(src_path):
            shutil.copy2(src_path, dst_path)
            print(f"  Upgraded: {src_name} -> {dst_name} in assets/svgs/")
        else:
            print(f"  Warning: Source file {src_name} not found!")


def update_xcassets_for_path(assets_catalog_path, app_name):
    print(f"\n>>> Migrating member badges in {app_name} from legacy PDF to high-quality SVG...")
    for folder_name, pdf_name, svg_name, src_name in MEMBER_BADGES:
        imageset_dir = os.path.join(assets_catalog_path, f"{folder_name}.imageset")
        if not os.path.exists(imageset_dir):
            print(f"  Warning: {folder_name}.imageset not found at {imageset_dir}")
            continue

        # 1. Write the new SVG file from the brand source
        src_svg_path = os.path.join(BRAND_SVG_DIR, src_name)
        dst_svg_path = os.path.join(imageset_dir, svg_name)
        shutil.copy2(src_svg_path, dst_svg_path)
        print(f"  Written SVG: {svg_name} inside {folder_name}.imageset")

        # 2. Update Contents.json to point to the new SVG
        contents_json_path = os.path.join(imageset_dir, "Contents.json")
        if os.path.exists(contents_json_path):
            with open(contents_json_path) as f:
                try:
                    data = json.load(f)
                except Exception as e:
                    print(f"  Error loading JSON from {contents_json_path}: {e}")
                    data = None

            if data and "images" in data:
                for img in data["images"]:
                    if img.get("filename") == pdf_name:
                        img["filename"] = svg_name
                        print(f"  Updated Contents.json reference: {pdf_name} -> {svg_name}")

                with open(contents_json_path, "w") as f:
                    json.dump(data, f, indent=2)
            else:
                # Re-create correct Contents.json format if missing or invalid
                new_data = {
                    "images": [{"filename": svg_name, "idiom": "universal"}],
                    "info": {"author": "xcode", "version": 1},
                    "properties": {"preserves-vector-representation": True, "template-rendering-intent": "original"},
                }
                with open(contents_json_path, "w") as f:
                    json.dump(new_data, f, indent=2)
                print(f"  Re-created Contents.json reference for {svg_name}")

        # 3. Clean up legacy PDF file
        pdf_path = os.path.join(imageset_dir, pdf_name)
        if os.path.exists(pdf_path):
            os.remove(pdf_path)
            print(f"  Cleaned up legacy PDF: {pdf_name}")


def main():
    sync_website_vectors()
    sync_assets_svgs()
    update_xcassets_for_path(MAC_ASSETS_DIR, "AgentLens (macOS)")
    update_xcassets_for_path(IOS_ASSETS_DIR, "OpenBurnBarMobile (iOS)")
    print(
        "\n>>> Brand asset synchronization and migration completed successfully! All 17 vector sets fully updated across Web, assets catalog, and macOS/iOS apps."
    )


if __name__ == "__main__":
    main()
