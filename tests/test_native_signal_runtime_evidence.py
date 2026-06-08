from datetime import UTC, datetime, timedelta

from scripts.ci.check_native_signal_runtime_evidence import validate_native_signal_runtime_evidence


def generated_at_now():
    return datetime.now(UTC).isoformat().replace("+00:00", "Z")


def command_evidence(command: str, assertions: list[str], *, status: str = "pass", exit_code: int = 0):
    return {
        "command": command,
        "status": status,
        "exitCode": exit_code,
        "durationMs": 1,
        "stdoutSha256": "0" * 64,
        "stderrSha256": "0" * 64,
        "assertions": assertions,
    }


SWIFT_ASSERTIONS = [
    "official_libsignal_session_round_trip",
    "persistence_reload_round_trip",
    "replay_or_skipped_key_negative",
    "identity_or_safety_number_change_negative",
    "no_plaintext_keys_or_user_data",
]

KOTLIN_ASSERTIONS = [
    "official_libsignal_session_round_trip",
    "swift_interop_kat_open",
    "replay_or_skipped_key_negative",
    "identity_key_store_negative",
    "no_plaintext_keys_or_user_data",
]

RUST_ASSERTIONS = [
    "official_libsignal_rust_bridge_builds",
    "ffi_contracts_exported",
    "swift_ffi_surface_present",
    "kotlin_jni_surface_present",
    "node_napi_surface_present",
    "no_plaintext_keys_or_user_data",
]


def test_validates_swift_native_runtime_evidence():
    errors = validate_native_signal_runtime_evidence(
        {
            "schemaVersion": 1,
            "generatedAt": generated_at_now(),
            "generatedBy": "tests",
            "privacy": "proof_only_no_plaintext_keys_or_user_data",
            "platforms": {
                "swift": {
                    "commandEvidence": [
                        command_evidence(
                            "swift test --package-path OpenBurnBarCore --filter OBBSignalProtocolStoreSessionTests",
                            SWIFT_ASSERTIONS,
                        )
                    ]
                },
                "kotlin": {
                    "commandEvidence": [
                        command_evidence(
                            "python3 scripts/ci/run_android_signal_runtime_tests.py",
                            KOTLIN_ASSERTIONS,
                        )
                    ]
                },
            },
        }
    )
    assert errors == []


def test_validates_kotlin_android_native_runtime_evidence():
    errors = validate_native_signal_runtime_evidence(
        {
            "schemaVersion": 1,
            "generatedAt": generated_at_now(),
            "generatedBy": "tests",
            "privacy": "proof_only_no_plaintext_keys_or_user_data",
            "platforms": {
                "swift": {
                    "commandEvidence": [
                        command_evidence(
                            "swift test --package-path OpenBurnBarCore --filter OBBSignalProtocolStoreSessionTests",
                            SWIFT_ASSERTIONS,
                        )
                    ]
                },
                "kotlin": {
                    "commandEvidence": [
                        command_evidence(
                            "python3 scripts/ci/run_android_signal_runtime_tests.py",
                            KOTLIN_ASSERTIONS,
                            status="fail",
                            exit_code=1,
                        )
                    ]
                },
            },
        }
    )
    assert "missing passing command evidence for kotlin runtime" in errors


def test_rust_core_bridge_gate_requires_rust_evidence():
    errors = validate_native_signal_runtime_evidence(
        {
            "schemaVersion": 1,
            "generatedAt": generated_at_now(),
            "generatedBy": "tests",
            "privacy": "proof_only_no_plaintext_keys_or_user_data",
            "platforms": {
                "swift": {
                    "commandEvidence": [
                        command_evidence(
                            "swift test --package-path OpenBurnBarCore --filter OBBSignalProtocolStoreSessionTests",
                            SWIFT_ASSERTIONS,
                        )
                    ]
                },
                "kotlin": {
                    "commandEvidence": [
                        command_evidence(
                            "python3 scripts/ci/run_android_signal_runtime_tests.py",
                            KOTLIN_ASSERTIONS,
                        )
                    ]
                },
            },
        },
        gate="rust_core_bridge",
    )
    assert "missing rust runtime evidence" in errors


