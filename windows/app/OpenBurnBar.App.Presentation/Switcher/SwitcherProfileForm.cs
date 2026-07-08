using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.Linq;
using System.Runtime.CompilerServices;

namespace OpenBurnBar.App.Presentation.Switcher;

// PORTED (faithful) from the create/edit form state + logic in
// AgentLens/Views/Settings/AccountSwitcher/AccountSwitcherSettingsView+DataOperations.swift
//   • resetForm() / editProfile() — form state seed
//   • validateForm(excludingID:) — VAL-SETTINGS-011 target-specific + duplicate-name checks
//   • buildProfileRecord(id:) — create-record construction (arg/env parsing)
//   • saveProfileAsync(original:) — update-record construction (original fields preserved)
// and the bindings in AccountSwitcherProfileFormView.swift.
//
// This is the two-way-bindable form model the WinUI ProfileFormDialog x:Binds, plus the
// pure validation + record builders that the create/edit paths run. Unit-tested on macOS.

/// <summary>Outcome of <see cref="SwitcherProfileForm.Validate"/>. Swift returns a Bool and
/// sets <c>editFormValidationError</c> / <c>editFormDuplicateError</c>; this bundles both.</summary>
public sealed record SwitcherFormValidationResult(
    bool IsValid,
    string? ValidationError,
    string? DuplicateError)
{
    public static readonly SwitcherFormValidationResult Valid = new(true, null, null);
}

/// <summary>
/// Editable create/edit form. Swift <c>editForm*</c> @State + the form bindings. Two-way
/// bindable (INotifyPropertyChanged) for the WinUI dialog; plain properties for tests.
/// </summary>
public sealed class SwitcherProfileForm : INotifyPropertyChanged
{
    private string _name = string.Empty;
    private SwitcherProfileTargetKind _targetKind = SwitcherProfileTargetKind.Browser;
    private SwitcherBrowserProfileType _browserType = SwitcherBrowserProfileType.Chrome;
    private SwitcherCLIProfileType _cliType = SwitcherCLIProfileType.Claude;
    private string _profileIdentifier = string.Empty;
    private string _workingDirectory = string.Empty;
    private string _additionalArgs = string.Empty;
    private string _envKeys = string.Empty;
    private string? _validationError;
    private string? _duplicateError;

    public string Name { get => _name; set => Set(ref _name, value ?? string.Empty); }

    public SwitcherProfileTargetKind TargetKind
    {
        get => _targetKind;
        set { if (Set(ref _targetKind, value)) { OnPropertyChanged(nameof(IsBrowser)); OnPropertyChanged(nameof(IsCli)); } }
    }

    public SwitcherBrowserProfileType BrowserType { get => _browserType; set => Set(ref _browserType, value); }

    public SwitcherCLIProfileType CliType { get => _cliType; set => Set(ref _cliType, value); }

    public string ProfileIdentifier { get => _profileIdentifier; set => Set(ref _profileIdentifier, value ?? string.Empty); }

    public string WorkingDirectory { get => _workingDirectory; set => Set(ref _workingDirectory, value ?? string.Empty); }

    public string AdditionalArgs { get => _additionalArgs; set => Set(ref _additionalArgs, value ?? string.Empty); }

    public string EnvKeys { get => _envKeys; set => Set(ref _envKeys, value ?? string.Empty); }

    public string? ValidationError { get => _validationError; private set => Set(ref _validationError, value); }

    public string? DuplicateError { get => _duplicateError; private set => Set(ref _duplicateError, value); }

    /// <summary>Swift: <c>targetKind == .browser</c>.</summary>
    public bool IsBrowser => _targetKind == SwitcherProfileTargetKind.Browser;

    /// <summary>Swift: <c>targetKind == .cli</c>.</summary>
    public bool IsCli => _targetKind == SwitcherProfileTargetKind.Cli;

