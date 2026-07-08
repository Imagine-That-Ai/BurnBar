using System;
using System.Linq;
using System.Threading.Tasks;
using OpenBurnBar.App.Presentation.Budget;
using Xunit;

namespace OpenBurnBar.App.Presentation.Tests.Budget;

// Port of the BudgetSettings partitioning + write-with-audit behavior the macOS Settings UI
// (and BudgetGate) rely on.

public sealed class BudgetSettingsModelTests
{
    private static BudgetSettingsModel NewModel() =>
        new(new InMemoryBudgetRuleStore(), deviceId: "test-device", now: () => new DateTimeOffset(2026, 7, 3, 0, 0, 0, TimeSpan.Zero));

    [Fact]
    public async Task Upsert_PartitionsRulesByScope()
    {
        BudgetSettingsModel model = NewModel();
        await model.UpsertRuleAsync(new BudgetRule { Scope = BudgetRuleScope.Global, AmountUsd = 100 });
        await model.UpsertRuleAsync(new BudgetRule { Scope = BudgetRuleScope.Credential, ProviderId = "openai", AmountUsd = 50 });
        await model.UpsertRuleAsync(new BudgetRule { Scope = BudgetRuleScope.Project, ProjectName = "burnbar", AmountUsd = 25 });

        Assert.Single(model.GlobalRules);
        Assert.Single(model.CredentialRules);
        Assert.Single(model.ProjectRules);
        // Observable collections the WinUI list sections bind to are kept in sync.
        Assert.Single(model.GlobalRuleItems);
        Assert.Single(model.CredentialRuleItems);
        Assert.Single(model.ProjectRuleItems);
    }

    [Fact]
    public async Task Upsert_NewThenSameId_EmitsCreatedThenUpdated()
    {
        BudgetSettingsModel model = NewModel();
        BudgetRule created = await model.UpsertRuleAsync(new BudgetRule { Scope = BudgetRuleScope.Global, AmountUsd = 100 });
        await model.UpsertRuleAsync(created with { AmountUsd = 150 });

        var events = model.RecentEvents();
        // Newest first.
        Assert.Equal(BudgetEventKind.RuleUpdated, events[0].Kind);
        Assert.Equal(BudgetEventKind.RuleCreated, events[1].Kind);
        Assert.Equal(150, model.GlobalRules.Single().AmountUsd);
    }

    [Fact]
    public async Task Delete_RemovesRule_AndEmitsDeletedEvent()
    {
        BudgetSettingsModel model = NewModel();
        BudgetRule created = await model.UpsertRuleAsync(new BudgetRule { Scope = BudgetRuleScope.Credential, ProviderId = "openai", AmountUsd = 50 });

        await model.DeleteRuleAsync(created.Id);

        Assert.Empty(model.CredentialRules);
        Assert.Empty(model.CredentialRuleItems);
        Assert.Equal(BudgetEventKind.RuleDeleted, model.RecentEvents()[0].Kind);
    }

    [Fact]
    public async Task PrimaryGlobalRule_IsTheLargestAmount()
    {
        BudgetSettingsModel model = NewModel();
        await model.UpsertRuleAsync(new BudgetRule { Scope = BudgetRuleScope.Global, AmountUsd = 100 });
        BudgetRule big = await model.UpsertRuleAsync(new BudgetRule { Scope = BudgetRuleScope.Global, AmountUsd = 500 });
        await model.UpsertRuleAsync(new BudgetRule { Scope = BudgetRuleScope.Global, AmountUsd = 250 });

        Assert.Equal(big.Id, model.PrimaryGlobalRule!.Id);
    }

    [Fact]
    public async Task RulesForCredential_MatchesProviderAndAccount()
    {
        BudgetSettingsModel model = NewModel();
        await model.UpsertRuleAsync(new BudgetRule { Scope = BudgetRuleScope.Credential, ProviderId = "openai", AccountId = "slot-1", AmountUsd = 50 });
        await model.UpsertRuleAsync(new BudgetRule { Scope = BudgetRuleScope.Credential, ProviderId = "openai", AccountId = "slot-2", AmountUsd = 60 });

        Assert.Single(model.RulesForCredential("openai", "slot-1"));
        Assert.Empty(model.RulesForCredential("openai", "slot-3"));
        Assert.Empty(model.RulesForCredential("anthropic", "slot-1"));
    }

    [Fact]
    public async Task StampsSourceDevice_AndClearsSyncedAt_OnUpsert()
    {
        BudgetSettingsModel model = NewModel();
        BudgetRule created = await model.UpsertRuleAsync(new BudgetRule { Scope = BudgetRuleScope.Global, AmountUsd = 100, SyncedAt = DateTimeOffset.UtcNow });

        Assert.Equal("test-device", created.SourceDeviceId);
        Assert.Null(created.SyncedAt);
        Assert.Equal(new DateTimeOffset(2026, 7, 3, 0, 0, 0, TimeSpan.Zero), created.UpdatedAt);
    }

    [Fact]
    public async Task Model_IsReadableByTheGate_AsARuleProvider()
    {
        BudgetSettingsModel model = NewModel();
        await model.UpsertRuleAsync(new BudgetRule
        {
            Scope = BudgetRuleScope.Credential,
            ProviderId = "openrouter",
            AccountId = "slot-1",
            AmountUsd = 50,
            Behavior = BudgetBehavior.HardBlock,
        });

        // The SAME settings model backs the gate (IBudgetRuleProvider), so a UI-created rule
        // is immediately enforceable with no second source of truth.
        var gate = new BudgetGate(model, new StubLedger(60.0));
        BudgetGateDecision decision = await gate.EvaluateAsync(BudgetFixtures.Credential(), estimatedCost: 1.0);

        Assert.IsType<BudgetGateDecision.Block>(decision);
    }
}