def test_rust_core_bridge_gate_accepts_rust_evidence():
    errors = validate_native_signal_runtime_evidence(
        {
            "schemaVersion": 1,
            "generatedAt": generated_at_now(),
            "generatedBy": "tests",
            "privacy": "proof_only_no_plaintext_keys_or_user_data",
            "platforms": {
                "rust": {
                    "commandEvidence": [
                        command_evidence("cargo test -p openburnbar-libsignal-ffi", RUST_ASSERTIONS)
                    ],
                },
            },
        },
        gate="rust_core_bridge",
    )
    assert errors == []


def test_rust_core_bridge_rejects_self_report_without_assertions():
    errors = validate_native_signal_runtime_evidence(
        {
            "schemaVersion": 1,
            "generatedAt": generated_at_now(),
            "generatedBy": "tests",
            "privacy": "proof_only_no_plaintext_keys_or_user_data",
            "platforms": {
                "rust": {
                    "commandEvidence": [
                        command_evidence("cargo test -p openburnbar-libsignal-ffi", [])
                    ]
                },
            },
        },
        gate="rust_core_bridge",
    )
    assert any("rust runtime evidence is missing assertions" in error for error in errors)
    assert any("ffi_contracts_exported" in error for error in errors)


def test_kotlin_gate_requires_dedicated_android_signal_runtime_harness():
    errors = validate_native_signal_runtime_evidence(
        {
            "schemaVersion": 1,
            "generatedAt": generated_at_now(),
            "generatedBy": "tests",
            "privacy": "proof_only_no_plaintext_keys_or_user_data",
            "platforms": {
                "kotlin": {
                    "commandEvidence": [
                        command_evidence(
                            "./gradlew :app:testDebugUnitTest --tests *AndroidSignal*",
                            KOTLIN_ASSERTIONS,
                        )
                    ]
                },
            },
        },
        gate="kotlin_round_trips",
    )
    assert any("approved runtime command" in error for error in errors)
    assert any("scripts/ci/run_android_signal_runtime_tests.py" in error for error in errors)


def test_native_evidence_rejects_raw_key_or_user_data_fields():
    errors = validate_native_signal_runtime_evidence(
        {
            "schemaVersion": 1,
            "generatedAt": generated_at_now(),
            "generatedBy": "tests",
            "privacy": "proof_only_no_plaintext_keys_or_user_data",
            "platforms": {
                "rust": {
                    "commandEvidence": [
                        command_evidence("cargo test -p openburnbar-libsignal-ffi", RUST_ASSERTIONS)
                    ],
                    "privateKey": "not allowed",
                },
            },
        },
        gate="rust_core_bridge",
    )
    assert any("must not contain raw user data or key material fields" in error for error in errors)


def test_native_evidence_rejects_stale_packets():
    errors = validate_native_signal_runtime_evidence(
        {
            "schemaVersion": 1,
            "generatedAt": (datetime.now(UTC) - timedelta(days=2)).isoformat().replace("+00:00", "Z"),
            "generatedBy": "tests",
            "privacy": "proof_only_no_plaintext_keys_or_user_data",
            "platforms": {
                "rust": {
                    "commandEvidence": [
                        command_evidence("cargo test -p openburnbar-libsignal-ffi", RUST_ASSERTIONS)
                    ],
                },
            },
        },
        gate="rust_core_bridge",
    )
    assert "generatedAt must be within the last 24 hours" in errors


def test_native_evidence_rejects_self_reported_platform_status_without_command_evidence():
    errors = validate_native_signal_runtime_evidence(
        {
            "schemaVersion": 1,
            "generatedAt": generated_at_now(),
            "generatedBy": "tests",
            "privacy": "proof_only_no_plaintext_keys_or_user_data",
            "platforms": {
                "rust": {
                    "status": "pass",
                    "command": "echo forged-rust-proof",
                    "assertions": RUST_ASSERTIONS,
                },
            },
        },
        gate="rust_core_bridge",
    )

    assert "rust runtime evidence is missing commandEvidence" in errors
    assert "missing passing command evidence for rust runtime" in errors


def test_native_evidence_rejects_echo_command_with_assertion_strings():
    errors = validate_native_signal_runtime_evidence(
        {
            "schemaVersion": 1,
            "generatedAt": generated_at_now(),
            "generatedBy": "tests",
            "privacy": "proof_only_no_plaintext_keys_or_user_data",
            "platforms": {
                "rust": {
                    "commandEvidence": [
                        command_evidence("echo forged-rust-proof", RUST_ASSERTIONS),
                    ]
                },
            },
        },
        gate="rust_core_bridge",
    )

    assert "missing passing command evidence for rust approved runtime command: cargo test" in errors
