using System;
using System.Collections.Generic;
using System.IO;
using System.Text;
using OpenBurnBar.ComputerUse.Core.Adapters;
using OpenBurnBar.ComputerUse.Core.Gate;
using OpenBurnBar.ComputerUse.Core.KillSwitch;
using OpenBurnBar.ComputerUse.Core.Loop;
using Xunit;

namespace OpenBurnBar.ComputerUse.Tests;

public sealed class PrivilegedInputProtocolTests
{
    [Fact]
    public void DispatchRoundTripPreservesBoundedAction()
    {
        var action = new MacInputAction(
            MacInputAction.Kind.Shortcut,
            key: "K",
            modifiers: new[] { "ctrl", "shift" });

        PrivilegedInputCommand parsed = PrivilegedInputCommand.Parse(
            PrivilegedInputCommand.EncodeDispatch("session-1", "approval-1", "action-1", action));

        Assert.Equal(PrivilegedInputCommandKind.Dispatch, parsed.Kind);
        Assert.Equal("session-1", parsed.SessionId);
        Assert.Equal("approval-1", parsed.ApprovalId);
        Assert.Equal("action-1", parsed.ActionId);
        Assert.Equal(MacInputAction.Kind.Shortcut, parsed.Action!.ActionKind);
        Assert.Equal("K", parsed.Action.Key);
        Assert.Equal(new[] { "ctrl", "shift" }, parsed.Action.Modifiers);
    }

    [Theory]
    [InlineData("")]
    [InlineData("{}")]
    [InlineData("{\"action\":\"dispatch\"}")]
    [InlineData("{\"action\":\"unknown\"}")]
    [InlineData("not-json")]
    public void MalformedCommandsFailClosed(string json)
    {
        PrivilegedInputCommand command = PrivilegedInputCommand.Parse(Encoding.UTF8.GetBytes(json));
        Assert.Equal(PrivilegedInputCommandKind.Invalid, command.Kind);
        Assert.NotEmpty(command.Error!);
    }

    [Fact]
    public void OversizedTextFailsClosedWithoutEchoingPayload()
    {
        string secret = new('x', PrivilegedInputCommand.MaximumTextCharacters + 1);
        string json = "{\"action\":\"dispatch\",\"sessionId\":\"s\",\"approvalId\":\"a\","
            + "\"input\":{\"kind\":\"type\",\"text\":\"" + secret + "\"}}";

        PrivilegedInputCommand command = PrivilegedInputCommand.Parse(Encoding.UTF8.GetBytes(json));

        Assert.Equal(PrivilegedInputCommandKind.Invalid, command.Kind);
        Assert.DoesNotContain(secret, command.Error, StringComparison.Ordinal);
    }

    [Fact]
    public void NonNumericCoordinatesFailClosedWithoutThrowing()
    {
        const string json = "{\"action\":\"dispatch\",\"sessionId\":\"s\","
            + "\"approvalId\":\"a\",\"actionId\":\"id\","
            + "\"input\":{\"kind\":\"click\",\"displayX\":\"bad\",\"displayY\":2}}";

        PrivilegedInputCommand command = PrivilegedInputCommand.Parse(Encoding.UTF8.GetBytes(json));

        Assert.Equal(PrivilegedInputCommandKind.Invalid, command.Kind);
        Assert.Equal("invalid_input", command.Error);
    }

    [Fact]
    public void ControlCharactersInIdentifiersFailClosed()
    {
        const string json = "{\"action\":\"dispatch\",\"sessionId\":\"s\","
            + "\"approvalId\":\"a\",\"actionId\":\"bad\\nvalue\","
            + "\"input\":{\"kind\":\"pointer_click\"}}";

        PrivilegedInputCommand command = PrivilegedInputCommand.Parse(Encoding.UTF8.GetBytes(json));

        Assert.Equal(PrivilegedInputCommandKind.Invalid, command.Kind);
        Assert.Equal("invalid_dispatch", command.Error);
    }

    [Fact]
    public void ResponseRoundTripRequiresStructuredFields()
    {
        PrivilegedInputResponse parsed = PrivilegedInputResponse.Parse(
            new PrivilegedInputResponse(true, "dispatched").Encode());

        Assert.Equal(new PrivilegedInputResponse(true, "dispatched"), parsed);
    }

    [Theory]
    [InlineData("")]
    [InlineData("not-json")]
    [InlineData("{\"ok\":true}")]
    [InlineData("{\"ok\":\"true\",\"detail\":\"dispatched\"}")]
    [InlineData("{\"ok\":true,\"detail\":\"\"}")]
    public void MalformedResponsesFailClosed(string payload)
    {
        PrivilegedInputResponse parsed = PrivilegedInputResponse.Parse(Encoding.UTF8.GetBytes(payload));

        Assert.False(parsed.Ok);
        Assert.Equal("invalid_response", parsed.Detail);
    }

