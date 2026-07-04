namespace OpenBurnBar.Updater.Core.Feed;

/// <summary>The two update-feed encodings the updater understands.</summary>
public enum FeedFormat
{
    /// <summary>The Sparkle / WinSparkle appcast RSS-XML (mirrors appcast.xml).</summary>
    Appcast,

    /// <summary>The latest-windows.json companion (mirrors latest-macos.json).</summary>
    Json,
}
