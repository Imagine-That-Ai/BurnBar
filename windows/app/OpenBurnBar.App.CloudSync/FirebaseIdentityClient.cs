using System;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Net.Http;
using System.Text.Json;
using System.Threading;
using System.Threading.Tasks;

namespace OpenBurnBar.App.CloudSync;

/// <summary>
/// The portable wire contract for the desktop Firebase sign-in exchanges, over an
/// injected <see cref="HttpClient"/>. Owns exactly three round-trips and fails
/// CLOSED (throws <see cref="DesktopOAuthException"/>) on any non-success:
/// <list type="number">
///   <item><see cref="ExchangeAuthorizationCodeAsync"/> — Google OAuth token endpoint
///     (authorization-code + PKCE → Google id/access/refresh tokens),</item>
///   <item><see cref="SignInWithIdpAsync"/> — Firebase <c>accounts:signInWithIdp</c>
///     (Google id token → Firebase id token + refresh token + uid),</item>
///   <item><see cref="RefreshAsync"/> — Firebase <c>securetoken</c>
///     (refresh_token → new Firebase id token).</item>
/// </list>
/// Field parsing tolerates both snake_case (Google OAuth + securetoken) and
/// camelCase (Identity Toolkit) spellings, and an <c>expires_in</c> that arrives as
/// a number or a string.
/// </summary>
public sealed class FirebaseIdentityClient
{
    private readonly HttpClient _http;
    private readonly DesktopOAuthOptions _options;

    public FirebaseIdentityClient(HttpClient http, DesktopOAuthOptions options)
    {
        _http = http ?? throw new ArgumentNullException(nameof(http));
        _options = options ?? throw new ArgumentNullException(nameof(options));
    }

    /// <summary>Google OAuth: exchange the authorization code (+ PKCE verifier) for tokens.</summary>
    public async Task<GoogleTokenResult> ExchangeAuthorizationCodeAsync(
        string code,
        string codeVerifier,
        string redirectUri,
        CancellationToken cancellationToken)
    {
        var form = new List<KeyValuePair<string, string>>
        {
            new("grant_type", "authorization_code"),
            new("code", code),
            new("code_verifier", codeVerifier),
            new("redirect_uri", redirectUri),
            new("client_id", _options.ClientId),
        };
        if (!string.IsNullOrEmpty(_options.ClientSecret))
        {
            form.Add(new KeyValuePair<string, string>("client_secret", _options.ClientSecret!));
        }

        JsonElement root = await PostFormAsync(_options.TokenEndpoint, form, "code exchange", cancellationToken)
            .ConfigureAwait(false);

        string? googleIdToken = ReadString(root, "id_token", "idToken");
        if (string.IsNullOrEmpty(googleIdToken))
        {
            throw DesktopOAuthException.Malformed("code exchange", "missing id_token");
        }

        return new GoogleTokenResult(
            GoogleIdToken: googleIdToken!,
            AccessToken: ReadString(root, "access_token", "accessToken"),
            RefreshToken: ReadString(root, "refresh_token", "refreshToken"),
            ExpiresInSeconds: ReadExpiresIn(root));
    }

    /// <summary>Firebase <c>accounts:signInWithIdp</c>: trade a Google id token for a Firebase id token.</summary>
    public async Task<FirebaseSignInResult> SignInWithIdpAsync(
        string googleIdToken,
        CancellationToken cancellationToken)
    {
        string requestUri = $"http://{_options.LoopbackHost}";
        string postBody = $"id_token={Uri.EscapeDataString(googleIdToken)}&providerId={Uri.EscapeDataString(_options.ProviderId)}";

        byte[] body;
        using (var stream = new MemoryStream())
        {
            using (var writer = new Utf8JsonWriter(stream))
            {
                writer.WriteStartObject();
                writer.WriteString("postBody", postBody);
                writer.WriteString("requestUri", requestUri);
                writer.WriteBoolean("returnSecureToken", true);
                writer.WriteBoolean("returnIdpCredential", true);
                writer.WriteEndObject();
            }
            body = stream.ToArray();
        }

        Uri url = WithApiKey(_options.FirebaseSignInEndpoint);
        JsonElement root = await PostJsonAsync(url, body, "signInWithIdp", cancellationToken).ConfigureAwait(false);

        string? idToken = ReadString(root, "idToken", "id_token");
        string? refreshToken = ReadString(root, "refreshToken", "refresh_token");
        string? uid = ReadString(root, "localId", "user_id");
        if (string.IsNullOrEmpty(idToken) || string.IsNullOrEmpty(refreshToken) || string.IsNullOrEmpty(uid))
        {
            throw DesktopOAuthException.Malformed("signInWithIdp", "missing idToken/refreshToken/localId");
        }

        return new FirebaseSignInResult(
            IdToken: idToken!,
            RefreshToken: refreshToken!,
            ExpiresInSeconds: ReadExpiresIn(root) ?? 3600,
            Uid: uid!,
            Email: ReadString(root, "email"));
    }

