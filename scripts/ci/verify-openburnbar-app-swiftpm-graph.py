import json
import re
import sys
from pathlib import Path


FIREBASE_REVISION = "42cf1417c51c5e3bfbae5d3ab89b778f8fdc4bb8"


def validate_source_pin(pin: object, identity: str, repository: str) -> dict[str, object]:
    if not isinstance(pin, dict):
        raise ValueError(f"missing {identity} pin")
    if pin.get("kind") != "remoteSourceControl":
        raise ValueError(f"invalid {identity} source-control kind")
    if pin.get("location") not in (repository, f"{repository}.git"):
        raise ValueError(f"invalid {identity} repository location")
    state = pin.get("state")
    if not isinstance(state, dict):
        raise ValueError(f"invalid {identity} state")
    version = state.get("version")
    if not isinstance(version, str) or not re.fullmatch(
        r"[0-9]+\.[0-9]+\.[0-9]+(?:-[0-9A-Za-z.-]+)?(?:\+[0-9A-Za-z.-]+)?", version
    ):
        raise ValueError(f"invalid {identity} version")
    revision = state.get("revision")
    if not isinstance(revision, str) or not re.fullmatch(r"[0-9a-f]{40}", revision):
        raise ValueError(f"invalid {identity} revision")
    return state


def main() -> int:
    if len(sys.argv) != 2:
        print("Usage: verify-openburnbar-app-swiftpm-graph.py <Package.resolved>", file=sys.stderr)
        return 2

    try:
        document = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
        if not isinstance(document, dict) or not isinstance(document.get("pins"), list):
            raise ValueError("expected a SwiftPM lockfile with a pins array")
        pins: dict[str, dict[str, object]] = {}
        for pin in document["pins"]:
            if not isinstance(pin, dict) or not isinstance(pin.get("identity"), str):
                raise ValueError("each pin must have a string identity")
            identity = pin["identity"]
            if not identity or identity != identity.strip():
                raise ValueError("each pin must have a nonempty, trimmed identity")
            if identity in pins:
                raise ValueError(f"duplicate SwiftPM pin: {identity}")
            pins[identity] = pin
        if "grpc-binary" in pins:
            raise ValueError("grpc-binary is forbidden; resolve with FIREBASE_SOURCE_FIRESTORE=1")
        firebase = validate_source_pin(
            pins.get("firebase-ios-sdk"), "firebase-ios-sdk", "https://github.com/firebase/firebase-ios-sdk"
        )
        validate_source_pin(pins.get("grpc-ios"), "grpc-ios", "https://github.com/grpc/grpc-ios")
        if firebase["version"] != "12.19.3":
            raise ValueError("firebase-ios-sdk must resolve exactly to 12.19.3")
        if firebase["revision"] != FIREBASE_REVISION:
            raise ValueError("firebase-ios-sdk revision does not match the verified 12.19.3 tag")
    except (OSError, UnicodeError, ValueError) as error:
        print(f"Invalid OpenBurnBar SwiftPM graph: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
