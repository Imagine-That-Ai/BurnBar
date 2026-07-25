using System;
using System.Collections.Generic;
using System.Linq;
using System.Text.Json.Nodes;
using Xunit;

namespace OpenBurnBar.App.SharedUi.Tests;

/// <summary>
/// Strict-decoder contract tests: the synthesized onboarding snapshot, the
/// subscription responses, and the runtime-capability manifest must satisfy
/// the EXACT invariants the frontend throws on (onboardingStore.ts,
/// decodeDaemonSubscriptionResponse, decodeRuntimeCapabilityManifest). Each
/// test re-implements the frontend check in miniature — a drift here fails
/// the build before the shell ever renders a boundary panel.
/// </summary>
public sealed class SharedUiContractTests
{
    // ── onboarding (decodeLinuxOnboardingSnapshot invariants) ────────────

    private static readonly (string Id, string Requirement)[] OnboardingLayout =
    {
        ("daemon", "required"), ("secret_store", "required"), ("provider_paths", "required"),
        ("cloud_identity", "optional"), ("portal_input", "optional"), ("tray", "optional"),
        ("updates", "optional"), ("privacy", "required"),
    };

    [Fact]
    public void OnboardingSnapshotSatisfiesEveryDecoderInvariant()
    {
        var machine = new SharedUiOnboardingMachine(store: null, () => new SharedUiCapabilityStatus());
        var snapshot = machine.Snapshot();

        Assert.Equal(1, snapshot["schemaVersion"]!.GetValue<int>());
        Assert.True(snapshot["revision"]!.GetValue<int>() >= 0);
        Assert.NotEmpty(snapshot["updatedAt"]!.GetValue<string>());
        Assert.True(snapshot["completed"]!.GetValue<bool>());

        var steps = snapshot["steps"]!.AsArray();
        Assert.Equal(OnboardingLayout.Length, steps.Count);
        var terminalStates = new HashSet<string> { "verified", "acknowledged", "skipped" };
        for (int i = 0; i < OnboardingLayout.Length; i += 1)
        {
            var (id, requirement) = OnboardingLayout[i];
            var step = steps[i]!;
            Assert.Equal(id, step["id"]!.GetValue<string>());
            Assert.Equal(requirement, step["requirement"]!.GetValue<string>());
            var state = step["state"]!.GetValue<string>();
            Assert.Contains(state, new[] { "pending", "blocked", "verified", "acknowledged", "skipped" });
            if (requirement == "required")
            {
                Assert.DoesNotContain(state, new[] { "acknowledged", "skipped" });
                Assert.Equal("verified", state); // completed:true demands it
            }
            else
            {
                Assert.Contains(state, terminalStates);
            }

            Assert.True(step["attemptCount"]!.GetValue<int>() >= 0);
        }

        // privacy verified ⇒ privacyChoices present with two booleans.
        var choices = snapshot["privacyChoices"]!;
        Assert.False(choices["telemetryEnabled"]!.GetValue<bool>());
        Assert.False(choices["cloudSyncEnabled"]!.GetValue<bool>());

        // currentStepID valid + never ahead of the first unresolved step.
        Assert.Contains(snapshot["currentStepID"]!.GetValue<string>(), OnboardingLayout.Select(s => s.Id));
    }

    [Fact]
    public void OnboardingPrivacyActionPersistsAndBumpsRevision()
    {
        var store = new FakeOnboardingStore();
        var machine = new SharedUiOnboardingMachine(store, () => new SharedUiCapabilityStatus());
        var updated = machine.ApplyAction(new JsonObject
        {
            ["request"] = new JsonObject
            {
                ["stepID"] = "privacy",
                ["action"] = "save_privacy_choices",
                ["telemetryEnabled"] = true,
                ["cloudSyncEnabled"] = true,
            },
        });

        Assert.True(updated["privacyChoices"]!["telemetryEnabled"]!.GetValue<bool>());
        Assert.True(updated["privacyChoices"]!["cloudSyncEnabled"]!.GetValue<bool>());
        Assert.Equal(1, updated["revision"]!.GetValue<int>());
        Assert.Equal((true, true, 1), (store.Telemetry, store.CloudSync, store.Revision));

        // Completion invariants still hold after the mutation.
        Assert.True(updated["completed"]!.GetValue<bool>());
    }

