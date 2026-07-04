using System;
using System.Collections.Generic;
using OpenBurnBar.ComputerUse.Core.Scope;
using Xunit;

namespace OpenBurnBar.ComputerUse.Tests;

public sealed class ScopeTests
{
    private static readonly DateTimeOffset Now = new(2026, 7, 3, 12, 0, 0, TimeSpan.Zero);
    private readonly ScopeMatcher _matcher = new();

    private static ScopeRule Rule(
        string id, ScopeEffect effect, string? url = null, string? bundle = null, string? title = null,
        DateTimeOffset? created = null, DateTimeOffset? expires = null, int? budget = null)
        => new(id, effect, ScopeOrigin.User, id, url, bundle, title, budget, expires, created ?? Now);

    [Fact]
    public void DenyPrecedesAllowWhenBothMatch()
    {
        var rules = new[]
        {
            Rule("allow", ScopeEffect.Allow, bundle: "chrome.exe"),
            Rule("deny", ScopeEffect.Deny, bundle: "chrome.exe"),
        };
        var outcome = _matcher.Evaluate(rules, new ScopeContext(bundleId: "chrome.exe"), Now);

        Assert.Equal(ScopeOutcome.Kind.Denied, outcome.Result);
        Assert.Equal("deny", outcome.RuleId);
    }

    [Fact]
    public void NewestAllowWinsAmongAllows()
    {
        var rules = new[]
        {
            Rule("old", ScopeEffect.Allow, bundle: "chrome.exe", created: Now.AddHours(-2)),
            Rule("new", ScopeEffect.Allow, bundle: "chrome.exe", created: Now.AddHours(-1)),
        };
        var outcome = _matcher.Evaluate(rules, new ScopeContext(bundleId: "chrome.exe"), Now);

        Assert.Equal(ScopeOutcome.Kind.Allowed, outcome.Result);
        Assert.Equal("new", outcome.RuleId);
    }

    [Fact]
    public void UrlPrefixMatchesCaseInsensitively()
    {
        var rules = new[] { Rule("a", ScopeEffect.Allow, url: "https://Example.com/App") };
        var outcome = _matcher.Evaluate(rules, new ScopeContext(url: "https://example.com/app/page"), Now);
        Assert.Equal(ScopeOutcome.Kind.Allowed, outcome.Result);
    }

    [Fact]
    public void BundleWildcardIsAPrefixMatch()
    {
        var rules = new[] { Rule("a", ScopeEffect.Allow, bundle: "com.foo.*") };
        Assert.Equal(ScopeOutcome.Kind.Allowed,
            _matcher.Evaluate(rules, new ScopeContext(bundleId: "com.foo.bar"), Now).Result);
        Assert.Equal(ScopeOutcome.Kind.NotMatched,
            _matcher.Evaluate(rules, new ScopeContext(bundleId: "com.other"), Now).Result);
    }

    [Fact]
    public void WindowTitleRegexIsUnanchored()
    {
        var rules = new[] { Rule("a", ScopeEffect.Deny, title: "admin") };
        Assert.Equal(ScopeOutcome.Kind.Denied,
            _matcher.Evaluate(rules, new ScopeContext(windowTitle: "site / admin / page"), Now).Result);
    }

    [Fact]
    public void ExpiredRuleIsSkipped()
    {
        var rules = new[] { Rule("a", ScopeEffect.Allow, bundle: "chrome.exe", expires: Now.AddSeconds(-1)) };
        Assert.Equal(ScopeOutcome.Kind.NotMatched,
            _matcher.Evaluate(rules, new ScopeContext(bundleId: "chrome.exe"), Now).Result);
    }

    [Fact]
    public void BudgetExhaustedRuleIsSkipped()
    {
        var rule = Rule("a", ScopeEffect.Allow, bundle: "chrome.exe", budget: 3);
        var states = new Dictionary<string, ScopeBudgetState> { ["a"] = new("a", actionsConsumed: 3) };
        Assert.Equal(ScopeOutcome.Kind.NotMatched,
            _matcher.Evaluate(new[] { rule }, new ScopeContext(bundleId: "chrome.exe"), Now, states).Result);
    }

    [Fact]
    public void EmptyRuleSetIsNotMatched()
    {
        Assert.Equal(ScopeOutcome.Kind.NotMatched,
            _matcher.Evaluate(Array.Empty<ScopeRule>(), new ScopeContext(bundleId: "x"), Now).Result);
    }

    [Fact]
    public void InvalidRegexDoesNotMatchAndDoesNotThrow()
    {
        var rules = new[] { Rule("a", ScopeEffect.Allow, title: "(unclosed") };
        Assert.Equal(ScopeOutcome.Kind.NotMatched,
            _matcher.Evaluate(rules, new ScopeContext(windowTitle: "anything"), Now).Result);
    }

    [Fact]
    public void OverlapsBuiltInDenyDetectsAndAcceptsNonOverlap()
    {
        var proposedOverlap = Rule("p", ScopeEffect.Allow, bundle: "LogonUI.exe");
        Assert.True(_matcher.OverlapsBuiltInDeny(
            proposedOverlap, DenyRegistry.BuiltInRules, DenyRegistry.EditorOverlapProbes));

        var proposedSafe = Rule("s", ScopeEffect.Allow, bundle: "notepad.exe");
        Assert.False(_matcher.OverlapsBuiltInDeny(
            proposedSafe, DenyRegistry.BuiltInRules, DenyRegistry.EditorOverlapProbes));
    }

    [Theory]
    [InlineData("LogonUI.exe", null, null)]
    [InlineData("consent.exe", null, null)]
    [InlineData("CredentialUIBroker.exe", null, null)]
    [InlineData(null, "https://accounts.google.com/o/oauth2/v2/auth", null)]
    [InlineData(null, "file:///C:/secret", null)]
    [InlineData(null, "http://127.0.0.1:11434/api", null)]
    [InlineData(null, "http://metadata.google.internal/x", null)]
    [InlineData(null, null, "app/admin/settings")]
    public void BuiltInDenyRegistryBlocksSecureAndSensitiveSurfaces(string? bundle, string? url, string? title)
    {
        var outcome = _matcher.Evaluate(
            DenyRegistry.BuiltInRules, new ScopeContext(url: url, bundleId: bundle, windowTitle: title), Now);
        Assert.Equal(ScopeOutcome.Kind.Denied, outcome.Result);
    }

    [Fact]
    public void BuiltInDenyRegistryLeavesBenignContextUnmatched()
    {
        var outcome = _matcher.Evaluate(
            DenyRegistry.BuiltInRules,
            new ScopeContext(url: "https://example.com/docs", bundleId: "notepad.exe", windowTitle: "Untitled"),
            Now);
        Assert.Equal(ScopeOutcome.Kind.NotMatched, outcome.Result);
    }

    [Fact]
    public void IsBuiltInIdentifiesRegistryRules()
    {
        Assert.True(DenyRegistry.IsBuiltIn("builtin.logonui"));
        Assert.False(DenyRegistry.IsBuiltIn("user.custom"));
    }

    [Fact]
    public void AccessibilityDenyReasonWireIsStable()
    {
        Assert.Equal("secure_text_field", AccessibilityDenyReason.SecureTextField.ToWire());
        Assert.Equal("system_auth_sheet", AccessibilityDenyReason.SystemAuthSheet.ToWire());
        Assert.Equal("keychain_prompt", AccessibilityDenyReason.KeychainPrompt.ToWire());
        Assert.Equal("unknown", AccessibilityDenyReason.Unknown.ToWire());
    }
}
