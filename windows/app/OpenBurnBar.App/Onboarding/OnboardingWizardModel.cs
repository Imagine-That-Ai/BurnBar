// PORTED (portable, unit-tested) from AgentLens/Views/Onboarding/OnboardingWizardView.swift
//   struct OnboardingWizardView — the @State step machine + navigate/canContinue/finalize.
//
// This is the dependency-free (System-only, NO WinUI) state machine that the
// WinUI OnboardingPage binds to. Every navigation/gating/completion rule the
// SwiftUI view expressed inline lives here so it is unit-testable off-Windows
// via a real `dotnet test` — the WinUI page is pure presentation over this model,
// exactly the seam the master plan calls for (view-models are portable + tested;
// XAML is the Windows-only shell verified to the XamlCompiler gate).

using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.Linq;
using System.Runtime.CompilerServices;
using OpenBurnBar.App.Theme;

namespace OpenBurnBar.App.Onboarding;

/// <summary>The persisted outcome of the wizard — what <c>finalize()</c> writes back to
/// settings + the chat controller on macOS. Returned so the (Windows-only) host can apply
/// it to real settings while the decision logic stays portable + tested.</summary>
public sealed class OnboardingCompletionResult
{
    /// <summary>Selected providers, to persist as the tracked set.</summary>
    public IReadOnlyList<AgentProviderBrand> SelectedProviders { get; init; } =
        Array.Empty<AgentProviderBrand>();

    /// <summary>Enabled chat backends in <see cref="ChatBackendMetadata.AllCases"/> order.
    /// Empty when the user enabled none (then <see cref="StartEngine"/> is <c>null</c>).</summary>
    public IReadOnlyList<ChatBackendId> OrderedBackends { get; init; } =
        Array.Empty<ChatBackendId>();

    /// <summary>The engine to make active: the default engine if still enabled, else the
    /// first enabled backend. Swift: <c>ordered.contains(defaultEngine) ? defaultEngine :
    /// ordered[0]</c>. <c>null</c> when no backend is enabled (leave current engine).</summary>
    public ChatBackendId? StartEngine { get; init; }
}

/// <summary>
/// The portable state machine behind the first-run onboarding wizard. Holds the same
/// state the SwiftUI <c>OnboardingWizardView</c> held in <c>@State</c> and exposes the
/// same navigation, gating, and completion rules — with zero WinUI/UI-framework
/// dependency so it runs under <c>dotnet test</c> on any host.
/// </summary>
public sealed class OnboardingWizardModel : INotifyPropertyChanged
{
    /// <summary>Number of sub-pages in the Tour step (Swift: <c>Self.pages.count</c> = 4,
    /// paginated 0..3). Continue on the Tour advances the sub-page until the last.</summary>
    public const int TourPageCount = 4;

    private readonly HashSet<AgentProviderBrand> _selectedProviders = new();
    private readonly HashSet<AgentProviderBrand> _detectedProviders = new();
    private readonly HashSet<ChatBackendId> _enabledBackends = new();

    private OnboardingWizardStep _currentStep = OnboardingWizardStep.Providers;
    private ChatBackendId _defaultEngine = ChatBackendId.Codex;
    private int _tourPage;
    private bool _isScanning;
    private bool _systemPermissionsResolved;
    private bool _hasOnboarded;
    private OnboardingNavigationDirection _lastNavigationDirection = OnboardingNavigationDirection.Forward;

    // MARK: - Step state

    /// <summary>The current wizard step. Swift <c>@State currentStep</c>.</summary>
    public OnboardingWizardStep CurrentStep
    {
        get => _currentStep;
        private set
        {
            if (_currentStep != value)
            {
                _currentStep = value;
                OnPropertyChanged();
                OnPropertyChanged(nameof(ProgressFraction));
                OnPropertyChanged(nameof(CanContinue));
                OnPropertyChanged(nameof(ContinueLabel));
                OnPropertyChanged(nameof(ShowsFooter));
                OnPropertyChanged(nameof(ShowsBackButton));
                OnPropertyChanged(nameof(ShowsSkipButton));
            }
        }
    }

    /// <summary>Progress bar fill 0..1 for the current step.</summary>
    public double ProgressFraction => _currentStep.ProgressFraction();

