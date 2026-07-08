using System;
using System.Collections.Generic;
using Xunit;

namespace OpenBurnBar.App.TextExpansion.Tests;

/// <summary>
/// State-machine coverage for <see cref="TextExpansionRuntimeController"/> — the
/// portable behavior port of the Mac CGEvent-tap hot path
/// (AgentLens/Services/TextExpansion/TextExpansionRuntimeController.swift
/// <c>handleEvent</c>): buffer build-up, the swallowing delete-count model, the
/// post-expansion suppression window (deterministic via an injected clock), the
/// policy gates, and the secure-field guard.
/// </summary>
public sealed class RuntimeControllerTests
{
    private sealed class RecordingSink : ITextExpansionKeystrokeSink
    {
        public List<TextExpansionReplacementCommand> Commands { get; } = new();

        public void Replace(TextExpansionReplacementCommand command) => Commands.Add(command);
    }

    private static TextExpansionGlobalTapPolicy ActivePolicy(string? frontmost = "com.apple.TextEdit") =>
        new(
            globalExpansionEnabled: true,
            accessibilityTrusted: true,
            frontmostBundleIdentifier: frontmost,
            ownBundleIdentifier: "com.openburnbar.app",
            focusedSurfaceDenied: false);

    private static InMemoryTextExpansionSnippetSource Source(params TextExpansionSnippet[] snippets) =>
        new(snippets);

    private static TextExpansionKeyDecision Feed(TextExpansionRuntimeController controller, string text)
    {
        var decision = TextExpansionKeyDecision.PassThrough;
        foreach (char c in text)
        {
            decision = controller.HandleCharacter(c.ToString());
        }

        return decision;
    }

    [Fact]
    public void BoundaryMatch_SwallowsKey_AndEmitsTokenDeleteWithReappendedBoundary()
    {
        var sink = new RecordingSink();
        // audit is a strict prefix of auditlog → "&&audit" is ambiguous until the space.
        var source = Source(
            new TextExpansionSnippet(title: "Audit", trigger: "audit", body: "Audit body"),
            new TextExpansionSnippet(title: "AuditLog", trigger: "auditlog", body: "Audit log body"));
        var controller = new TextExpansionRuntimeController(source, sink, ActivePolicy());

        Assert.Equal(TextExpansionKeyDecision.PassThrough, Feed(controller, "&&audit"));
        Assert.Empty(sink.Commands);

        Assert.Equal(TextExpansionKeyDecision.Swallow, controller.HandleCharacter(" "));
        var command = Assert.Single(sink.Commands);
        Assert.Equal(7, command.DeleteCount);              // delete the whole "&&audit" token
        Assert.Equal("Audit body ", command.Replacement);  // body + re-appended boundary
        Assert.Equal("audit", command.Trigger);
        Assert.Equal(string.Empty, controller.Buffer);      // buffer cleared after expansion
    }

    [Fact]
    public void UnambiguousMatch_SwallowsKey_AndDeletesTokenMinusJustTypedChar()
    {
        var sink = new RecordingSink();
        var source = Source(new TextExpansionSnippet(title: "Confident", trigger: "confident", body: "Ready."));
        var controller = new TextExpansionRuntimeController(source, sink, ActivePolicy());

        Assert.Equal(TextExpansionKeyDecision.PassThrough, Feed(controller, "&&confiden"));
        Assert.Equal(TextExpansionKeyDecision.Swallow, controller.HandleCharacter("t"));

        var command = Assert.Single(sink.Commands);
        Assert.Equal(10, command.DeleteCount); // token length 11 minus the just-typed "t"
        Assert.Equal("Ready.", command.Replacement);
    }

    [Fact]
    public void SuppressionWindow_IgnoresSyntheticKeystrokes_UntilElapsed()
    {
        var sink = new RecordingSink();
        var source = Source(new TextExpansionSnippet(title: "Confident", trigger: "confident", body: "Ready."));
        var baseTime = new DateTimeOffset(2026, 7, 6, 12, 0, 0, TimeSpan.Zero);
        var clock = baseTime;
        var controller = new TextExpansionRuntimeController(
            source, sink, ActivePolicy(), clock: () => clock);

        Feed(controller, "&&confiden");
        Assert.Equal(TextExpansionKeyDecision.Swallow, controller.HandleCharacter("t"));
        Assert.Single(sink.Commands);

        // Within the 1.5s window: the injector's own keystrokes pass through untouched.
        clock = baseTime.AddSeconds(1.0);
        Assert.Equal(TextExpansionKeyDecision.PassThrough, Feed(controller, "&&confident"));
        Assert.Single(sink.Commands);                 // no second expansion
        Assert.Equal(string.Empty, controller.Buffer); // suppressed input never entered the buffer

        // After the window: expansion works again.
        clock = baseTime.AddSeconds(2.0);
        Feed(controller, "&&confiden");
        Assert.Equal(TextExpansionKeyDecision.Swallow, controller.HandleCharacter("t"));
        Assert.Equal(2, sink.Commands.Count);
    }

