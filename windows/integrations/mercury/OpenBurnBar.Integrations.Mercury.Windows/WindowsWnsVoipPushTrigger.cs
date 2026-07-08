using System;
using System.Net.Http;
using System.Net.Http.Headers;
using System.Text;
using System.Threading;
using System.Threading.Tasks;
using OpenBurnBar.Integrations.Mercury.Adapters;
using Windows.Networking.PushNotifications;

namespace OpenBurnBar.Integrations.Mercury.Windows;

/// <summary>
/// The APNs-VoIP → Windows-push substitute implementing <see cref="IVoipPushTrigger"/>
/// (parity: the macOS VoIPCallTrigger APNs ping). Where iOS wakes a phone with an
/// APNs VoIP push, a Windows peer is woken with a WNS raw push: the caller POSTs a
/// wns/raw notification to the peer's channel URI with a WNS OAuth bearer token.
///
/// The <see cref="WnsChannelRegistrar"/> below uses the Windows-only
/// <see cref="PushNotificationChannelManager"/> to obtain the receiving device's
/// channel URI; the send is a portable HTTPS POST, so the trigger is verifiable
/// off Windows while the channel registration is Windows dev-host / CI deferred.
/// </summary>
public sealed class WindowsWnsVoipPushTrigger : IVoipPushTrigger
{
    private readonly HttpClient _httpClient;
    private readonly Func<string, CancellationToken, Task<string?>> _channelUriResolver;
    private readonly Func<CancellationToken, Task<string>> _accessTokenProvider;

    public WindowsWnsVoipPushTrigger(
        HttpClient httpClient,
        Func<string, CancellationToken, Task<string?>> channelUriResolver,
        Func<CancellationToken, Task<string>> accessTokenProvider)
    {
        _httpClient = httpClient ?? throw new ArgumentNullException(nameof(httpClient));
        _channelUriResolver = channelUriResolver ?? throw new ArgumentNullException(nameof(channelUriResolver));
        _accessTokenProvider = accessTokenProvider ?? throw new ArgumentNullException(nameof(accessTokenProvider));
    }

    public async Task<bool> TriggerAsync(string peerDeviceId, string sessionId, CancellationToken cancellationToken = default)
    {
        if (string.IsNullOrWhiteSpace(peerDeviceId))
        {
            throw new ArgumentException("peerDeviceId is required", nameof(peerDeviceId));
        }

        var channelUri = await _channelUriResolver(peerDeviceId, cancellationToken).ConfigureAwait(false);
        if (string.IsNullOrWhiteSpace(channelUri))
        {
            return false;
        }

        var token = await _accessTokenProvider(cancellationToken).ConfigureAwait(false);

        using var request = new HttpRequestMessage(HttpMethod.Post, channelUri)
        {
            Content = new StringContent(BuildRawPayload(sessionId), Encoding.UTF8),
        };
        request.Content.Headers.ContentType = new MediaTypeHeaderValue("application/octet-stream");
        request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", token);
        request.Headers.TryAddWithoutValidation("X-WNS-Type", "wns/raw");
        request.Headers.TryAddWithoutValidation("X-WNS-Cache-Policy", "no-cache");

        using var response = await _httpClient.SendAsync(request, cancellationToken).ConfigureAwait(false);
        return response.IsSuccessStatusCode;
    }

    /// <summary>Build the raw wns payload the receiver decodes to a wake intent.</summary>
    internal static string BuildRawPayload(string sessionId) =>
        $"{{\"kind\":\"mercury.voip.wake\",\"sessionId\":\"{sessionId}\"}}";
}

/// <summary>
/// Obtains a WNS channel URI for the local (receiving) Windows device via
/// <see cref="PushNotificationChannelManager"/>. Windows-only; used by the
/// receiver to register the URI the sender's <see cref="WindowsWnsVoipPushTrigger"/>
/// later POSTs to.
/// </summary>
public sealed class WnsChannelRegistrar
{
    public async Task<string> CreateChannelUriAsync()
    {
        var channel = await PushNotificationChannelManager
            .GetDefault()
            .CreatePushNotificationChannelForApplicationAsync();
        return channel.Uri;
    }
}
