using System.Threading.Tasks;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;

namespace OpenBurnBar.App.Memory;

/// <summary>
/// First-run memory-extraction consent (Windows). Windows analog of the macOS
/// <c>MemoryConsentSheet</c>. Reports only the decision; the caller persists the flag.
/// </summary>
public sealed partial class MemoryConsentDialog : ContentDialog
{
    public MemoryConsentDialog()
    {
        InitializeComponent();
    }

    /// <summary>
    /// Present the consent dialog and return the user's decision: <c>true</c> = enable
    /// memory extraction (primary button), <c>false</c> = not now (close / dismiss).
    /// Mirrors the Swift <c>onDecision(Bool)</c> callback.
    /// </summary>
    public static async Task<bool> RequestAsync(XamlRoot xamlRoot)
    {
        var dialog = new MemoryConsentDialog { XamlRoot = xamlRoot };
        var result = await dialog.ShowAsync();
        return result == ContentDialogResult.Primary;
    }
}
