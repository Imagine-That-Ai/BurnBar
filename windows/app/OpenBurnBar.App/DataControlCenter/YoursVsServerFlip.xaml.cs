using System;
using System.Collections.Generic;
using System.Linq;
using Microsoft.UI;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using OpenBurnBar.App.Presentation.DataControlCenter;
using Windows.UI;

namespace OpenBurnBar.App.DataControlCenter;

/// <summary>
/// The yours↔server flip card. Bound to a <see cref="DataDomain"/>; toggling a pill flips the face
/// (PlaneProjection RotationY) between the sealed "stays yours" facets and the "server sees"
/// facets. A purely server-readable domain has no device-only facets, so the "yours" pill is
/// suppressed and the card defaults to the server face — parity with the Swift <c>hasYoursFace</c>.
/// </summary>
public sealed partial class YoursVsServerFlip : UserControl
{
    private DataDomain? _domain;
    private bool _showingServer;

    public YoursVsServerFlip()
    {
        InitializeComponent();
        FlipOut.Completed += OnFlipOutCompleted;
    }

    /// <summary>Bind (or rebind) the domain and reset to its default face.</summary>
    public void SetDomain(DataDomain domain)
    {
        _domain = domain;
        _showingServer = !HasYoursFace(domain); // no device-only facets → default to server face
        FaceProjection.RotationY = 0;
        RenderFace();
        UpdatePills();
    }

    private static bool HasYoursFace(DataDomain domain) => domain.DeviceOnly.Count > 0;

    private void OnYoursClick(object sender, RoutedEventArgs e) => Flip(toServer: false);

    private void OnServerClick(object sender, RoutedEventArgs e) => Flip(toServer: true);

    private void Flip(bool toServer)
    {
        if (_domain is null || _showingServer == toServer)
        {
            return;
        }

        if (!toServer && !HasYoursFace(_domain))
        {
            return; // the "yours" pill is disabled for server-readable-only domains
        }

        _showingServer = toServer;
        UpdatePills();
        FlipOut.Begin();
    }

    private void OnFlipOutCompleted(object? sender, object e)
    {
        // Half-way through the flip: swap the face content, then rotate the back in.
        RenderFace();
        FaceProjection.RotationY = -90;
        FlipIn.Begin();
    }

    private void RenderFace()
    {
        if (_domain is null)
        {
            return;
        }

        bool sealedFace = !_showingServer;
        Color accent = sealedFace
            ? TierDisplay.AccentColor(EncryptionTier.EndToEnd)
            : TierDisplay.AccentColor(_domain.EncryptionTier);

        FaceGlyph.Glyph = sealedFace ? "" : ""; // Shield vs RedEye
        FaceGlyph.Foreground = new SolidColorBrush(accent);
        FaceTitle.Text = sealedFace ? "Stays on your device" : "What the server can read";
        FaceSubtitle.Text = TierDisplay.Explanation(_domain.EncryptionTier);
        FaceCard.BorderBrush = new SolidColorBrush(Color.FromArgb(sealedFace ? (byte)0x73 : (byte)0x4C, accent.R, accent.G, accent.B));

        IReadOnlyList<string> facets = sealedFace ? _domain.DeviceOnly : _domain.ServerSees;
        if (facets.Count == 0)
        {
            FaceChips.ItemsSource = null;
            FaceChips.Visibility = Visibility.Collapsed;
            FaceEmpty.Visibility = Visibility.Visible;
            FaceEmpty.Text = sealedFace
                ? "Nothing here stays device-only."
                : "The server stores no readable facets for this domain.";
        }
        else
        {
            FaceEmpty.Visibility = Visibility.Collapsed;
            FaceChips.Visibility = Visibility.Visible;
            FaceChips.ItemsSource = facets.ToList();
        }
    }

    private void UpdatePills()
    {
        bool yoursEnabled = _domain is not null && HasYoursFace(_domain);
        YoursPill.IsEnabled = yoursEnabled;
        YoursPill.Opacity = yoursEnabled ? 1 : 0.4;

        Color yoursTint = TierDisplay.AccentColor(EncryptionTier.EndToEnd);
        Color serverTint = _domain is null
            ? TierDisplay.AccentColor(EncryptionTier.ServerReadable)
            : TierDisplay.AccentColor(_domain.EncryptionTier);

        ApplyPill(YoursPill, YoursPillGlyph, selected: !_showingServer, tint: yoursTint);
        ApplyPill(ServerPill, ServerPillGlyph, selected: _showingServer, tint: serverTint);
    }

    private static void ApplyPill(Button pill, FontIcon glyph, bool selected, Color tint)
    {
        pill.Background = selected ? new SolidColorBrush(tint) : new SolidColorBrush(Colors.Transparent);
        var foreground = new SolidColorBrush(selected ? Colors.White : Color.FromArgb(0x8C, 0xFF, 0xFF, 0xFF));
        pill.Foreground = foreground;
        glyph.Foreground = foreground;
    }
}
