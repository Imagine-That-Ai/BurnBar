using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using OpenBurnBar.App.Presentation.ElderWand;

namespace OpenBurnBar.App.ElderWand;

/// <summary>
/// The Elder Wand analysis panel (Windows). Renders an <see cref="ElderWandChipCloudViewModel"/>
/// in <see cref="ElderWandCloudMode.Analysis"/> mode and shows the live "N of 8" counter off the
/// shared <see cref="ElderWandConfiguratorModel"/>. Both are portable + unit-tested on macOS;
/// this control is their WinUI render. The container calls <see cref="SetContext"/> once the live
/// catalog is resolved.
/// </summary>
public sealed partial class ElderWandAnalysisSection : UserControl
{
    public ElderWandAnalysisSection()
    {
        InitializeComponent();
    }

    /// <summary>The shared edit buffer (drives the header counter). Set via <see cref="SetContext"/>.</summary>
    public ElderWandConfiguratorModel? Editor { get; private set; }

    /// <summary>The analysis-mode chip cloud this control renders. Set via <see cref="SetContext"/>.</summary>
    public ElderWandChipCloudViewModel? Cloud { get; private set; }

    /// <summary>Bind the edit buffer + analysis cloud, then refresh the compiled bindings.</summary>
    public void SetContext(ElderWandConfiguratorModel editor, ElderWandChipCloudViewModel cloud)
    {
        Editor = editor;
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