    /// <summary>Which edge the pending step transition slides from (Frame slide info).</summary>
    public OnboardingNavigationDirection LastNavigationDirection => _lastNavigationDirection;

    /// <summary>Current Tour sub-page (0..<see cref="TourPageCount"/>-1).</summary>
    public int TourPage
    {
        get => _tourPage;
        private set
        {
            int clamped = Math.Clamp(value, 0, TourPageCount - 1);
            if (_tourPage != clamped)
            {
                _tourPage = clamped;
                OnPropertyChanged();
                OnPropertyChanged(nameof(ContinueLabel));
            }
        }
    }

    /// <summary>Whether the aggregator is still parsing (drives the Scan step's gate +
    /// label). Swift: <c>aggregator?.isRefreshing</c>. Set by the host as scanning runs.</summary>
    public bool IsScanning
    {
        get => _isScanning;
        set
        {
            if (_isScanning != value)
            {
                _isScanning = value;
                OnPropertyChanged();
                OnPropertyChanged(nameof(CanContinue));
                OnPropertyChanged(nameof(ContinueLabel));
            }
        }
    }

    /// <summary>Whether all system-permission grants are resolved (drives the
    /// SystemPermissions Continue label). Swift: <c>permissionsCoordinator.allResolved</c>.</summary>
    public bool SystemPermissionsResolved
    {
        get => _systemPermissionsResolved;
        set
        {
            if (_systemPermissionsResolved != value)
            {
                _systemPermissionsResolved = value;
                OnPropertyChanged();
                OnPropertyChanged(nameof(ContinueLabel));
            }
        }
    }

    /// <summary>Set once the wizard finalizes. Swift <c>@AppStorage("hasOnboarded")</c>.</summary>
    public bool HasOnboarded
    {
        get => _hasOnboarded;
        private set
        {
            if (_hasOnboarded != value)
            {
                _hasOnboarded = value;
                OnPropertyChanged();
            }
        }
    }

    // MARK: - Selection state

    /// <summary>Providers detected on this machine (input). Drives pre-selection,
    /// detected-first ordering, and the "Select all detected" affordance.</summary>
    public IReadOnlyCollection<AgentProviderBrand> DetectedProviders => _detectedProviders;

    /// <summary>The user's selected providers. Swift <c>@State selectedProviders</c>.</summary>
    public IReadOnlyCollection<AgentProviderBrand> SelectedProviders => _selectedProviders;

    /// <summary>Enabled chat backends (unordered set; render via <see cref="OrderedEnabledBackends"/>).
    /// Swift <c>@State enabledBackends</c>.</summary>
    public IReadOnlyCollection<ChatBackendId> EnabledBackends => _enabledBackends;

    /// <summary>Enabled backends in canonical order. Swift:
    /// <c>ChatBackendID.allCases.filter { enabledBackends.contains($0) }</c>.</summary>
    public IReadOnlyList<ChatBackendId> OrderedEnabledBackends =>
        ChatBackendMetadata.AllCases.Where(_enabledBackends.Contains).ToList();

    /// <summary>The default engine among enabled backends. Swift <c>@State defaultEngine</c>.</summary>
    public ChatBackendId DefaultEngine
    {
        get => _defaultEngine;
        set
        {
            if (_defaultEngine != value)
            {
                _defaultEngine = value;
                OnPropertyChanged();
            }
        }
    }

    // MARK: - Seeding (onAppear)

    /// <summary>Record which providers were detected on this machine.</summary>
    public void SetDetectedProviders(IEnumerable<AgentProviderBrand> detected)
    {
        _detectedProviders.Clear();
        foreach (AgentProviderBrand provider in detected)
        {
            _detectedProviders.Add(provider);
        }
    }

    /// <summary>Pre-select every detected provider. Swift onAppear:
    /// <c>for (provider, found) in detection where found { selectedProviders.insert(provider) }</c>.</summary>
    public void PreselectDetectedProviders()
    {
        bool changed = false;
        foreach (AgentProviderBrand provider in _detectedProviders)
        {
            changed |= _selectedProviders.Add(provider);
        }

        if (changed)
        {
            RaiseSelectionChanged();
        }
    }