    /// <summary>Reset to defaults. Swift: <c>resetForm()</c>.</summary>
    public void Reset()
    {
        Name = string.Empty;
        TargetKind = SwitcherProfileTargetKind.Browser;
        BrowserType = SwitcherBrowserProfileType.Chrome;
        CliType = SwitcherCLIProfileType.Claude;
        ProfileIdentifier = string.Empty;
        WorkingDirectory = string.Empty;
        AdditionalArgs = string.Empty;
        EnvKeys = string.Empty;
        ValidationError = null;
        DuplicateError = null;
    }

    /// <summary>Seed the form from an existing profile. Swift: <c>editProfile(_:)</c>.</summary>
    public static SwitcherProfileForm LoadFrom(SwitcherProfileRecord profile)
    {
        var form = new SwitcherProfileForm
        {
            Name = profile.DisplayName,
            TargetKind = profile.TargetKind,
            BrowserType = profile.BrowserType ?? SwitcherBrowserProfileType.Chrome,
            CliType = profile.CliType ?? SwitcherCLIProfileType.Claude,
            ProfileIdentifier = profile.BrowserMetadata?.ProfileIdentifier ?? string.Empty,
            WorkingDirectory = profile.CliMetadata?.WorkingDirectory ?? string.Empty,
            AdditionalArgs = profile.CliMetadata is { } cli ? string.Join(" ", cli.AdditionalArgs) : string.Empty,
            EnvKeys = profile.CliMetadata is { } cli2 ? string.Join(", ", cli2.EnvKeysToPass) : string.Empty,
        };
        form.ValidationError = null;
        form.DuplicateError = null;
        return form;
    }

    /// <summary>
    /// Validate + populate error fields. Swift: <c>validateForm(excludingID:)</c>. The caller
    /// supplies the OTHER profiles' display names (Swift's <c>existsProfileWithNormalizedName</c>
    /// with <c>excludingID</c> applied); a normalized-name collision is a duplicate.
    /// </summary>
    public SwitcherFormValidationResult Validate(IEnumerable<string> otherProfileDisplayNames)
    {
        ValidationError = null;
        DuplicateError = null;

        if (!string.IsNullOrEmpty(Name))
        {
            var normalized = SwitcherProfileRecord.NormalizeName(Name);
            var collision = (otherProfileDisplayNames ?? Enumerable.Empty<string>())
                .Any(other => SwitcherProfileRecord.NormalizeName(other) == normalized);
            if (collision)
            {
                DuplicateError = "A profile with this name already exists";
                return new SwitcherFormValidationResult(false, null, DuplicateError);
            }
        }

        if (TargetKind == SwitcherProfileTargetKind.Browser && string.IsNullOrEmpty(ProfileIdentifier))
        {
            ValidationError = "Profile identifier is required";
            return new SwitcherFormValidationResult(false, ValidationError, null);
        }

        return SwitcherFormValidationResult.Valid;
    }

    /// <summary>Build a fresh record from the form. Swift: <c>buildProfileRecord(id:)</c>.</summary>
    public SwitcherProfileRecord BuildNewRecord(string id, DateTimeOffset now)
    {
        if (TargetKind == SwitcherProfileTargetKind.Browser)
        {
            return new SwitcherProfileRecord(
                Id: id,
                TargetKind: SwitcherProfileTargetKind.Browser,
                SortKey: 0,
                BrowserType: BrowserType,
                BrowserMetadata: new SwitcherBrowserProfileMetadata(
                    ProfileIdentifier: ProfileIdentifier,
                    DisplayLabel: NullIfEmpty(Name)),
                CreatedAt: now,
                UpdatedAt: now);
        }

        return new SwitcherProfileRecord(
            Id: id,
            TargetKind: SwitcherProfileTargetKind.Cli,
            SortKey: 0,
            CliType: CliType,
            CliMetadata: new SwitcherCLIProfileMetadata(
                WorkingDirectory: NullIfEmpty(WorkingDirectory),
                AdditionalArgs: ParseArgs(AdditionalArgs),
                EnvKeysToPass: ParseEnvKeys(EnvKeys),
                DisplayLabel: NullIfEmpty(Name)),
            CreatedAt: now,
            UpdatedAt: now);
    }

