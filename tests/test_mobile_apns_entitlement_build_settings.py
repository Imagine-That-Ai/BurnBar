import plistlib
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]


def test_mobile_apns_entitlement_build_setting_is_bound_per_configuration():
    entitlements = plistlib.loads(
        (ROOT / "OpenBurnBarMobile/Resources/OpenBurnBarMobile.entitlements").read_bytes()
    )
    project = (ROOT / "project.yml").read_text(encoding="utf-8")
    pbxproj = (ROOT / "OpenBurnBar.xcodeproj/project.pbxproj").read_text(encoding="utf-8")

    assert entitlements["aps-environment"] == "$(APS_ENVIRONMENT)"
    assert "Debug:\n          APS_ENVIRONMENT: development" in project
    assert "Release:\n          APS_ENVIRONMENT: production" in project
    assert "APS_ENVIRONMENT = development;" in pbxproj
    assert "APS_ENVIRONMENT = production;" in pbxproj