    [Fact]
    public void ExecutionDeniesProtectedTargetBeforeSynthesis()
    {
        var input = new RecordingInput();
        var service = new PrivilegedInputExecutionService(
            new FixedInspector(new UiElementInfo("CredentialUIBroker.exe", "Sign in", false, false, true)),
            input,
            new InMemoryKillSwitchFlag());
        PrivilegedInputCommand command = Dispatch(new MacInputAction(
            MacInputAction.Kind.Click,
            displayX: 10,
            displayY: 20));

        PrivilegedInputResponse result = service.Execute(command);

        Assert.False(result.Ok);
        Assert.Equal("protected_target", result.Detail);
        Assert.Equal(0, input.Calls);
    }

    [Fact]
    public void ExecutionAppliesBuiltInProtectedProcessDenyRules()
    {
        var input = new RecordingInput();
        var service = new PrivilegedInputExecutionService(
            new FixedInspector(new UiElementInfo("SecHealthUI.exe", "Windows Security", false, false, false)),
            input,
            new InMemoryKillSwitchFlag());

        PrivilegedInputResponse result = service.Execute(Dispatch(new MacInputAction(
            MacInputAction.Kind.PointerClick)));

        Assert.False(result.Ok);
        Assert.Equal("protected_target", result.Detail);
        Assert.Equal(0, input.Calls);
    }

    [Fact]
    public void ExecutionChecksKillSwitchAtLeaf()
    {
        var flag = new InMemoryKillSwitchFlag();
        flag.Activate("panic");
        var input = new RecordingInput();
        var service = new PrivilegedInputExecutionService(
            new FixedInspector(new UiElementInfo("notepad.exe", "Notes", false, false, false)),
            input,
            flag);

        PrivilegedInputResponse result = service.Execute(Dispatch(new MacInputAction(
            MacInputAction.Kind.Type,
            text: "harmless")));

        Assert.False(result.Ok);
        Assert.Equal("kill_switch", result.Detail);
        Assert.Equal(0, input.Calls);
    }

    [Fact]
    public void ExecutionFailsClosedWhenTargetInspectionThrows()
    {
        var input = new RecordingInput();
        var service = new PrivilegedInputExecutionService(
            new ThrowingInspector(),
            input,
            new InMemoryKillSwitchFlag());

        PrivilegedInputResponse result = service.Execute(Dispatch(new MacInputAction(
            MacInputAction.Kind.PointerClick)));

        Assert.False(result.Ok);
        Assert.Equal("target_unavailable", result.Detail);
        Assert.Equal(0, input.Calls);
    }

    [Fact]
    public void ExecutionFailsClosedWhenTargetProcessCannotBeIdentified()
    {
        var input = new RecordingInput();
        var service = new PrivilegedInputExecutionService(
            new FixedInspector(new UiElementInfo(null, "Unknown", false, false, false)),
            input,
            new InMemoryKillSwitchFlag());

        PrivilegedInputResponse result = service.Execute(Dispatch(new MacInputAction(
            MacInputAction.Kind.PointerClick)));

        Assert.False(result.Ok);
        Assert.Equal("target_unavailable", result.Detail);
        Assert.Equal(0, input.Calls);
    }

    [Fact]
    public void ExecutionDispatchesOnlyAfterInspectionAndSecondKillCheck()
    {
        var input = new RecordingInput();
        var flag = new CountingKillSwitchFlag();
        var service = new PrivilegedInputExecutionService(
            new FixedInspector(new UiElementInfo("notepad.exe", "Notes", false, false, false)),
            input,
            flag);

        PrivilegedInputResponse result = service.Execute(Dispatch(new MacInputAction(
            MacInputAction.Kind.Type,
            text: "harmless")));

        Assert.True(result.Ok);
        Assert.Equal("dispatched", result.Detail);
        Assert.Equal(2, flag.Reads);
        Assert.Equal(1, input.Calls);
    }

    [Fact]
    public void CompletedActionReplaysReceiptWithoutSynthesizingTwice()
    {
        var input = new RecordingInput();
        var service = new PrivilegedInputExecutionService(
            new FixedInspector(new UiElementInfo("notepad.exe", "Notes", false, false, false)),
            input,
            new InMemoryKillSwitchFlag());
        PrivilegedInputCommand command = Dispatch(new MacInputAction(
            MacInputAction.Kind.PointerClick));

        PrivilegedInputResponse first = service.Execute(command);
        PrivilegedInputResponse replay = service.Execute(command);

        Assert.True(first.Ok);
        Assert.Equal(first, replay);
        Assert.Equal(1, input.Calls);
    }