    [Fact]
    public void Backspace_CorrectsBuffer_BeforeCompletingTrigger()
    {
        var sink = new RecordingSink();
        var source = Source(new TextExpansionSnippet(title: "Confident", trigger: "confident", body: "Ready."));
        var controller = new TextExpansionRuntimeController(source, sink, ActivePolicy());

        Feed(controller, "&&confiden");
        controller.HandleCharacter("x");          // typo → buffer "&&confidenx"
        controller.HandleBackspace();             // corrected → "&&confiden"
        Assert.Equal(TextExpansionKeyDecision.Swallow, controller.HandleCharacter("t"));
        Assert.Single(sink.Commands);
    }

    [Fact]
    public void ModifierCombo_ClearsInProgressToken()
    {
        var sink = new RecordingSink();
        var source = Source(new TextExpansionSnippet(title: "Confident", trigger: "confident", body: "Ready."));
        var controller = new TextExpansionRuntimeController(source, sink, ActivePolicy());

        Feed(controller, "&&confi");
        Assert.Equal(TextExpansionKeyDecision.PassThrough, controller.HandleModifierCombo());
        Assert.Equal(string.Empty, controller.Buffer);
    }

    [Fact]
    public void BufferIsCappedToTrailing160Characters()
    {
        var sink = new RecordingSink();
        var controller = new TextExpansionRuntimeController(Source(), sink, ActivePolicy());
        Feed(controller, new string('a', 200));
        Assert.Equal(TextExpansionRuntimeController.MaxBufferLength, controller.Buffer.Length);
    }

    [Theory]
    [InlineData(false, true, "com.apple.TextEdit")]  // disabled
    [InlineData(true, false, "com.apple.TextEdit")]  // untrusted
    [InlineData(true, true, "com.openburnbar.app")]  // front app is our own app
    public void PolicyGates_SuppressExpansion(bool enabled, bool trusted, string frontmost)
    {
        var sink = new RecordingSink();
        var source = Source(new TextExpansionSnippet(title: "Confident", trigger: "confident", body: "Ready."));
        var policy = new TextExpansionGlobalTapPolicy(
            globalExpansionEnabled: enabled,
            accessibilityTrusted: trusted,
            frontmostBundleIdentifier: frontmost,
            ownBundleIdentifier: "com.openburnbar.app");
        var controller = new TextExpansionRuntimeController(source, sink, policy);

        Assert.Equal(TextExpansionKeyDecision.PassThrough, Feed(controller, "&&confident"));
        Assert.Empty(sink.Commands);
        Assert.Equal(string.Empty, controller.Buffer);
    }

    [Fact]
    public void SecureSurface_NeverExpands_AndClearsBuffer()
    {
        var sink = new RecordingSink();
        var source = Source(new TextExpansionSnippet(title: "Confident", trigger: "confident", body: "Ready."));
        var controller = new TextExpansionRuntimeController(
            source, sink, ActivePolicy(), isSecureSurface: () => true);

        Feed(controller, "&&confiden");
        Assert.Equal(TextExpansionKeyDecision.PassThrough, controller.HandleCharacter("t"));
        Assert.Empty(sink.Commands);
        Assert.Equal(string.Empty, controller.Buffer);
    }

    [Fact]
    public void LlmPreviewSnippet_IsNeverSwallowed_ByTheRuntime()
    {
        var sink = new RecordingSink();
        var source = Source(new TextExpansionSnippet(
            title: "Ctx", trigger: "ctx", body: "fit", mode: TextExpansionMode.LlmRewrite));
        var controller = new TextExpansionRuntimeController(source, sink, ActivePolicy());

        Assert.Equal(TextExpansionKeyDecision.PassThrough, Feed(controller, "&&ctx "));
        Assert.Empty(sink.Commands);
    }
}
