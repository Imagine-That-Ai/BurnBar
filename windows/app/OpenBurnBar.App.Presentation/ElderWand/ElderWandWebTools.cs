using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Net;
using System.Net.Http;
using System.Net.Sockets;
using System.Text;
using System.Text.Json;
using System.Text.RegularExpressions;
using System.Threading;
using System.Threading.Tasks;

namespace OpenBurnBar.App.Presentation.ElderWand;

/// <summary>Bounded, DNS-pinned web tools for the Elder Wand model loop.</summary>
public static partial class ElderWandWebTools
{
    public const int MaximumResponseBytes = 512 * 1024;
    public const int MaximumVisibleCharacters = 64 * 1024;

    public static IReadOnlyList<FusionTool> CreateProduction(
        Func<string, int, CancellationToken, Task<string>>? hostedSearch = null) =>
        new[]
        {
            new FusionTool("web_fetch", Schema(
                "web_fetch",
                "Fetch one public HTTP(S) page and return bounded visible text.",
                "url"), FetchAsync),
            new FusionTool("web_search", Schema(
                "web_search",
                "Search the web for current sources.",
                "query"), async (arguments, cancellationToken) =>
            {
                string? query = ReadStringArgument(arguments, "query");
                if (string.IsNullOrWhiteSpace(query)) return "web_search requires a non-empty query.";
                if (query.Length > 2_000) return "web_search query exceeds the safety limit.";
                return hostedSearch is null
                    ? "Web search is unavailable because no authenticated hosted-search session is configured."
                    : await hostedSearch(query, 5, cancellationToken).ConfigureAwait(false);
            }),
        };

    public static bool IsPublicAddress(IPAddress address)
    {
        if (address.IsIPv4MappedToIPv6) address = address.MapToIPv4();
        if (IPAddress.IsLoopback(address) || address.Equals(IPAddress.Any) || address.Equals(IPAddress.IPv6Any))
        {
            return false;
        }
        byte[] bytes = address.GetAddressBytes();
        if (address.AddressFamily == AddressFamily.InterNetwork)
        {
            return bytes[0] switch
            {
                0 or 10 or 127 => false,
                100 when bytes[1] is >= 64 and <= 127 => false,
                169 when bytes[1] == 254 => false,
                172 when bytes[1] is >= 16 and <= 31 => false,
                192 when bytes[1] == 168 => false,
                >= 224 => false,
                _ => true,
            };
        }
        if (address.AddressFamily != AddressFamily.InterNetworkV6) return false;
        return !address.IsIPv6LinkLocal
            && !address.IsIPv6Multicast
            && !address.IsIPv6SiteLocal
            && (bytes[0] & 0xFE) != 0xFC;
    }

