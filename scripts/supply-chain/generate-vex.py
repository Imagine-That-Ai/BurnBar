#!/usr/bin/env python3
"""
generate-vex.py — Emit a minimal OpenVEX document for OpenBurnBar release/PR SBOMs.

Usage:
  scripts/supply-chain/generate-vex.py --sbom PATH --output PATH [--product-version VERSION]
"""

from __future__ import annotations

import argparse
import json
import uuid
from datetime import datetime, timezone
from pathlib import Path


def main() -> int:
    parser = argparse.ArgumentParser(description="Generate OpenVEX sidecar for an SPDX SBOM")
    parser.add_argument("--sbom", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--product-version", default="0.0.0")
    args = parser.parse_args()

    sbom_path = args.sbom
    if not sbom_path.exists():
        raise SystemExit(f"SBOM not found: {sbom_path}")

    sbom = json.loads(sbom_path.read_text(encoding="utf-8"))
    spdx_id = sbom.get("SPDXID", "SPDXRef-DOCUMENT")
    now = datetime.now(timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z")

    vex = {
        "@context": "https://openvex.dev/ns/v0.2.0",
        "@id": f"https://openburnbar.dev/vex/{uuid.uuid4()}",
        "author": "OpenBurnBar Release Engineering",
        "timestamp": now,
        "version": 1,
        "statements": [
            {
                "vulnerability": {
                    "name": "placeholder-no-known-exploitable-in-release-sbom",
                },
                "timestamp": now,
                "products": [
                    {
                        "@id": spdx_id,
                        "subcomponents": [],
                    }
                ],
                "status": "not_affected",
                "status_notes": (
                    f"OpenBurnBar v{args.product_version}: no VEX exceptions filed at generation time. "
                    "Re-run with statement entries when npm/OSV/cargo-deny findings are triaged."
                ),
            }
        ],
    }

    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(vex, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    print(f"Wrote VEX → {args.output}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
