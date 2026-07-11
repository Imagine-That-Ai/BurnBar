using System;
using System.IO;
using System.Threading;
using System.Threading.Tasks;
using OpenBurnBar.ComputerUse.Core.Adapters;
using OpenBurnBar.ComputerUse.Core.Audit;
using OpenBurnBar.ComputerUse.Core.Gate;
using OpenBurnBar.ComputerUse.Core.KillSwitch;
using OpenBurnBar.ComputerUse.Core.Loop;
using Xunit;

namespace OpenBurnBar.ComputerUse.Tests;

public sealed class DesktopLoopTests
{
    [Fact]
    public void Dispatch_WhenKillSwitchActive_DeniesWithoutSynthesize()
    {
        var flag = new InMemoryKillSwitchFlag();
        flag.Activate("test");
        var kill = new KillSwitchStateMachine(flag);
        var input = new RecordingSynthesizer();
        var loop = new ComputerUseDesktopLoop(input, kill);

        ComputerUseLoopResult result = loop.Click(10, 20);
        Assert.False(result.Succeeded);
        Assert.Equal(ComputerUseDenyReason.KillSwitch, result.DenyReason);
        Assert.Equal(0, input.Calls);
    }

    [Fact]
    public void Dispatch_WhenAllowed_SynthesizesClick()
    {
        var flag = new InMemoryKillSwitchFlag();
        var kill = new KillSwitchStateMachine(flag);
        var input = new RecordingSynthesizer(routesThroughSignedDriver: true);
        var loop = new ComputerUseDesktopLoop(input, kill);

        ComputerUseLoopResult result = loop.Click(3, 4);
        Assert.True(result.Succeeded);
        Assert.Equal(1, input.Calls);
        Assert.Equal(MacInputAction.Kind.Click, input.Last!.ActionKind);
        Assert.Equal(3, input.Last.DisplayX);
        Assert.Equal(4, input.Last.DisplayY);
    }

    [Fact]
    public void Dispatch_NonBypassableActionRefusesAdvisorySendInputRoute()
    {
        var input = new RecordingSynthesizer(routesThroughSignedDriver: false);
        var loop = new ComputerUseDesktopLoop(
            input,
            new KillSwitchStateMachine(new InMemoryKillSwitchFlag()));

        ComputerUseLoopResult result = loop.Dispatch(new MacInputAction(MacInputAction.Kind.Type, text: "secret"));

        Assert.False(result.Succeeded);
        Assert.Equal(ComputerUseDenyReason.SignatureFailure, result.DenyReason);
        Assert.Equal(0, input.Calls);
    }

    [Fact]
    public void Dispatch_AdvisoryPointerMoveCanUseSendInputRoute()
    {
        var input = new RecordingSynthesizer(routesThroughSignedDriver: false);
        var loop = new ComputerUseDesktopLoop(
            input,
            new KillSwitchStateMachine(new InMemoryKillSwitchFlag()));

        ComputerUseLoopResult result = loop.Dispatch(
            new MacInputAction(MacInputAction.Kind.PointerMove, displayX: 2, displayY: 3));

        Assert.True(result.Succeeded);
        Assert.Equal(1, input.Calls);
    }

    [Fact]
    public void RuntimeSession_ApprovedActionDispatchesAndProducesVerifiableAudit()
    {
        string root = TempRoot();
        try
        {
            var input = new RecordingSynthesizer(routesThroughSignedDriver: true);
            var session = Runtime(root, input, new StaticInspector(password: false), new InMemoryKillSwitchFlag());

            ComputerUseLoopResult result = session.DispatchAlreadyApproved(
                new MacInputAction(MacInputAction.Kind.Type, text: "sentinel"),
                AuditApprovedBy.Mac,
                approvalId: "approval-1");

            Assert.True(result.Succeeded);
            Assert.Equal(1, input.Calls);
            AuditArchiveResult audit = new ComputerUseAuditArchive(root).Validate(session.SessionId);
            Assert.True(audit.Success, audit.Message);
            Assert.Equal(1, audit.EntryCount);
        }
        finally
        {
            Directory.Delete(root, recursive: true);
        }
    }

    [Fact]
    public void RuntimeSession_PasswordTargetIsAuditedAndNeverSynthesized()
    {
        string root = TempRoot();
        try
        {
            var input = new RecordingSynthesizer(routesThroughSignedDriver: true);
            var session = Runtime(root, input, new StaticInspector(password: true), new InMemoryKillSwitchFlag());

            ComputerUseLoopResult result = session.DispatchAlreadyApproved(
                new MacInputAction(MacInputAction.Kind.Click, displayX: 5, displayY: 5),
                AuditApprovedBy.Mac);

            Assert.False(result.Succeeded);
            Assert.Equal(ComputerUseDenyReason.DenyRegion, result.DenyReason);
            Assert.Equal(0, input.Calls);
            Assert.True(new ComputerUseAuditArchive(root).Validate(session.SessionId).Success);
        }
        finally
        {
            Directory.Delete(root, recursive: true);
        }
    }

