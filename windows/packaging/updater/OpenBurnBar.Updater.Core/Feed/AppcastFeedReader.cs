// Parses the Sparkle / WinSparkle appcast XML into an UpdateManifest.
//
// The appcast mirrors scripts/generate-macos-appcast.mjs: an RSS 2.0 channel
// whose newest <item> carries <sparkle:shortVersionString>, <sparkle:version>,
// <sparkle:minimumSystemVersion>, <sparkle:releaseNotesLink>, an optional
// <sparkle:tags><sparkle:criticalUpdate/>, and an <enclosure> with url / length
// / type / sparkle:edSignature (+ our sparkle:sha256 extension). It selects the
// HIGHEST-versioned item (not merely the first) so a feed that lists several
// releases still yields the newest candidate.
//
// Parsing is HARDENED and FAIL-CLOSED: external DTDs and entity resolution are
// disabled (no XXE / billion-laughs), and ANY structural problem returns null.
// A null result is mapped by the verifier to a MalformedFeed rejection — the
// updater never "accepts" a feed it could not fully parse.

using System;
using System.IO;
using System.Linq;
using System.Xml;
using System.Xml.Linq;
using OpenBurnBar.Updater.Core.Versioning;

namespace OpenBurnBar.Updater.Core.Feed;

/// <summary>Reads the Sparkle/WinSparkle appcast XML feed format.</summary>
public static class AppcastFeedReader
{
    private static readonly XNamespace Sparkle =
        "http://www.andymatuschak.org/xml-namespaces/sparkle";

    /// <summary>
    /// Parses the appcast and returns its newest well-formed item, or null if
    /// the document is malformed, has no usable item, or is missing a required
    /// field (version + url). Never throws on bad input.
    /// </summary>
    public static UpdateManifest? TryParse(string? xml)
    {
        if (string.IsNullOrWhiteSpace(xml))
        {
            return null;
        }

        XDocument document;
        try
        {
            var settings = new XmlReaderSettings
            {
                DtdProcessing = DtdProcessing.Prohibit,
                XmlResolver = null,
                IgnoreComments = true,
                IgnoreProcessingInstructions = true,
            };
            using var stringReader = new StringReader(xml);
            using var xmlReader = XmlReader.Create(stringReader, settings);
            document = XDocument.Load(xmlReader);
        }
        catch (XmlException)
        {
            return null;
        }
        catch (IOException)
        {
            return null;
        }

        var items = document.Descendants("item");
        UpdateManifest? best = null;
        UpdateVersion bestVersion = default;

        foreach (var item in items)
        {
            var candidate = TryParseItem(item);
            if (candidate is null)
            {
                continue;
            }

            if (!candidate.TryGetVersion(out var candidateVersion))
            {
                // An item whose version is not dotted-numeric is unusable; skip
                // it rather than let it masquerade as newest.
                continue;
            }

            if (best is null || candidateVersion > bestVersion)
            {
                best = candidate;
                bestVersion = candidateVersion;
            }
        }

        return best;
    }

    private static UpdateManifest? TryParseItem(XElement item)
    {
        var enclosure = item.Element("enclosure");
        if (enclosure is null)
        {
            return null;
        }

        var url = (string?)enclosure.Attribute("url");
        var version = ((string?)item.Element(Sparkle + "shortVersionString"))?.Trim();
        if (string.IsNullOrWhiteSpace(url) || string.IsNullOrWhiteSpace(version))
        {
            return null;
        }

        long? length = null;
        var lengthRaw = (string?)enclosure.Attribute("length");
        if (!string.IsNullOrWhiteSpace(lengthRaw) &&
            long.TryParse(lengthRaw, out var parsedLength) && parsedLength >= 0)
        {
            length = parsedLength;
        }

        var critical = item
            .Descendants(Sparkle + "criticalUpdate")
            .Any();

        return new UpdateManifest
        {
            Version = version!,
            Build = ((string?)item.Element(Sparkle + "version"))?.Trim(),
            Url = url!,
            Length = length,
            Sha256 = ((string?)enclosure.Attribute(Sparkle + "sha256"))?.Trim(),
            EdSignatureBase64 = ((string?)enclosure.Attribute(Sparkle + "edSignature"))?.Trim(),
            Critical = critical,
            MinimumSystemVersion = ((string?)item.Element(Sparkle + "minimumSystemVersion"))?.Trim(),
            ReleaseNotesUrl = ((string?)item.Element(Sparkle + "releaseNotesLink"))?.Trim(),
            PubDate = ((string?)item.Element("pubDate"))?.Trim(),
        };
    }
}
