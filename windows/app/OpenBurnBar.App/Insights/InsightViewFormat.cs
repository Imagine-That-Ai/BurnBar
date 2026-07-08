namespace OpenBurnBar.App.Insights;

/// <summary>
/// Tiny presentation-string helpers used by the Insights XAML via <c>x:Bind</c> function
/// binding (the Windows idiom for a one-liner value converter). Pure + trivial.
/// </summary>
public static class InsightViewFormat
{
    /// <summary>"8 widgets" / "1 widget" for the template gallery card footer.</summary>
    public static string WidgetCount(int count) => count == 1 ? "1 widget" : $"{count} widgets";
}
