from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]


def test_computer_use_runtime_uses_single_production_daemon_manager() -> None:
    app_source = (ROOT / "AgentLens/App/AgentLensApp.swift").read_text(encoding="utf-8")
    runtime_source = (ROOT / "AgentLens/Services/ComputerUse/ComputerUseRuntimeController.swift").read_text(
        encoding="utf-8"
    )
    recovery_source = (ROOT / "AgentLens/Services/OpenBurnBarStartupRecovery.swift").read_text(encoding="utf-8")

    assert "OpenBurnBarDaemonManager.shared" in app_source
    assert "OpenBurnBarDaemonManager(settingsManager: settings)" not in app_source
    assert "daemonManager: daemonManager" in recovery_source
    assert "try await daemonManager.publishComputerUseCapabilityState(" in runtime_source
    assert "try await OpenBurnBarDaemonManager.shared.publishComputerUseCapabilityState(" not in runtime_source
    assert "ComputerUseBudgetStatusStore.shared" not in runtime_source
    assert "ComputerUseQuotaUsageStore.shared" not in runtime_source
    assert "ComputerUseCloudMeteringService.shared" not in runtime_source
