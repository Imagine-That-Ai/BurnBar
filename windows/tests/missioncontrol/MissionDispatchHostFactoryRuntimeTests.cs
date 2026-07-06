using System;
using System.Threading.Tasks;
using OpenBurnBar.App.Configuration;
using OpenBurnBar.App.MissionControl;
using OpenBurnBar.App.Presentation.MissionControl;
using Xunit;

namespace OpenBurnBar.App.MissionControl.Tests;

public sealed class MissionDispatchHostFactoryRuntimeTests
{
    private const string SampleEnv = "OPENBURNBAR_SAMPLE_MODE";

    [Fact]
    public void Create_without_credentials_returns_empty_host_when_sample_mode_off()
    {
        try
        {
            Environment.SetEnvironmentVariable(SampleEnv, null);
            IMissionDispatchHost host = MissionDispatchHostFactory.Create(null, null, null);
            Assert.IsType<EmptyMissionDispatchHost>(host);
        }
        finally
        {
            Environment.SetEnvironmentVariable(SampleEnv, null);
        }
    }

    [Fact]
    public void Create_without_credentials_returns_demo_host_when_sample_mode_on()
    {
        try
        {
            Environment.SetEnvironmentVariable(SampleEnv, "1");
            IMissionDispatchHost host = MissionDispatchHostFactory.Create(null, null, null);
            Assert.IsType<MissionDispatchDemoHost>(host);
        }
        finally
        {
            Environment.SetEnvironmentVariable(SampleEnv, null);
        }
    }

    [Fact]
    public async Task Empty_fallback_dispatch_fails_with_actionable_message_not_demo_success()
    {
        try
        {
            Environment.SetEnvironmentVariable(SampleEnv, null);
            IMissionDispatchHost host = MissionDispatchHostFactory.Create(null, null, null);
            MissionDispatchOutcome outcome = await host.DispatchAsync(
                new MissionDispatchRequest(
                    title: "t",
                    prompt: "p",
                    kind: MissionKind.Diligence,
                    runtimeId: "claude",
                    targetProject: null,
                    depth: MissionDepth.Standard,
                    approvalMode: MissionApprovalMode.ExistingPolicy,
                    commandsAllowed: false,
                    fileEditsAllowed: true));

            Assert.False(outcome.Dispatched);
            Assert.Contains("OPENBURNBAR_SAMPLE_MODE=1", outcome.FailureMessage ?? string.Empty);
        }
        finally
        {
            Environment.SetEnvironmentVariable(SampleEnv, null);
        }
    }
}