    /// <summary>
    /// Build the updated record, preserving fields the form does not edit. Swift:
    /// <c>saveProfileAsync(original:)</c> (browser: account email / provider id / services /
    /// disabled; CLI: config dir, account, provider/runtime/tier/capability, harnesses,
    /// quota-exhaustion + disabled state — all carried from <paramref name="original"/>).
    /// </summary>
    public SwitcherProfileRecord BuildUpdatedRecord(SwitcherProfileRecord original, DateTimeOffset now)
    {
        if (TargetKind == SwitcherProfileTargetKind.Browser)
        {
            return original with
            {
                TargetKind = SwitcherProfileTargetKind.Browser,
                BrowserType = BrowserType,
                BrowserMetadata = new SwitcherBrowserProfileMetadata(
                    ProfileIdentifier: ProfileIdentifier,
                    DisplayLabel: NullIfEmpty(Name),
                    AccountEmail: original.BrowserMetadata?.AccountEmail,
                    ProviderIdentifier: original.BrowserMetadata?.ProviderIdentifier,
                    ServiceIdentities: original.BrowserMetadata?.ServiceIdentities,
                    IsDisabled: original.BrowserMetadata?.IsDisabled ?? false),
                CliType = null,
                CliMetadata = null,
                UpdatedAt = now,
            };
        }

        var originalCli = original.CliMetadata;
        return original with
        {
            TargetKind = SwitcherProfileTargetKind.Cli,
            CliType = CliType,
            CliMetadata = new SwitcherCLIProfileMetadata(
                WorkingDirectory: NullIfEmpty(WorkingDirectory),
                AdditionalArgs: ParseArgs(AdditionalArgs),
                EnvKeysToPass: ParseEnvKeys(EnvKeys),
                DisplayLabel: NullIfEmpty(Name),
                ConfigDirectory: originalCli?.ConfigDirectory,
                AccountDescription: originalCli?.AccountDescription,
                ProviderId: originalCli?.ProviderId,
                RuntimeAccountId: originalCli?.RuntimeAccountId,
                SubscriptionTierId: originalCli?.SubscriptionTierId,
                ModelCapabilityClassId: originalCli?.ModelCapabilityClassId,
                LinkedHarnessIds: originalCli?.LinkedHarnessIds,
                NeverAutoSwitch: originalCli?.NeverAutoSwitch ?? false,
                LastQuotaExhaustedAt: originalCli?.LastQuotaExhaustedAt,
                ExhaustedUntil: originalCli?.ExhaustedUntil,
                LastQuotaExhaustionDetail: originalCli?.LastQuotaExhaustionDetail,
                IsDisabled: originalCli?.IsDisabled ?? false),
            BrowserType = null,
            BrowserMetadata = null,
            UpdatedAt = now,
        };
    }

    /// <summary>Swift: <c>additionalArgs.split(separator: " ").map(String.init)</c> (empty → []).</summary>
    public static IReadOnlyList<string> ParseArgs(string raw) =>
        string.IsNullOrEmpty(raw)
            ? Array.Empty<string>()
            : raw.Split(' ', StringSplitOptions.RemoveEmptyEntries);

    /// <summary>Swift: <c>envKeys.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }</c>.</summary>
    public static IReadOnlyList<string> ParseEnvKeys(string raw) =>
        string.IsNullOrEmpty(raw)
            ? Array.Empty<string>()
            : raw.Split(',', StringSplitOptions.RemoveEmptyEntries).Select(s => s.Trim()).ToArray();

    private static string? NullIfEmpty(string value) => string.IsNullOrEmpty(value) ? null : value;

    public event PropertyChangedEventHandler? PropertyChanged;

    private bool Set<T>(ref T field, T value, [CallerMemberName] string? name = null)
    {
        if (EqualityComparer<T>.Default.Equals(field, value))
        {
            return false;
        }

        field = value;
        OnPropertyChanged(name);
        return true;
    }

    private void OnPropertyChanged([CallerMemberName] string? name = null) =>
        PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(name));
}
