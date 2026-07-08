using System;
using System.Linq;
using Microsoft.UI;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using OpenBurnBar.App.Presentation.DataControlCenter;
using Windows.UI;

namespace OpenBurnBar.App.DataControlCenter;

/// <summary>
/// The domain inspector pane. <see cref="Show"/> populates every section from the selected
/// <see cref="DomainRow"/> (header, flip, footprint, Pensieve caps, audit, paths, actions). Actions
/// raise events the host wires to the governance dialogs + export; the audit + verify buttons drive
/// the portable view-model directly.
/// </summary>
public sealed partial class DomainInspectorView : UserControl
{
    private DataControlCenterViewModel? _viewModel;
    private DomainRow? _row;

    public DomainInspectorView()
    {
        InitializeComponent();
    }

    /// <summary>Raised when the user asks to export the selected domain.</summary>
    public event EventHandler<DomainRow>? ExportRequested;

    /// <summary>Raised when the user opens recovery setup from the selected domain.</summary>
    public event EventHandler<DomainRow>? RecoverRequested;

    /// <summary>Raised when the user asks to delete the selected domain.</summary>
    public event EventHandler<DomainRow>? DeleteRequested;

    /// <summary>Populate the inspector for a selected domain row.</summary>
    public void Show(DataControlCenterViewModel viewModel, DomainRow row)
    {
        _viewModel = viewModel;
        _row = row;
        var domain = row.Domain;
        Color tint = TierDisplay.AccentColor(domain.EncryptionTier);

        // Header
        HeaderIcon.Glyph = DomainGlyphMap.Glyph(domain.Id);
        HeaderIconTile.Background = new SolidColorBrush(tint);
        HeaderTitle.Text = domain.Title;
        HeaderSummary.Text = domain.Summary;
        HeaderTierBadge.Background = new SolidColorBrush(Color.FromArgb(0x24, tint.R, tint.G, tint.B));
        HeaderTierBadge.BorderBrush = new SolidColorBrush(Color.FromArgb(0x66, tint.R, tint.G, tint.B));
        HeaderTierGlyph.Glyph = TierDisplay.Glyph(domain.EncryptionTier);
        HeaderTierGlyph.Foreground = new SolidColorBrush(tint);
        HeaderTierLabel.Text = TierDisplay.Label(domain.EncryptionTier);
        HeaderTierLabel.Foreground = new SolidColorBrush(tint);
        HeaderRetention.Text = TierDisplay.RetentionLabel(domain.Retention);

        // Flip
        Flip.SetDomain(domain);

        // Footprint
        FootprintCount.Text = row.Count.ToString(System.Globalization.CultureInfo.CurrentCulture);
        FootprintCountLabel.Text = CountLabel(domain);
        if (domain.ByteSource is not null)
        {
            FootprintBytesGroup.Visibility = Visibility.Visible;
            FootprintBytes.Text = DataControlFormat.Bytes(row.Bytes);
        }
        else
        {
            FootprintBytesGroup.Visibility = Visibility.Collapsed;
        }

        FootprintBar.Background = new SolidColorBrush(tint);

        // Pensieve caps
        if (domain.Id == "pensieve")
        {
            PensieveCard.Visibility = Visibility.Visible;
            var limits = viewModel.PensieveLimits;
            PensieveCaption.Text = $"Your {Capitalize(viewModel.Tier.RawValue())} plan caps Pensieve knowledge at these ceilings.";
            PensieveChunksValue.Text = $"{row.Count} / {limits.Chunks}";
            PensieveChunksBar.Value = Fraction(row.Count, limits.Chunks);
            PensieveStorageValue.Text = $"{DataControlFormat.Bytes(row.Bytes)} / {DataControlFormat.Bytes(limits.Bytes)}";
            PensieveStorageBar.Value = Fraction(row.Bytes, limits.Bytes);
        }
        else
        {
            PensieveCard.Visibility = Visibility.Collapsed;
        }

        // Audit
        if (domain.Id == "audit_timeline")
        {
            AuditCard.Visibility = Visibility.Visible;
            AuditList.ItemsSource = viewModel.AuditEvents;
            UpdateAuditState();
        }
        else
        {
            AuditCard.Visibility = Visibility.Collapsed;
        }

        // Paths
        CollectionsGroup.Visibility = domain.FirestorePaths.Count > 0 ? Visibility.Visible : Visibility.Collapsed;
        CollectionsChips.ItemsSource = domain.FirestorePaths.ToList();
        if (domain.StoragePaths.Count > 0)
        {
            StorageGroup.Visibility = Visibility.Visible;
            StorageChips.ItemsSource = domain.StoragePaths.ToList();
        }
        else
        {
            StorageGroup.Visibility = Visibility.Collapsed;
        }

        // Actions
        ExportButton.Visibility = domain.HasAction("export") ? Visibility.Visible : Visibility.Collapsed;
        RecoverButton.Visibility = domain.HasAction("recover") ? Visibility.Visible : Visibility.Collapsed;
        DeleteButton.Visibility = domain.HasAction("delete") ? Visibility.Visible : Visibility.Collapsed;
    }

    private static string CountLabel(DataDomain domain) =>
        domain.CountSource is { } source ? source.Replace('_', ' ') : "Records";

    private static double Fraction(long used, long limit) =>
        limit > 0 ? Math.Min(1.0, (double)used / limit) : 0;

    private static string Capitalize(string value) =>
        string.IsNullOrEmpty(value) ? value : char.ToUpper(value[0], System.Globalization.CultureInfo.InvariantCulture) + value.Substring(1);

    private async void OnVerifyClick(object sender, RoutedEventArgs e)
    {
        if (_viewModel is null)
        {
            return;
        }

        await _viewModel.VerifyAuditLogAsync();
        UpdateAuditState();
    }

    private void UpdateAuditState()
    {
        if (_viewModel is null)
        {
            return;
        }

        AuditEmpty.Visibility = _viewModel.AuditEvents.Count == 0 ? Visibility.Visible : Visibility.Collapsed;

        if (_viewModel.AuditVerification is { } verification)
        {
            if (verification.Valid)
            {
                VerifyResult.Text = "Intact";
                VerifyResult.Foreground = new SolidColorBrush(Color.FromArgb(0xFF, 0x4C, 0xC9, 0x8A));
            }
            else
            {
                VerifyResult.Text = $"Broken at {verification.BrokenAt ?? -1}";
                VerifyResult.Foreground = new SolidColorBrush(TierDisplay.AccentColor(EncryptionTier.ServerReadable));
            }
        }
        else
        {
            VerifyResult.Text = string.Empty;
        }
    }

    private void OnExportClick(object sender, RoutedEventArgs e)
    {
        if (_row is { } row)
        {
            ExportRequested?.Invoke(this, row);
        }
    }

    private void OnRecoverClick(object sender, RoutedEventArgs e)
    {
        if (_row is { } row)
        {
            RecoverRequested?.Invoke(this, row);
        }
    }

    private void OnDeleteClick(object sender, RoutedEventArgs e)
    {
        if (_row is { } row)
        {
            DeleteRequested?.Invoke(this, row);
        }
    }
}