    /// <summary>Firebase <c>securetoken</c>: exchange a refresh token for a fresh Firebase id token.</summary>
    public async Task<FirebaseRefreshResult> RefreshAsync(string refreshToken, CancellationToken cancellationToken)
    {
        var form = new List<KeyValuePair<string, string>>
        {
            new("grant_type", "refresh_token"),
            new("refresh_token", refreshToken),
        };

        Uri url = WithApiKey(_options.FirebaseRefreshEndpoint);
        JsonElement root = await PostFormAsync(url, form, "token refresh", cancellationToken).ConfigureAwait(false);

        string? idToken = ReadString(root, "id_token", "idToken", "access_token");
        string? newRefresh = ReadString(root, "refresh_token", "refreshToken");
        string? uid = ReadString(root, "user_id", "localId");
        if (string.IsNullOrEmpty(idToken) || string.IsNullOrEmpty(newRefresh))
        {
            throw DesktopOAuthException.Malformed("token refresh", "missing id_token/refresh_token");
        }

        return new FirebaseRefreshResult(
            IdToken: idToken!,
            RefreshToken: newRefresh!,
            ExpiresInSeconds: ReadExpiresIn(root) ?? 3600,
            Uid: uid ?? string.Empty);
    }

    // ── HTTP plumbing ────────────────────────────────────────────────────────
    private Uri WithApiKey(Uri endpoint)
    {
        var builder = new UriBuilder(endpoint);
        string keyParam = $"key={Uri.EscapeDataString(_options.FirebaseApiKey)}";
        builder.Query = string.IsNullOrEmpty(builder.Query) ? keyParam : builder.Query.TrimStart('?') + "&" + keyParam;
        return builder.Uri;
    }

    private Task<JsonElement> PostFormAsync(
        Uri url,
        IEnumerable<KeyValuePair<string, string>> form,
        string stage,
        CancellationToken cancellationToken) =>
        SendAsync(url, new FormUrlEncodedContent(form), stage, cancellationToken);

    private Task<JsonElement> PostJsonAsync(Uri url, byte[] body, string stage, CancellationToken cancellationToken)
    {
        var content = new ByteArrayContent(body);
        content.Headers.TryAddWithoutValidation("Content-Type", "application/json");
        return SendAsync(url, content, stage, cancellationToken);
    }

    private async Task<JsonElement> SendAsync(Uri url, HttpContent content, string stage, CancellationToken cancellationToken)
    {
        using var request = new HttpRequestMessage(HttpMethod.Post, url) { Content = content };
        request.Headers.TryAddWithoutValidation("Accept", "application/json");

        using var timeoutCts = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
        if (_options.HttpTimeoutSeconds > 0)
        {
            timeoutCts.CancelAfter(TimeSpan.FromSeconds(_options.HttpTimeoutSeconds));
        }

        HttpResponseMessage response;
        try
        {
            response = await _http.SendAsync(request, HttpCompletionOption.ResponseContentRead, timeoutCts.Token)
                .ConfigureAwait(false);
        }
        catch (OperationCanceledException) when (!cancellationToken.IsCancellationRequested)
        {
            throw new DesktopOAuthException(DesktopOAuthFailure.Transport, $"{stage} timed out.");
        }
        catch (HttpRequestException ex)
        {
            throw DesktopOAuthException.Transport(stage, ex);
        }

        using (response)
        {
            string bodyText = await response.Content.ReadAsStringAsync(cancellationToken).ConfigureAwait(false);
            if (!response.IsSuccessStatusCode)
            {
                throw DesktopOAuthException.TokenExchange(stage, (int)response.StatusCode, bodyText);
            }

            try
            {
                using var document = JsonDocument.Parse(string.IsNullOrEmpty(bodyText) ? "{}" : bodyText);
                return document.RootElement.Clone();
            }
            catch (JsonException ex)
            {
                throw DesktopOAuthException.Malformed(stage, $"non-JSON body ({ex.Message})");
            }
        }
    }

    private static string? ReadString(JsonElement root, params string[] names)
    {
        foreach (string name in names)
        {
            if (root.ValueKind == JsonValueKind.Object
                && root.TryGetProperty(name, out JsonElement value)
                && value.ValueKind == JsonValueKind.String)
            {
                string? s = value.GetString();
                if (!string.IsNullOrEmpty(s))
                {
                    return s;
                }
            }
        }
        return null;
    }

    private static long? ReadExpiresIn(JsonElement root)
    {
        foreach (string name in new[] { "expires_in", "expiresIn" })
        {
            if (root.ValueKind != JsonValueKind.Object || !root.TryGetProperty(name, out JsonElement value))
            {
                continue;
            }
            if (value.ValueKind == JsonValueKind.Number && value.TryGetInt64(out long n))
            {
                return n;
            }
            if (value.ValueKind == JsonValueKind.String
                && long.TryParse(value.GetString(), NumberStyles.Integer, CultureInfo.InvariantCulture, out long parsed))
            {
                return parsed;
            }
        }
        return null;
    }
}

/// <summary>Google OAuth token-endpoint result (the id token here is a <b>Google</b> OIDC token).</summary>
public sealed record GoogleTokenResult(
    string GoogleIdToken,
    string? AccessToken,
    string? RefreshToken,
    long? ExpiresInSeconds);

/// <summary>Firebase <c>signInWithIdp</c> result (the id token here is a <b>Firebase</b> token).</summary>
public sealed record FirebaseSignInResult(
    string IdToken,
    string RefreshToken,
    long ExpiresInSeconds,
    string Uid,
    string? Email);

/// <summary>Firebase <c>securetoken</c> refresh result.</summary>
public sealed record FirebaseRefreshResult(
    string IdToken,
    string RefreshToken,
    long ExpiresInSeconds,
    string Uid);
