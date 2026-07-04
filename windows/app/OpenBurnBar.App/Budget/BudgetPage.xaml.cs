using System.Collections.Generic;
using System.Threading.Tasks;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Navigation;
using OpenBurnBar.App.Storage;

namespace OpenBurnBar.App.Budget;

/// <summary>
/// The Budget rule-editor surface (Windows). Hosts the global / credential / project rule
/// sections, the recent-activity audit list, and a live preview of the reusable
/// <see cref="BurnRailBudgetChip"/> + <see cref="BudgetBlockedCard"/>. Bound to the portable
/// <see cref="BudgetSettingsModel"/> (unit-tested on macOS). Registered as the "budget"
/// destination in the AppShell NavigationView.
///
/// Dev-host: <see cref="WindowsStorageDevHost.CreateBudgetRuleStore"/> uses SQLCipher when
/// <c>OPENBURNBAR_SQLCIPHER_PATH</c> + passphrase are set; otherwise seeds
/// <see cref="InMemoryBudgetRuleStore"/> with <see cref="SeedRules"/>.
/// </summary>
public sealed partial class BudgetPage : Page
{
    private BudgetSettingsModel _settings = new(WindowsStorageDevHost.CreateBudgetRuleStore());

    public BudgetPage()
    {
        InitializeComponent();
        Loaded += OnLoaded;
    }

    protected override void OnNavigatedTo(NavigationEventArgs e)
    {
        base.OnNavigatedTo(e);
    }

    private async void OnLoaded(object sender, RoutedEventArgs e)
    {
        Loaded -= OnLoaded;
        _settings = new BudgetSettingsModel(WindowsStorageDevHost.CreateBudgetRuleStore(SeedRules()));
        await _settings.RefreshAsync();

        GlobalList.ItemsSource = _settings.GlobalRuleItems;
        CredentialList.ItemsSource = _settings.CredentialRuleItems;
        ProjectList.ItemsSource = _settings.ProjectRuleItems;
        EventsList.ItemsSource = _settings.RecentEventItems;
        RefreshEventsVisibility();

        LoadPreview();
    }

    // ── Add / edit ─────────────────────────────────────────────────────────────

    private async void Add_Click(object sender, RoutedEventArgs e)
    {
        if (sender is not FrameworkElement element || element.Tag is not string tag)
        {
            return;
        }

        BudgetRuleScope scope = tag switch
        {
            "credential" => BudgetRuleScope.Credential,
            "project" => BudgetRuleScope.Project,
            _ => BudgetRuleScope.Global,
        };

        await EditAsync(BudgetRuleEditorViewModel.ForNewRule(scope));
    }

    private async void RuleRow_Click(object sender, RoutedEventArgs e)
    {
        if (sender is FrameworkElement { Tag: string id } && FindRule(id) is BudgetRule rule)
        {
            await EditAsync(BudgetRuleEditorViewModel.ForExisting(rule));
        }
    }

    private async Task EditAsync(BudgetRuleEditorViewModel viewModel)
    {
        var dialog = new BudgetRuleEditorDialog(viewModel)
        {
            XamlRoot = XamlRoot,
        };

        BudgetRuleEditorResult result = await dialog.ShowEditorAsync();
        switch (result)
        {
            case BudgetRuleEditorResult.Save:
                await _settings.UpsertRuleAsync(viewModel.Build());
                break;
            case BudgetRuleEditorResult.Delete when !viewModel.IsNew:
                await _settings.DeleteRuleAsync(viewModel.Build().Id);
                break;
        }

        RefreshEventsVisibility();
    }

    private BudgetRule? FindRule(string id)
    {
        foreach (BudgetRule rule in _settings.Rules)
        {
            if (rule.Id == id)
            {
                return rule;
            }
        }

        return null;
    }

    private void RefreshEventsVisibility()
    {
        bool hasEvents = _settings.RecentEventItems.Count > 0;
        EventsCardHost.Visibility = hasEvents ? Visibility.Visible : Visibility.Collapsed;
        NoEventsText.Visibility = hasEvents ? Visibility.Collapsed : Visibility.Visible;
    }

    // ── Preview (dev-host proof the reusable components render) ───────────────────

    private void LoadPreview()
    {
        var rule = new BudgetRule
        {
            Scope = BudgetRuleScope.Credential,
            ProviderId = "openrouter",
            AccountId = "slot-abc123",
            Label = "OpenRouter main",
            AmountUsd = 50,
            Period = BudgetPeriod.Month,
            Behavior = BudgetBehavior.WarnThenBlock,
        };

        var spend = new Dictionary<string, double> { [rule.Id] = 42 };
        PreviewChip.SetState(BurnRailBudgetChipModel.Compute(new[] { rule }, spend));

        var error = new BudgetBlockedError
        {
            Rule = rule,
            Used = 52.37,
            Limit = 50,
            ResetAt = System.DateTimeOffset.Now.AddDays(4),
        };
        PreviewBlockedCard.SetError(new BudgetBlockedCardModel(error));
    }

    private static IReadOnlyList<BudgetRule> SeedRules() => new List<BudgetRule>
    {
        new()
        {
            Scope = BudgetRuleScope.Global,
            Label = "All per-usage credentials",
            AmountUsd = 200,
            Period = BudgetPeriod.Month,
            Behavior = BudgetBehavior.WarnThenBlock,
        },
        new()
        {
            Scope = BudgetRuleScope.Credential,
            ProviderId = "openrouter",
            AccountId = "slot-abc123",
            Label = "OpenRouter main",
            AmountUsd = 50,
            Period = BudgetPeriod.Month,
            Behavior = BudgetBehavior.WarnThenBlock,
        },
        new()
        {
            Scope = BudgetRuleScope.Project,
            ProjectName = "burnbar",
            AmountUsd = 120,
            Period = BudgetPeriod.Month,
            Behavior = BudgetBehavior.HardBlock,
        },
    };
}
