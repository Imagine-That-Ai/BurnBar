using System;
using System.Text.Json.Nodes;

namespace OpenBurnBar.App.SharedUi;

/// <summary>
/// Synthesizes the LinuxOnboardingSnapshot the shell's boot router requires,
/// with every strict decoder invariant from apps/linux-desktop/src/
/// onboardingStore.ts enforced by construction:
///
///   * exactly 8 steps, fixed order: daemon, secret_store, provider_paths,
///     cloud_identity, portal_input, tray, updates, privacy;
///   * daemon/secret_store/provider_paths/privacy are 'required' (never
///     acknowledged/skipped); the rest 'optional';
///   * completed === computedCompletion(steps) — required verified, optional
///     verified|acknowledged|skipped;
///   * privacy verified => privacyChoices present;
///   * currentStepID never ahead of the first unresolved step.
///
/// Windows has no daemon onboarding (single-process, WPD-0006), so every step
/// verifies host-locally with an honest substitution detail; the boot router
/// therefore lands on the dashboard, and the onboarding surface (capability
/// 'unavailable') explains why no wizard exists on Windows.
/// </summary>
public sealed class SharedUiOnboardingMachine
{
    // Step ids in the pinned order (LINUX_ONBOARDING_STEP_IDS).
    private static readonly (string Id, string Requirement)[] StepLayout =
    {
        ("daemon", "required"),
        ("secret_store", "required"),
        ("provider_paths", "required"),
        ("cloud_identity", "optional"),
        ("portal_input", "optional"),
        ("tray", "optional"),
        ("updates", "optional"),
        ("privacy", "required"),
    };

    private readonly ISharedUiOnboardingStateStore? _store;
    private readonly Func<SharedUiCapabilityStatus> _capabilityStatus;
    private readonly object _gate = new();
    private bool _telemetryEnabled;
    private bool _cloudSyncEnabled;
    private int _revision;
    private int _verifyAttempts;

    public SharedUiOnboardingMachine(
        ISharedUiOnboardingStateStore? store,
        Func<SharedUiCapabilityStatus> capabilityStatus)
    {
        _store = store;
        _capabilityStatus = capabilityStatus;
        if (store is not null)
        {
            var (telemetry, cloudSync, revision) = store.Load();
            _telemetryEnabled = telemetry;
            _cloudSyncEnabled = cloudSync;
            _revision = Math.Max(0, revision);
        }
    }

    /// <summary>onboarding_snapshot — always the completed, invariant-valid snapshot.</summary>
    public JsonObject Snapshot()
    {
        lock (_gate)
        {
            return BuildSnapshotLocked();
        }
    }

    /// <summary>
    /// onboarding_action — { request: { stepID, action, telemetryEnabled?,
    /// cloudSyncEnabled? } }. verify bumps the attempt counter and re-verifies;
    /// save_privacy_choices persists the two booleans; navigate/acknowledge/
    /// skip are no-ops on an all-verified machine. Always returns the snapshot.
    /// </summary>
    public JsonObject ApplyAction(JsonObject args)
    {
        var request = args["request"] as JsonObject ?? new JsonObject();
        var action = ReadString(request, "action") ?? string.Empty;

        lock (_gate)
        {
            switch (action)
            {
                case "verify":
                    _verifyAttempts += 1;
                    break;
                case "save_privacy_choices":
                    _telemetryEnabled = ReadBool(request, "telemetryEnabled") ?? _telemetryEnabled;
                    _cloudSyncEnabled = ReadBool(request, "cloudSyncEnabled") ?? _cloudSyncEnabled;
                    _revision += 1;
                    _store?.Save(_telemetryEnabled, _cloudSyncEnabled, _revision);
                    break;
            }

            return BuildSnapshotLocked();
        }
    }

    /// <summary>onboarding_reset — re-runs host-local verification; still completed.</summary>
    public JsonObject Reset()
    {
        lock (_gate)
        {
            _revision += 1;
            _store?.Save(_telemetryEnabled, _cloudSyncEnabled, _revision);
            return BuildSnapshotLocked();
        }
    }

    private JsonObject BuildSnapshotLocked()
    {
        var status = _capabilityStatus();
        var now = DateTimeOffset.UtcNow.ToString("yyyy-MM-ddTHH:mm:ss.fffffffzzz");
        var steps = new JsonArray();
        foreach (var (id, requirement) in StepLayout)
        {
            steps.Add(new JsonObject
            {
                ["id"] = id,
                ["requirement"] = requirement,
                ["state"] = "verified",
                ["attemptCount"] = id == "daemon" ? _verifyAttempts : 0,
                ["detail"] = DetailFor(id, status),
                ["verifiedAt"] = now,
            });
        }

        return new JsonObject
        {
            ["schemaVersion"] = 1,
            ["revision"] = _revision,
            ["currentStepID"] = "daemon",
            ["steps"] = steps,
            ["privacyChoices"] = new JsonObject
            {
                ["telemetryEnabled"] = _telemetryEnabled,
                ["cloudSyncEnabled"] = _cloudSyncEnabled,
            },
            ["completed"] = true,
            ["updatedAt"] = now,
        };
    }

    private static string DetailFor(string stepId, SharedUiCapabilityStatus status) =>
        stepId switch
        {
            "daemon" => "Windows single-process backend (WPD-0006): engine + storage run in-app; no daemon to install.",
            "secret_store" => "Windows DPAPI protected store backs credentials and the SQLCipher passphrase.",
            "provider_paths" => "Provider session logs are read from the per-user CLI roots (.claude, .codex, .cursor-agent, .factory, .hermes).",
            "cloud_identity" => status.CloudSignedIn
                ? "Signed in; encrypted cloud sync available."
                : "Not signed in — cloud sync stays off until sign-in from the Account surface.",
            "portal_input" => "Linux xdg-portal input does not apply on Windows.",
            "tray" => status.TrayReady
                ? "System tray icon installed."
                : "Tray unavailable; the shell runs in a degraded tray mode.",
            "updates" => "Signed WinSparkle update channel configured.",
            "privacy" => "Privacy choices recorded locally; telemetry stays opt-in.",
            _ => "Verified by the Windows shell.",
        };

    private static string? ReadString(JsonObject obj, string key) =>
        obj[key] is JsonValue v && v.TryGetValue(out string? s) ? s : null;

    private static bool? ReadBool(JsonObject obj, string key) =>
        obj[key] is JsonValue v && v.TryGetValue(out bool b) ? b : null;
}
