using System.Text.Json;
using System.Text.Json.Serialization;
using OpenBurnBar.App.Configuration;

namespace OpenBurnBar.App.CloudSync;

public interface IFirebaseOAuthSessionStore
{
    FirebaseOAuthSession? Load();
    void Save(FirebaseOAuthSession session);
    void Delete();
}

public sealed class ProtectedFirebaseOAuthSessionStore : IFirebaseOAuthSessionStore
{
    private static readonly JsonSerializerOptions JsonOptions = new()
    {
        PropertyNamingPolicy = JsonNamingPolicy.CamelCase,
        DefaultIgnoreCondition = JsonIgnoreCondition.WhenWritingNull,
    };

    private readonly IAppSecretStore _secrets;
    private readonly string _secretName;

    public ProtectedFirebaseOAuthSessionStore(
        IAppSecretStore secrets,
        string secretName = AppSecretNames.OAuthSession)
    {
        _secrets = secrets ?? throw new ArgumentNullException(nameof(secrets));
        _secretName = secretName;
    }

    public FirebaseOAuthSession? Load()
    {
        string? json = _secrets.Read(_secretName);
        if (string.IsNullOrWhiteSpace(json))
        {
            return null;
        }

        try
        {
            return JsonSerializer.Deserialize<FirebaseOAuthSession>(json, JsonOptions);
        }
        catch (JsonException ex)
        {
            throw new SecretStoreException(
                SecretStoreFailureKind.CorruptProtectedPayload,
                "Protected OAuth session could not be decoded.",
                _secretName,
                ex);
        }
    }

    public void Save(FirebaseOAuthSession session)
    {
        ArgumentNullException.ThrowIfNull(session);
        _secrets.Write(_secretName, JsonSerializer.Serialize(session, JsonOptions));
    }

    public void Delete() => _secrets.Delete(_secretName);
}