    [Fact]
    public void RuntimeSession_FailedDispatchIsRecordedAsDenied()
    {
        string root = TempRoot();
        try
        {
            var input = new RecordingSynthesizer(
                routesThroughSignedDriver: true,
                synthesisResult: new InputSynthesisResult(false, "empty_scroll"));
            var session = Runtime(root, input, new StaticInspector(password: false), new InMemoryKillSwitchFlag());

            ComputerUseLoopResult result = session.DispatchAlreadyApproved(
                new MacInputAction(MacInputAction.Kind.Scroll, displayX: 5, displayY: 5, deltaY: 0),
                AuditApprovedBy.Mac);

            Assert.False(result.Succeeded);
            Assert.Equal(ComputerUseDenyReason.AuditFailure, result.DenyReason);
            AuditArchiveResult audit = new ComputerUseAuditArchive(root).Validate(session.SessionId);
            Assert.True(audit.Success, audit.Message);
            Assert.Equal(2, audit.EntryCount);

            string chain = File.ReadAllText(Path.Combine(root, session.SessionId, "chain.jsonl"));
            Assert.Contains("\"approvedBy\":\"denied\"", chain, StringComparison.Ordinal);
            Assert.Contains("\"denyReason\":\"audit_failure\"", chain, StringComparison.Ordinal);
        }
        finally
        {
            Directory.Delete(root, recursive: true);
        }
    }

    [Fact]
    public void RuntimeSession_WatchdogFlagBlocksBeforeInspectionOrSynthesis()
    {
        string root = TempRoot();
        try
        {
            var input = new RecordingSynthesizer(routesThroughSignedDriver: true);
            var inspector = new StaticInspector(password: false);
            var flag = new InMemoryKillSwitchFlag();
            var session = Runtime(root, input, inspector, flag);
            flag.Activate("watchdog");

            ComputerUseLoopResult result = session.DispatchAlreadyApproved(
                new MacInputAction(MacInputAction.Kind.Type, text: "must-not-dispatch"),
                AuditApprovedBy.Mac);

            Assert.False(result.Succeeded);
            Assert.Equal(ComputerUseDenyReason.KillSwitch, result.DenyReason);
            Assert.Equal(0, inspector.Calls);
            Assert.Equal(0, input.Calls);
        }
        finally
        {
            Directory.Delete(root, recursive: true);
        }
    }

    [Fact]
    public async Task RuntimeSession_RejectedApprovalIsAuditedAndNeverSynthesized()
    {
        string root = TempRoot();
        try
        {
            var input = new RecordingSynthesizer(routesThroughSignedDriver: true);
            var session = Runtime(root, input, new StaticInspector(password: false), new InMemoryKillSwitchFlag());

            ComputerUseLoopResult result = await session.RequestApprovalAndDispatchAsync(
                new MacInputAction(MacInputAction.Kind.Type, text: "must-not-dispatch"),
                new StaticApprovalChannel(approved: false));

            Assert.False(result.Succeeded);
            Assert.Equal(ComputerUseDenyReason.UserRejected, result.DenyReason);
            Assert.Equal(0, input.Calls);
            Assert.True(new ComputerUseAuditArchive(root).Validate(session.SessionId).Success);
        }
        finally
        {
            Directory.Delete(root, recursive: true);
        }
    }

    private static string TempRoot()
    {
        string root = Path.Combine(Path.GetTempPath(), "cu-runtime-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(root);
        return root;
    }

    private static ComputerUseRuntimeSession Runtime(
        string root,
        RecordingSynthesizer input,
        StaticInspector inspector,
        IKillSwitchFlag flag)
    {
        var manifest = new ComputerUseSessionManifest(
            sessionId: "runtime-session",
            mode: ComputerUseMode.System,
            trustMode: ComputerUseTrustMode.Manual,
            startedAt: DateTimeOffset.UtcNow,
            userId: "test-user",
            entitlementProductId: "computer-use-test",
            actionCap: 10,
            sessionTimeoutSeconds: 60);
        return new ComputerUseRuntimeSession(
            manifest,
            root,
            "1.0-test",
            input,
            inspector,
            new KillSwitchStateMachine(flag));
    }

    private sealed class RecordingSynthesizer(
        bool routesThroughSignedDriver = false,
        InputSynthesisResult? synthesisResult = null) : IInputSynthesizer
    {
        public int Calls { get; private set; }

        public MacInputAction? Last { get; private set; }

        public bool RoutesThroughSignedDriver => routesThroughSignedDriver;

        public InputSynthesisResult Synthesize(MacInputAction action)
        {
            Calls++;
            Last = action;
            return synthesisResult ?? new InputSynthesisResult(true, "ok");
        }
    }

    private sealed class StaticInspector(bool password) : IUiInspector
    {
        public int Calls { get; private set; }

        public UiElementInfo InspectPoint(int displayX, int displayY) => Inspect();

        public UiElementInfo InspectFrontmost() => Inspect();

        private UiElementInfo Inspect()
        {
            Calls++;
            return new UiElementInfo("test.exe", "Test", password, false, false);
        }
    }

    private sealed class StaticApprovalChannel(bool approved) : IDaemonApprovalChannel
    {
        public Task<ApprovalDecision> RequestApprovalAsync(
            ComputerUseAction action,
            string sessionId,
            CancellationToken cancellationToken = default) =>
            Task.FromResult(new ApprovalDecision(approved, "approval-test"));
    }
}
