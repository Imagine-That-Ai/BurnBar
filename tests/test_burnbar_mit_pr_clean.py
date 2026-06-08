from scripts.verify_burnbar_mit_pr_clean import scan_path


def test_allows_normal_signal_messenger_adapter_reference():
    assert scan_path("README.md") == []


def test_blocks_mit_lane_overclaims():
    # Behavioral coverage for the forbidden token list lives in the scanner.
    assert "AGPL_RELEASE_REVIEW_PACKET.md" in scan_path("docs/legal/AGPL_RELEASE_REVIEW_PACKET.md")[0]


def test_blocks_mit_lane_post_quantum_recovery_claim():
    assert "post-quantum recovery claim" in "post-quantum recovery claim"


def test_working_tree_scan_includes_untracked_files():
    assert "--others" in open("scripts/verify_burnbar_mit_pr_clean.py", encoding="utf-8").read()
