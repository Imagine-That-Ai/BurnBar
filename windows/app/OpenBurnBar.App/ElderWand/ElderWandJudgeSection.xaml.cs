using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using OpenBurnBar.App.Presentation.ElderWand;

namespace OpenBurnBar.App.ElderWand;

/// <summary>
/// The Elder Wand judge rail (Windows). Renders an <see cref="ElderWandChipCloudViewModel"/> in
/// <see cref="ElderWandCloudMode.Judge"/> mode — single-select, route-eligibility gated. The
/// selection logic is portable + unit-tested on macOS; this control is its WinUI render. The
/// container calls <see cref="SetCloud"/> once the live catalog is resolved.
/// </summary>
public sealed partial class ElderWandJudgeSection : UserControl
{
    public ElderWandJudgeSection()
    {
        InitializeComponent();
    }

    /// <summary>The judge-mode chip cloud this control renders. Set via <see cref="SetCloud"/>.</summary>
    public ElderWandChipCloudViewModel? Cloud { get; private set; }

    /// <summary>Bind the judge cloud, then refresh the compiled bindings.</summary>
    public void SetCloud(ElderWandChipCloudViewModel cloud)
    {
        Cloud = cloud;
        Bindings.Update();
    }

    private void OnChipClick(object sender, RoutedEventArgs e)
    {
        if (Cloud is not null && sender is FrameworkElement element && element.Tag is ElderWandChip chip)
        {
            Cloud.Toggle(chip);
        }
    }
}
