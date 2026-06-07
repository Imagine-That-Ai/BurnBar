from pathlib import Path

from scripts.ci.check_native_signal_runtime_evidence import validate_native_signal_runtime_evidence


def proof(command: str, artifact_paths: list[str]) -> dict[str, object]:
    return {
        "status": "passed",
        "command": command,
        "artifactPaths": artifact_paths,
        "notes": "Proof-only release evidence; no plaintext, private keys, or user data.",
    }


def swift_evidence() -> dict[str, object]:
    return {
        "schemaVersion": 1,
        "generatedAt": "2026-06-06T00:00:00Z",
        "privacy": "proof_only_no_plaintext_keys_or_user_data",
        "runtime": "swift_signal_runtime",
        "platform": "swift",
        "proofs": {
            "native_build_tests": proof(
                "swift test --package-path OpenBurnBarCore --disable-swift-testing --filter OpenBurnBarSignalCoreTests",
                [
                    "OpenBurnBarCore/Package.swift",
                    "OpenBurnBarCore/Tests/OpenBurnBarSignalCoreTests/SignalPrekeyPublicationTests.swift",
                ],
            ),
            "libsignal_prekey_publication": proof(
                "swift test --package-path OpenBurnBarCore --disable-swift-testing --filter SignalPrekeyPublicationTests",
                [
                    "OpenBurnBarCore/Sources/OpenBurnBarSignalCore/SignalPrekeyPublication.swift",
                    "OpenBurnBarCore/Sources/OpenBurnBarSignalCore/SignalPrekeyPublicationStore.swift",
                    "OpenBurnBarCore/Tests/OpenBurnBarSignalCoreTests/SignalPrekeyPublicationTests.swift",
                ],
            ),
            "secret_state_local_only": proof(
                "swift test --package-path OpenBurnBarCore --disable-swift-testing --filter "
                "SignalPrekeyPublicationTests/testLifecycleDocumentsArePublicOnlyAndMatchRulesContract",
                ["OpenBurnBarCore/Tests/OpenBurnBarSignalCoreTests/SignalPrekeyPublicationTests.swift"],
            ),
            "binding_aad_vectors": proof(
                "swift test --package-path OpenBurnBarCore --disable-swift-testing --filter SignalEnvelopeAADTests",
                [
                    "OpenBurnBarCore/Package.swift",
                    "OpenBurnBarCore/Sources/OpenBurnBarSignalCore/SignalEnvelopeAAD.swift",
                    "OpenBurnBarCore/Tests/OpenBurnBarSignalCoreTests/SignalEnvelopeAADTests.swift",
                    "packages/signal-envelope-contracts/fixtures/binding-aad-vectors.json",
                ],
            ),
        },
    }


def kotlin_evidence() -> dict[str, object]:
    return {
        "schemaVersion": 1,
        "generatedAt": "2026-06-06T00:00:00Z",
        "privacy": "proof_only_no_plaintext_keys_or_user_data",
        "runtime": "kotlin_android_signal_runtime",
        "platform": "kotlin_android",
        "proofs": {
            "native_build_tests": proof(
                "cd android && ./gradlew :app:testDebugUnitTest",
                [
                    "android/gradlew",
                    "android/gradle/wrapper/gradle-wrapper.properties",
                    "android/settings.gradle.kts",
                    "android/build.gradle.kts",
                    "android/app/build.gradle.kts",
                    "android/app/src/test/java/com/openburnbar/data/cloud/AndroidCloudVaultSignalPayloadsTest.kt",
                    "android/app/src/test/java/com/openburnbar/data/cloud/AndroidSignalPrekeyDirectoryTest.kt",
                ],
            ),
            "libsignal_prekey_publication": proof(
                "cd android && ./gradlew :app:testDebugUnitTest --tests '*AndroidSignalPrekeyDirectoryTest'",
                [
                    "android/app/src/main/java/com/openburnbar/data/cloud/AndroidSignalPrekeyDirectory.kt",
                    "android/app/src/test/java/com/openburnbar/data/cloud/AndroidSignalPrekeyDirectoryTest.kt",
                ],
            ),
            "cloudvault_signal_binding": proof(
                "cd android && ./gradlew :app:testDebugUnitTest --tests '*AndroidCloudVaultSignalPayloadsTest'",
                [
                    "android/app/src/main/java/com/openburnbar/data/cloud/AndroidCloudVaultSignalPayloads.kt",
                    "android/app/src/test/java/com/openburnbar/data/cloud/AndroidCloudVaultSignalPayloadsTest.kt",
                ],
            ),
            "binding_aad_vectors": proof(
                "cd android && ./gradlew :app:testDebugUnitTest --tests '*AndroidCloudVaultSignalPayloadsTest'",
                [
                    "android/app/src/test/java/com/openburnbar/data/cloud/AndroidCloudVaultSignalPayloadsTest.kt",
                    "packages/signal-envelope-contracts/fixtures/binding-aad-vectors.json",
                ],
            ),
        },
    }