    /// <summary>Seed the enabled backends + default engine (existing settings).
    /// Swift onAppear: pre-load <c>enabledChatBackends</c> + current <c>chatBackend</c>.</summary>
    public void SeedChatBackends(IEnumerable<ChatBackendId> existingEnabled, ChatBackendId? currentEngine)
    {
        _enabledBackends.Clear();
        foreach (ChatBackendId backend in existingEnabled)
        {
            _enabledBackends.Add(backend);
        }

        if (currentEngine is { } engine)
        {
            _defaultEngine = engine;
        }

        OnPropertyChanged(nameof(EnabledBackends));
        OnPropertyChanged(nameof(OrderedEnabledBackends));
        OnPropertyChanged(nameof(DefaultEngine));
    }

    // MARK: - Provider selection

    /// <summary>Whether a provider is currently selected.</summary>
    public bool IsProviderSelected(AgentProviderBrand provider) => _selectedProviders.Contains(provider);

    /// <summary>Whether a provider was detected on this machine.</summary>
    public bool IsProviderDetected(AgentProviderBrand provider) => _detectedProviders.Contains(provider);

    /// <summary>Toggle a provider's selection. Swift: the pill's onTap insert/remove.</summary>
    public void ToggleProvider(AgentProviderBrand provider)
    {
        if (!_selectedProviders.Remove(provider))
        {
            _selectedProviders.Add(provider);
        }

        RaiseSelectionChanged();
    }

    /// <summary>Select every detected provider. Swift: "Select all detected (n)".</summary>
    public void SelectAllDetected()
    {
        bool changed = false;
        foreach (AgentProviderBrand provider in _detectedProviders)
        {
            changed |= _selectedProviders.Add(provider);
        }

        if (changed)
        {
            RaiseSelectionChanged();
        }
    }

    /// <summary>
    /// Providers in detected-first order: detected sorted by name, then the rest sorted by
    /// name. Swift <c>sortedProviders</c>. Names come from the injected <paramref name="displayName"/>
    /// so this stays free of any UI display table.
    /// </summary>
    public IReadOnlyList<AgentProviderBrand> SortedProviders(Func<AgentProviderBrand, string> displayName)
    {
        if (displayName is null)
        {
            throw new ArgumentNullException(nameof(displayName));
        }

        AgentProviderBrand[] all = Enum.GetValues<AgentProviderBrand>();
        IEnumerable<AgentProviderBrand> detected = all
            .Where(_detectedProviders.Contains)
            .OrderBy(displayName, StringComparer.Ordinal);
        IEnumerable<AgentProviderBrand> rest = all
            .Where(p => !_detectedProviders.Contains(p))
            .OrderBy(displayName, StringComparer.Ordinal);
        return detected.Concat(rest).ToList();
    }

    // MARK: - Chat backend selection

    /// <summary>
    /// Enable/disable a chat backend. Swift: the per-backend Toggle setter, including its
    /// side effect — if the default engine is no longer enabled, reassign it to the first
    /// remaining enabled backend (or <see cref="ChatBackendId.Codex"/> when none remain).
    /// </summary>
    public void SetBackendEnabled(ChatBackendId backend, bool enabled)
    {
        bool changed = enabled ? _enabledBackends.Add(backend) : _enabledBackends.Remove(backend);
        if (!changed)
        {
            return;
        }

        IReadOnlyList<ChatBackendId> ordered = OrderedEnabledBackends;
        if (!ordered.Contains(_defaultEngine))
        {
            DefaultEngine = ordered.Count > 0 ? ordered[0] : ChatBackendId.Codex;
        }

        OnPropertyChanged(nameof(EnabledBackends));
        OnPropertyChanged(nameof(OrderedEnabledBackends));
    }

    /// <summary>Whether a backend is enabled.</summary>
    public bool IsBackendEnabled(ChatBackendId backend) => _enabledBackends.Contains(backend);

    // MARK: - Footer chrome

    /// <summary>Footer is hidden on the Complete step (it has its own buttons). Swift:
    /// <c>if currentStep != .complete { footer }</c>.</summary>
    public bool ShowsFooter => _currentStep != OnboardingWizardStep.Complete;

