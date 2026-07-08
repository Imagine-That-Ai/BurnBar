using OpenBurnBar.App.Presentation.Budget;
using Xunit;

namespace OpenBurnBar.App.Presentation.Tests.Budget;

// Port of the BudgetRuleEditor Form validation (saveDisabled) + field -> rule projection.

public sealed class BudgetRuleEditorViewModelTests
{
    [Fact]
    public void NewCredentialRule_RequiresAProvider()
    {
        var vm = BudgetRuleEditorViewModel.ForNewRule(BudgetRuleScope.Credential);
        Assert.True(vm.SaveDisabled);   // no provider yet

        vm.ProviderId = "openai";
        Assert.False(vm.SaveDisabled);
        Assert.True(vm.CanSave);
    }

    [Fact]
    public void NewProjectRule_RequiresAProjectName()
    {
        var vm = BudgetRuleEditorViewModel.ForNewRule(BudgetRuleScope.Project);
        Assert.True(vm.SaveDisabled);

        vm.ProjectName = "burnbar";
        Assert.False(vm.SaveDisabled);
    }

    [Fact]
    public void NewGlobalRule_ValidWithPositiveAmount()
    {
        var vm = BudgetRuleEditorViewModel.ForNewRule(BudgetRuleScope.Global);
        Assert.False(vm.SaveDisabled);   // default amount is 50

        vm.AmountUsd = 0;
        Assert.True(vm.SaveDisabled);     // non-positive amount is invalid

        vm.AmountUsd = -5;
        Assert.True(vm.SaveDisabled);
    }

    [Fact]
    public void Build_ProjectsFields_AndNullifiesEmptyText()
    {
        var vm = BudgetRuleEditorViewModel.ForNewRule(BudgetRuleScope.Credential);
        vm.ProviderId = "anthropic";
        vm.AmountUsd = 120;
        vm.Period = BudgetPeriod.Week;
        vm.Behavior = BudgetBehavior.HardBlock;
        vm.Label = "   ";   // whitespace-only collapses to null

        BudgetRule rule = vm.Build();

        Assert.Equal(BudgetRuleScope.Credential, rule.Scope);
        Assert.Equal("anthropic", rule.ProviderId);
        Assert.Equal(120, rule.AmountUsd);
        Assert.Equal(BudgetPeriod.Week, rule.Period);
        Assert.Equal(BudgetBehavior.HardBlock, rule.Behavior);
        Assert.Null(rule.Label);
    }

    [Fact]
    public void ForExisting_PreservesIdentity_AndAppliesEdits()
    {
        var source = new BudgetRule
        {
            Id = "keep-me",
            Scope = BudgetRuleScope.Global,
            AmountUsd = 100,
            Label = "Original",
        };
        var vm = BudgetRuleEditorViewModel.ForExisting(source);
        vm.AmountUsd = 250;
        vm.Label = "Renamed";

        BudgetRule edited = vm.Build();

        Assert.Equal("keep-me", edited.Id);
        Assert.Equal(250, edited.AmountUsd);
        Assert.Equal("Renamed", edited.Label);
    }

    [Fact]
    public void PropertyChanged_FiresForSaveDisabled_WhenValidityChanges()
    {
        var vm = BudgetRuleEditorViewModel.ForNewRule(BudgetRuleScope.Credential);
        bool sawSaveDisabled = false;
        vm.PropertyChanged += (_, e) =>
        {
            if (e.PropertyName == nameof(BudgetRuleEditorViewModel.SaveDisabled))
            {
                sawSaveDisabled = true;
            }
        };

        vm.ProviderId = "openai";
        Assert.True(sawSaveDisabled);
    }
}