def test_validates_swift_native_runtime_evidence() -> None:
    assert validate_native_signal_runtime_evidence(swift_evidence(), platform="swift") == []


def test_validates_kotlin_android_native_runtime_evidence() -> None:
    assert validate_native_signal_runtime_evidence(kotlin_evidence(), platform="kotlin_android") == []


def test_rejects_platform_mismatch() -> None:
    errors = validate_native_signal_runtime_evidence(swift_evidence(), platform="kotlin_android")

    assert "platform must be 'kotlin_android', found 'swift'" in errors


def test_rejects_missing_required_native_proof() -> None:
    data = swift_evidence()
    del data["proofs"]["binding_aad_vectors"]  # type: ignore[index]

    assert validate_native_signal_runtime_evidence(data, platform="swift") == [
        "proofs missing required proof(s): binding_aad_vectors"
    ]


def test_rejects_missing_required_artifact_path() -> None:
    data = kotlin_evidence()
    data["proofs"]["cloudvault_signal_binding"]["artifactPaths"] = [  # type: ignore[index]
        "android/app/src/main/java/com/openburnbar/data/cloud/AndroidCloudVaultSignalPayloads.kt",
    ]

    errors = validate_native_signal_runtime_evidence(data, platform="kotlin_android")

    assert (
        "proofs.cloudvault_signal_binding.artifactPaths missing required path(s): "
        "android/app/src/test/java/com/openburnbar/data/cloud/AndroidCloudVaultSignalPayloadsTest.kt"
    ) in errors


def test_rejects_android_runtime_evidence_without_gradle_project_boundary() -> None:
    data = kotlin_evidence()
    data["proofs"]["native_build_tests"]["artifactPaths"] = [  # type: ignore[index]
        "android/gradlew",
        "android/gradle/wrapper/gradle-wrapper.properties",
        "android/build.gradle.kts",
        "android/app/build.gradle.kts",
        "android/app/src/test/java/com/openburnbar/data/cloud/AndroidCloudVaultSignalPayloadsTest.kt",
        "android/app/src/test/java/com/openburnbar/data/cloud/AndroidSignalPrekeyDirectoryTest.kt",
    ]

    errors = validate_native_signal_runtime_evidence(data, platform="kotlin_android")

    assert (
        "proofs.native_build_tests.artifactPaths missing required path group: "
        "one of android/settings.gradle, android/settings.gradle.kts"
    ) in errors


def test_rejects_irrelevant_native_proof_command() -> None:
    data = swift_evidence()
    data["proofs"]["binding_aad_vectors"]["command"] = "echo ok"  # type: ignore[index]

    errors = validate_native_signal_runtime_evidence(data, platform="swift")

    assert (
        "proofs.binding_aad_vectors.command missing required command fragment(s): "
        "swift test, --package-path OpenBurnBarCore, --disable-swift-testing, SignalEnvelopeAADTests"
    ) in errors


def test_rejects_irrelevant_android_proof_command() -> None:
    data = kotlin_evidence()
    data["proofs"]["libsignal_prekey_publication"]["command"] = "echo ok"  # type: ignore[index]

    errors = validate_native_signal_runtime_evidence(data, platform="kotlin_android")

    assert (
        "proofs.libsignal_prekey_publication.command missing required command fragment(s): "
        "./gradlew, :app:testDebugUnitTest, AndroidSignalPrekeyDirectoryTest"
    ) in errors


def test_rejects_embedded_private_or_user_data_fields() -> None:
    data = swift_evidence()
    data["proofs"]["secret_state_local_only"]["privateKeyData"] = "secret"  # type: ignore[index]

    errors = validate_native_signal_runtime_evidence(data, platform="swift")

    assert "proofs.secret_state_local_only.privateKeyData must not be embedded in native runtime proof evidence" in errors
    assert "proofs.secret_state_local_only has unexpected key: privateKeyData" in errors


def test_validates_artifact_paths_exist_when_repo_root_is_supplied(tmp_path: Path) -> None:
    errors = validate_native_signal_runtime_evidence(swift_evidence(), platform="swift", repo_root=tmp_path)

    assert any(
        "path does not exist: OpenBurnBarCore/Sources/OpenBurnBarSignalCore/SignalEnvelopeAAD.swift" in error
        for error in errors
    )