    /// <summary>Back is shown on every step after Providers. Swift:
    /// <c>if currentStep != .providers { Back }</c>.</summary>
    public bool ShowsBackButton =>
        ShowsFooter && _currentStep != OnboardingWizardStep.Providers;

    /// <summary>Skip is hidden on the Scan step. Swift: <c>if currentStep != .scan { Skip }</c>.</summary>
    public bool ShowsSkipButton =>
        ShowsFooter && _currentStep != OnboardingWizardStep.Scan;

    /// <summary>Whether the Continue button is enabled. Swift <c>canContinue</c>.</summary>
    public bool CanContinue => _currentStep switch
    {
        OnboardingWizardStep.Providers => _selectedProviders.Count > 0,
        OnboardingWizardStep.Scan => !_isScanning,
        _ => true,
    };

    /// <summary>The Continue button's label for the current step. Swift <c>continueLabel</c>.</summary>
    public string ContinueLabel => _currentStep switch
    {
        OnboardingWizardStep.Providers => "Continue",
        OnboardingWizardStep.Connect => "Scan",
        OnboardingWizardStep.Scan => _isScanning ? "Scanning…" : "Continue",
        OnboardingWizardStep.Tour => _tourPage < TourPageCount - 1 ? "Next" : "Continue",
        OnboardingWizardStep.SystemPermissions =>
            _systemPermissionsResolved ? "Continue" : "Continue (set up later)",
        OnboardingWizardStep.ChatEngine => "Finish",
        _ => string.Empty,
    };

    // MARK: - Navigation

    /// <summary>
    /// Advance. On the Tour step this first walks the sub-pages (0→3) before advancing to
    /// the next step. Otherwise it moves to the next step. No-op past Complete. Swift
    /// <c>navigateForward()</c>. Returns <c>true</c> if anything changed.
    /// </summary>
    public bool NavigateForward()
    {
        if (_currentStep == OnboardingWizardStep.Tour && _tourPage < TourPageCount - 1)
        {
            TourPage = _tourPage + 1;
            return true;
        }

        OnboardingWizardStep? next = _currentStep.Next();
        if (next is null)
        {
            return false;
        }

        _lastNavigationDirection = OnboardingNavigationDirection.Forward;
        OnPropertyChanged(nameof(LastNavigationDirection));
        CurrentStep = next.Value;
        return true;
    }

    /// <summary>
    /// Go back. On the Tour step this first walks the sub-pages (3→0) before stepping back.
    /// No-op before Providers. Swift <c>navigateBack()</c>. Returns <c>true</c> if changed.
    /// </summary>
    public bool NavigateBack()
    {
        if (_currentStep == OnboardingWizardStep.Tour && _tourPage > 0)
        {
            TourPage = _tourPage - 1;
            return true;
        }

        OnboardingWizardStep? prev = _currentStep.Previous();
        if (prev is null)
        {
            return false;
        }

        _lastNavigationDirection = OnboardingNavigationDirection.Backward;
        OnPropertyChanged(nameof(LastNavigationDirection));
        CurrentStep = prev.Value;
        return true;
    }

    // MARK: - Completion

    /// <summary>
    /// Persist the wizard's outcome and mark onboarding complete. Swift <c>finalize()</c>:
    /// resolves the ordered enabled backends + the start engine, then sets
    /// <see cref="HasOnboarded"/>. The (Windows-only) host applies the returned result to
    /// real settings + the chat controller.
    /// </summary>
    public OnboardingCompletionResult Finalize()
    {
        IReadOnlyList<ChatBackendId> ordered = OrderedEnabledBackends;
        ChatBackendId? startEngine = null;
        if (ordered.Count > 0)
        {
            startEngine = ordered.Contains(_defaultEngine) ? _defaultEngine : ordered[0];
        }

        HasOnboarded = true;

        return new OnboardingCompletionResult
        {
            SelectedProviders = _selectedProviders.ToList(),
            OrderedBackends = ordered,
            StartEngine = startEngine,
        };
    }

    private void RaiseSelectionChanged()
    {
        OnPropertyChanged(nameof(SelectedProviders));
        OnPropertyChanged(nameof(CanContinue));
    }

    public event PropertyChangedEventHandler? PropertyChanged;

    private void OnPropertyChanged([CallerMemberName] string? name = null) =>
        PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(name));
}