    private static async Task<string> FetchAsync(string arguments, CancellationToken cancellationToken)
    {
        string? rawUrl = ReadStringArgument(arguments, "url");
        if (!Uri.TryCreate(rawUrl, UriKind.Absolute, out Uri? url)
            || url.Scheme is not ("http" or "https")
            || !string.IsNullOrEmpty(url.UserInfo))
        {
            return "web_fetch requires a public HTTP(S) URL without embedded credentials.";
        }

        try
        {
            using var handler = new SocketsHttpHandler
            {
                AllowAutoRedirect = false,
                ConnectCallback = ConnectPublicAsync,
            };
            using var client = new HttpClient(handler) { Timeout = TimeSpan.FromSeconds(20) };
            using var request = new HttpRequestMessage(HttpMethod.Get, url);
            request.Headers.UserAgent.ParseAdd("OpenBurnBar-ElderWand/1.0");
            using HttpResponseMessage response = await client.SendAsync(
                request,
                HttpCompletionOption.ResponseHeadersRead,
                cancellationToken).ConfigureAwait(false);
            if ((int)response.StatusCode is >= 300 and <= 399)
            {
                return "web_fetch denied a redirect; fetch the validated destination explicitly.";
            }
            if (!response.IsSuccessStatusCode)
            {
                return $"web_fetch returned HTTP {(int)response.StatusCode}.";
            }

            byte[] body = await ReadBoundedAsync(response.Content, cancellationToken).ConfigureAwait(false);
            string text = Encoding.UTF8.GetString(body);
            string mediaType = response.Content.Headers.ContentType?.MediaType ?? string.Empty;
            if (mediaType.Contains("html", StringComparison.OrdinalIgnoreCase))
            {
                text = ScriptAndStylePattern().Replace(text, " ");
                text = TagPattern().Replace(text, " ");
                text = WebUtility.HtmlDecode(text);
            }
            text = WhitespacePattern().Replace(text, " ").Trim();
            return text.Length <= MaximumVisibleCharacters ? text : text[..MaximumVisibleCharacters];
        }
        catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested)
        {
            throw;
        }
        catch
        {
            return "web_fetch failed or the destination was denied by network safety policy.";
        }
    }

    private static async ValueTask<Stream> ConnectPublicAsync(
        SocketsHttpConnectionContext context,
        CancellationToken cancellationToken)
    {
        IPAddress[] addresses = await Dns.GetHostAddressesAsync(context.DnsEndPoint.Host, cancellationToken)
            .ConfigureAwait(false);
        IPAddress? selected = addresses.FirstOrDefault(IsPublicAddress);
        if (selected is null || addresses.Any(address => !IsPublicAddress(address)))
        {
            throw new HttpRequestException("The destination did not resolve exclusively to public addresses.");
        }
        var socket = new Socket(selected.AddressFamily, SocketType.Stream, ProtocolType.Tcp);
        try
        {
            await socket.ConnectAsync(selected, context.DnsEndPoint.Port, cancellationToken).ConfigureAwait(false);
            return new NetworkStream(socket, ownsSocket: true);
        }
        catch
        {
            socket.Dispose();
            throw;
        }
    }

    private static async Task<byte[]> ReadBoundedAsync(HttpContent content, CancellationToken cancellationToken)
    {
        if (content.Headers.ContentLength is > MaximumResponseBytes)
        {
            throw new HttpRequestException("web_fetch response exceeds the safety limit.");
        }
        await using Stream stream = await content.ReadAsStreamAsync(cancellationToken).ConfigureAwait(false);
        using var output = new MemoryStream();
        var buffer = new byte[16 * 1024];
        while (true)
        {
            int read = await stream.ReadAsync(buffer, cancellationToken).ConfigureAwait(false);
            if (read == 0) return output.ToArray();
            if (output.Length + read > MaximumResponseBytes)
            {
                throw new HttpRequestException("web_fetch response exceeds the safety limit.");
            }
            output.Write(buffer, 0, read);
        }
    }

    private static JsonElement Schema(string name, string description, string requiredProperty)
    {
        using JsonDocument document = JsonDocument.Parse(JsonSerializer.Serialize(new
        {
            type = "function",
            function = new
            {
                name,
                description,
                parameters = new
                {
                    type = "object",
                    properties = new Dictionary<string, object>
                    {
                        [requiredProperty] = new { type = "string" },
                    },
                    required = new[] { requiredProperty },
                    additionalProperties = false,
                },
            },
        }));
        return document.RootElement.Clone();
    }

    private static string? ReadStringArgument(string arguments, string name)
    {
        try
        {
            using JsonDocument document = JsonDocument.Parse(arguments);
            return document.RootElement.TryGetProperty(name, out JsonElement value)
                && value.ValueKind == JsonValueKind.String
                ? value.GetString()?.Trim()
                : null;
        }
        catch (JsonException)
        {
            return null;
        }
    }

    [GeneratedRegex(@"(?:<script\b[^>]*>[\s\S]*?</script>|<style\b[^>]*>[\s\S]*?</style>)", RegexOptions.IgnoreCase | RegexOptions.CultureInvariant | RegexOptions.NonBacktracking)]
    private static partial Regex ScriptAndStylePattern();

    [GeneratedRegex(@"<[^>]+>", RegexOptions.CultureInvariant | RegexOptions.NonBacktracking)]
    private static partial Regex TagPattern();

    [GeneratedRegex(@"\s+", RegexOptions.CultureInvariant | RegexOptions.NonBacktracking)]
    private static partial Regex WhitespacePattern();
}