    [Fact]
    public void OnboardingResetStaysCompleted()
    {
        var machine = new SharedUiOnboardingMachine(store: null, () => new SharedUiCapabilityStatus());
        var snapshot = machine.Reset();
        Assert.True(snapshot["completed"]!.GetValue<bool>());
        Assert.Equal(1, snapshot["revision"]!.GetValue<int>());
    }

    // ── subscriptions (decodeDaemonSubscriptionResponse invariants) ──────

    [Fact]
    public void SubscriptionStartSatisfiesTheStrictDecoder()
    {
        var hub = new SharedUiSubscriptionHub();
        var response = hub.Start(new JsonObject
        {
            ["request"] = new JsonObject { ["topic"] = "data", ["client_id"] = "windows-shell" },
        });

        AssertSubscriptionResponse(response, expectFirstSnapshot: true);
        Assert.Equal("data", response["topic"]!.GetValue<string>());
        Assert.Equal(response["seq"]!.GetValue<long>().ToString(), response["cursor"]!.GetValue<string>());
        Assert.True(response["degraded_fallback"]!.GetValue<bool>());
    }

    [Fact]
    public void SubscriptionResumeEchoesIdAndIncreasesSeq()
    {
        var hub = new SharedUiSubscriptionHub();
        var start = hub.Start(new JsonObject { ["request"] = new JsonObject { ["topic"] = "data" } });
        var id = start["subscription_id"]!.GetValue<string>();
        var firstSeq = start["seq"]!.GetValue<long>();

        var resume = hub.Resume(new JsonObject
        {
            ["request"] = new JsonObject
            {
                ["subscription_id"] = id,
                ["topic"] = "data",
                ["after_seq"] = firstSeq,
            },
        });

        Assert.Equal(id, resume["subscription_id"]!.GetValue<string>());
        Assert.True(resume["seq"]!.GetValue<long>() > firstSeq);
        Assert.False(resume["first_snapshot"]!.GetValue<bool>());
        Assert.False(resume["terminal_state_delivered"]!.GetValue<bool>());
        Assert.Empty(resume["events"]!.AsArray());

        var stop = hub.Stop(new JsonObject { ["request"] = new JsonObject { ["subscription_id"] = id } });
        Assert.Equal(id, stop["subscription_id"]!.GetValue<string>());
        Assert.True(stop["stopped"]!.GetValue<bool>());
        Assert.True(stop["last_seq"]!.GetValue<long>() >= 0);
    }

    [Fact]
    public void SubscriptionRejectsUnsupportedTopic()
    {
        var hub = new SharedUiSubscriptionHub();
        var ex = Assert.Throws<SharedUiCommandException>(() =>
            hub.Start(new JsonObject { ["request"] = new JsonObject { ["topic"] = "nope" } }));
        Assert.Equal("subscription.topic is unsupported.", ex.Message);
    }

    private static void AssertSubscriptionResponse(JsonObject response, bool expectFirstSnapshot)
    {
        // The exact required snake_case keys + types (decodeDaemonSubscriptionResponse).
        Assert.NotEmpty(response["subscription_id"]!.GetValue<string>());
        Assert.Contains(response["topic"]!.GetValue<string>(), new[] { "data", "health", "run" });
        Assert.True(response["seq"]!.GetValue<long>() >= 0);
        Assert.NotEmpty(response["cursor"]!.GetValue<string>());
        Assert.Equal(expectFirstSnapshot, response["first_snapshot"]!.GetValue<bool>());
        Assert.NotNull(response["events"]!.AsArray());
        Assert.True(response["degraded_fallback"]!.GetValue<bool>());
        Assert.NotEmpty(response["backpressure"]!.GetValue<string>());
        Assert.False(response["disconnect_detected"]!.GetValue<bool>());
        Assert.False(response["recovered_after_restart"]!.GetValue<bool>());
        Assert.False(response["terminal_state_delivered"]!.GetValue<bool>());
    }

    // ── runtime capabilities (decodeRuntimeCapabilityManifest invariants) ─

    private static readonly string[] RequiredCapabilityIds =
    {
        "usage.read", "database.read", "providers.configure", "projects.read",
        "missions.manage", "sessions.read", "chat.gateway", "memory.review",
        "computer-use.browser", "computer-use.system", "media.mercury",
        "smarthub.control", "settings.read", "account.read", "updates.check",
        "updates.install", "support.export", "onboarding.repair", "pet.overlay",
        "text-expansion.in-app", "text-expansion.system", "secrets.secret-service",
        "secrets.kwallet", "portal.desktop", "native.tray", "native.notifications",
        "native.external-billing",
    };

