using System.Security.Cryptography;
using System.Text;
using Microsoft.AspNetCore.HttpOverrides;
using OpenBurnBar.CloudSync.AppCheck.Windows;

const string TokenEnvironment = "OPENBURNBAR_TPM_VERIFIER_TOKEN";
const string AppIdEnvironment = "OPENBURNBAR_TPM_VERIFIER_APP_ID";
const string TrustedProxiesEnvironment = "OPENBURNBAR_TPM_VERIFIER_TRUSTED_PROXIES";
const int MaxClaimBytes = 64 * 1024;
const int EcdsaP256PublicBlobBytes = 72;
const long MaxAgeMs = 5 * 60 * 1000;
const long MaxForwardSkewMs = 60 * 1000;

string verifierToken = Environment.GetEnvironmentVariable(TokenEnvironment) ?? "";
string expectedAppId = Environment.GetEnvironmentVariable(AppIdEnvironment) ?? "";
IReadOnlyList<System.Net.IPAddress> trustedProxies = TrustedProxyAddressParser.Parse(
    Environment.GetEnvironmentVariable(TrustedProxiesEnvironment));
if (verifierToken.Length < 32)
    throw new InvalidOperationException($"{TokenEnvironment} must contain at least 32 characters.");
if (string.IsNullOrWhiteSpace(expectedAppId))
    throw new InvalidOperationException($"{AppIdEnvironment} is required.");
if (!expectedAppId.StartsWith("1:", StringComparison.Ordinal) ||
    !expectedAppId.Contains(":web:", StringComparison.Ordinal) ||
    expectedAppId.Contains("placeholder", StringComparison.OrdinalIgnoreCase))
    throw new InvalidOperationException($"{AppIdEnvironment} must be a provisioned Firebase web app id.");

var builder = WebApplication.CreateBuilder(args);
builder.WebHost.ConfigureKestrel(options => options.Limits.MaxRequestBodySize = 128 * 1024);
if (trustedProxies.Count > 0)
{
    builder.Services.Configure<ForwardedHeadersOptions>(options =>
    {
        options.ForwardedHeaders = ForwardedHeaders.XForwardedProto;
        options.ForwardLimit = 1;
        options.KnownNetworks.Clear();
        options.KnownProxies.Clear();
        foreach (System.Net.IPAddress address in trustedProxies)
        {
            options.KnownProxies.Add(address);
        }
    });
}
var app = builder.Build();

if (trustedProxies.Count > 0)
{
    app.UseForwardedHeaders();
}
app.Use(async (context, next) =>
{
    if (!context.Request.IsHttps)
    {
        context.Response.StatusCode = StatusCodes.Status400BadRequest;
        await context.Response.WriteAsJsonAsync(new { valid = false, reason = "https_required" });
        return;
    }
    await next();
});

app.MapGet("/healthz", () => Results.Ok(new { ok = true }));
app.MapPost("/verify", (HttpRequest request, TpmVerificationRequest input) =>
{
    if (!HasValidBearer(request, verifierToken)) return Results.Unauthorized();
    if (!IsWellFormed(input, expectedAppId, out byte[] publicKey, out byte[] platformClaim))
        return Results.BadRequest(new { valid = false, reason = "malformed" });

    long age = DateTimeOffset.UtcNow.ToUnixTimeMilliseconds() - input.IssuedAtMs;
    if (age > MaxAgeMs || age < -MaxForwardSkewMs)
        return Results.Unauthorized();

    TpmClaimVerificationResult result = new TpmPlatformClaimVerifier().Verify(
        publicKey,
        platformClaim,
        input.Nonce);
    // Authentication failures use 401. A verified caller presenting an invalid
    // claim gets a normal negative verdict so Functions can distinguish forgery
    // from verifier/service unavailability without exposing the native status.
    if (!result.Valid) return Results.Ok(new { valid = false });

    return Results.Ok(new
    {
        valid = true,
        input.Uid,
        input.AppId,
        input.ChallengeId,
        input.Nonce,
    });
});

app.Run();

static bool HasValidBearer(HttpRequest request, string expectedToken)
{
    string authorization = request.Headers.Authorization.ToString();
    if (!authorization.StartsWith("Bearer ", StringComparison.Ordinal)) return false;
    byte[] actual = Encoding.UTF8.GetBytes(authorization["Bearer ".Length..]);
    byte[] expected = Encoding.UTF8.GetBytes(expectedToken);
    return actual.Length == expected.Length && CryptographicOperations.FixedTimeEquals(actual, expected);
}

static bool IsWellFormed(
    TpmVerificationRequest input,
    string expectedAppId,
    out byte[] publicKey,
    out byte[] platformClaim)
{
    publicKey = Array.Empty<byte>();
    platformClaim = Array.Empty<byte>();
    if (
        input.Version != 1 ||
        input.AppId != expectedAppId ||
        string.IsNullOrWhiteSpace(input.Uid) || input.Uid.Length > 256 ||
        string.IsNullOrWhiteSpace(input.ChallengeId) || input.ChallengeId.Length is < 16 or > 256 ||
        string.IsNullOrWhiteSpace(input.Nonce) || input.Nonce.Length is < 16 or > 256 ||
        input.IssuedAtMs <= 0)
    {
        return false;
    }
    try
    {
        publicKey = Convert.FromBase64String(input.SubjectPublicKey);
        platformClaim = Convert.FromBase64String(input.PlatformClaim);
        return publicKey.Length == EcdsaP256PublicBlobBytes &&
            platformClaim.Length is > 0 and <= MaxClaimBytes;
    }
    catch (FormatException)
    {
        return false;
    }
}

internal sealed record TpmVerificationRequest(
    int Version,
    string Uid,
    string AppId,
    string ChallengeId,
    string Nonce,
    long IssuedAtMs,
    string PlatformClaim,
    string SubjectPublicKey);