    [Fact]
    public void PendingActionFailsIndeterminateWithoutSynthesis()
    {
        var receipts = new InMemoryPrivilegedInputReceiptStore();
        _ = receipts.Reserve("action");
        var input = new RecordingInput();
        var service = new PrivilegedInputExecutionService(
            new FixedInspector(new UiElementInfo("notepad.exe", "Notes", false, false, false)),
            input,
            new InMemoryKillSwitchFlag(),
            receipts);

        PrivilegedInputResponse result = service.Execute(Dispatch(new MacInputAction(
            MacInputAction.Kind.PointerClick)));

        Assert.False(result.Ok);
        Assert.Equal("dispatch_indeterminate", result.Detail);
        Assert.Equal(0, input.Calls);
    }

    [Fact]
    public void FileReceiptStorePersistsCompletedResponse()
    {
        string directory = Path.Combine(Path.GetTempPath(), "obb-receipts-" + Guid.NewGuid().ToString("N"));
        string path = Path.Combine(directory, "receipts.json");
        try
        {
            var first = new FilePrivilegedInputReceiptStore(path);
            Assert.Equal(PrivilegedInputReceiptState.Reserved, first.Reserve("action-1").State);
            first.Complete("action-1", new PrivilegedInputResponse(true, "dispatched"));

            var reopened = new FilePrivilegedInputReceiptStore(path);
            PrivilegedInputReceiptReservation replay = reopened.Reserve("action-1");
            Assert.Equal(PrivilegedInputReceiptState.Completed, replay.State);
            Assert.Equal(new PrivilegedInputResponse(true, "dispatched"), replay.Response);
        }
        finally
        {
            if (Directory.Exists(directory)) Directory.Delete(directory, recursive: true);
        }
    }

    [Fact]
    public void CorruptFileReceiptStoreFailsClosed()
    {
        string directory = Path.Combine(Path.GetTempPath(), "obb-receipts-" + Guid.NewGuid().ToString("N"));
        string path = Path.Combine(directory, "receipts.json");
        try
        {
            Directory.CreateDirectory(directory);
            File.WriteAllText(path, "not-json");
            var store = new FilePrivilegedInputReceiptStore(path);

            Assert.Throws<InvalidOperationException>(() => store.Reserve("action-1"));
        }
        finally
        {
            if (Directory.Exists(directory)) Directory.Delete(directory, recursive: true);
        }
    }

    [Fact]
    public void NullEntryListInFileReceiptStoreFailsClosed()
    {
        string directory = Path.Combine(Path.GetTempPath(), "obb-receipts-" + Guid.NewGuid().ToString("N"));
        string path = Path.Combine(directory, "receipts.json");
        try
        {
            Directory.CreateDirectory(directory);
            File.WriteAllText(path, "{\"Entries\":null}");
            var store = new FilePrivilegedInputReceiptStore(path);

            Assert.Throws<InvalidOperationException>(() => store.Reserve("action-1"));
        }
        finally
        {
            if (Directory.Exists(directory)) Directory.Delete(directory, recursive: true);
        }
    }

    private static PrivilegedInputCommand Dispatch(MacInputAction action) =>
        PrivilegedInputCommand.Parse(
            PrivilegedInputCommand.EncodeDispatch("session", "approval", "action", action));

    private sealed class FixedInspector(UiElementInfo element) : IUiInspector
    {
        public UiElementInfo InspectPoint(int displayX, int displayY) => element;
        public UiElementInfo InspectFrontmost() => element;
    }

    private sealed class ThrowingInspector : IUiInspector
    {
        public UiElementInfo InspectPoint(int displayX, int displayY) => throw new InvalidOperationException();
        public UiElementInfo InspectFrontmost() => throw new InvalidOperationException();
    }

    private sealed class RecordingInput : IInputSynthesizer
    {
        public int Calls { get; private set; }
        public bool RoutesThroughSignedDriver => false;

        public InputSynthesisResult Synthesize(MacInputAction action)
        {
            Calls++;
            return new InputSynthesisResult(true, "ok");
        }
    }

    private sealed class CountingKillSwitchFlag : IKillSwitchFlag
    {
        public int Reads { get; private set; }
        public bool IsActive { get { Reads++; return false; } }
        public string? Reason => null;
        public void Activate(string? reason = null) { }
        public void Clear() { }
    }
}