    [Fact]
    public void ManifestSatisfiesTheStrictDecoder()
    {
        var manifest = SharedUiRuntimeCapabilities.BuildManifest(
            "1.2.3",
            new SharedUiCapabilityStatus { StorageReady = true, SessionLogsReady = true, GatewayRunning = true });

        Assert.Equal(1, manifest["schemaVersion"]!.GetValue<int>());
        Assert.NotEmpty(manifest["catalogVersion"]!.GetValue<string>());
        Assert.Equal("1.2.3", manifest["shellVersion"]!.GetValue<string>());

        var capabilities = manifest["capabilities"]!.AsArray();
        Assert.Equal(RequiredCapabilityIds.Length, capabilities.Count);

        var domains = new HashSet<string> { "product", "platform", "security", "delivery" };
        var states = new HashSet<string> { "available", "degraded", "unavailable", "blocked" };
        var seen = new HashSet<string>(StringComparer.Ordinal);
        foreach (var node in capabilities)
        {
            var entry = node!;
            var id = entry["id"]!.GetValue<string>();
            Assert.True(seen.Add(id), $"duplicate capability id {id}");
            Assert.Contains(id, RequiredCapabilityIds);
            Assert.Contains(entry["domain"]!.GetValue<string>(), domains);
            Assert.Contains(entry["state"]!.GetValue<string>(), states);
            Assert.NotEmpty(entry["reason"]!.GetValue<string>());
            Assert.NotEmpty(entry["source"]!.GetValue<string>());
            var substitute = entry["substitute"];
            Assert.True(substitute is null || !string.IsNullOrWhiteSpace(substitute.GetValue<string>()));
        }

        foreach (var id in RequiredCapabilityIds)
        {
            Assert.Contains(id, seen);
        }
    }

    [Fact]
    public void ManifestReflectsProbeStatesHonestly()
    {
        var healthy = SharedUiRuntimeCapabilities.BuildManifest(
            "1.0.0",
            new SharedUiCapabilityStatus { StorageReady = true, SessionLogsReady = true, GatewayRunning = true });
        Assert.Equal("available", StateOf(healthy, "usage.read"));
        Assert.Equal("available", StateOf(healthy, "sessions.read"));
        // chat.gateway stays UNAVAILABLE even with the gateway up. "degraded"
        // would not gate the surface — capabilityBlocksSurface() blocks only on
        // "unavailable"/"blocked" — and a mounted Chat route immediately calls
        // chatThreadList, which Windows does not serve. Flip this to available
        // only once chat_thread_list / chat_thread_get / chat_message_append are
        // backed by the dispatcher.
        Assert.Equal("unavailable", StateOf(healthy, "chat.gateway"));
        Assert.False(string.IsNullOrWhiteSpace(SubstituteOf(healthy, "chat.gateway")));

        var degraded = SharedUiRuntimeCapabilities.BuildManifest(
            "1.0.0",
            new SharedUiCapabilityStatus { StorageReady = false, SessionLogsReady = false, GatewayRunning = false });
        Assert.Equal("unavailable", StateOf(degraded, "usage.read"));
        Assert.Equal("unavailable", StateOf(degraded, "sessions.read"));
        Assert.Equal("unavailable", StateOf(degraded, "chat.gateway"));
    }

    private static string StateOf(JsonObject manifest, string id) =>
        manifest["capabilities"]!.AsArray()
            .Select(node => node!)
            .Single(entry => entry["id"]!.GetValue<string>() == id)["state"]!.GetValue<string>();

    private static string? SubstituteOf(JsonObject manifest, string id) =>
        manifest["capabilities"]!.AsArray()
            .Select(node => node!)
            .Single(entry => entry["id"]!.GetValue<string>() == id)["substitute"]?.GetValue<string>();

    private sealed class FakeOnboardingStore : ISharedUiOnboardingStateStore
    {
        public bool Telemetry { get; private set; }
        public bool CloudSync { get; private set; }
        public int Revision { get; private set; }

        public (bool TelemetryEnabled, bool CloudSyncEnabled, int Revision) Load() =>
            (Telemetry, CloudSync, Revision);

        public void Save(bool telemetryEnabled, bool cloudSyncEnabled, int revision)
        {
            Telemetry = telemetryEnabled;
            CloudSync = cloudSyncEnabled;
            Revision = revision;
        }
    }
}
