from scripts.ci.check_native_signal_runtime_evidence import validate_native_signal_runtime_evidence


def test_validates_swift_native_runtime_evidence():
    errors = validate_native_signal_runtime_evidence(
        {
            "privacy": "proof_only_no_plaintext_keys_or_user_data",
            "platforms": {
                "swift": {"status": "pass", "command": "swift test"},
                "kotlin": {"status": "pass", "command": "./gradlew test"},
            },
        }
    )
    assert errors == []


def test_validates_kotlin_android_native_runtime_evidence():
    errors = validate_native_signal_runtime_evidence(
        {
            "privacy": "proof_only_no_plaintext_keys_or_user_data",
            "platforms": {
                "swift": {"status": "pass", "command": "swift test"},
                "kotlin": {"status": "fail", "command": "./gradlew test"},
            },
        }
    )
    assert "kotlin runtime evidence must be pass" in errors


def test_rust_core_bridge_gate_requires_rust_evidence():
    errors = validate_native_signal_runtime_evidence(
        {
            "privacy": "proof_only_no_plaintext_keys_or_user_data",
            "platforms": {
                "swift": {"status": "pass", "command": "swift test"},
                "kotlin": {"status": "pass", "command": "./gradlew test"},
            },
        },
        gate="rust_core_bridge",
    )
    assert "missing rust runtime evidence" in errors


def test_rust_core_bridge_gate_accepts_rust_evidence():
    errors = validate_native_signal_runtime_evidence(
        {
            "privacy": "proof_only_no_plaintext_keys_or_user_data",
            "platforms": {
                "rust": {"status": "pass", "command": "cargo test -p openburnbar-libsignal-ffi"},
            },
        },
        gate="rust_core_bridge",
    )
    assert errors == []
