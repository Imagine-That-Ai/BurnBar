using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.Json.Serialization;

namespace OpenBurnBar.App.Configuration;

/// <summary>DPAPI-protected app secret store with one encrypted envelope per account.</summary>
public sealed class ProtectedFileSecretStore : IAppSecretStore
{
    private static readonly JsonSerializerOptions JsonOptions = new()
    {
        PropertyNamingPolicy = JsonNamingPolicy.CamelCase,
        DefaultIgnoreCondition = JsonIgnoreCondition.WhenWritingNull,
        WriteIndented = true,
    };

    private readonly string _rootDirectory;
    private readonly ISecretProtector _protector;

    public ProtectedFileSecretStore(string rootDirectory)
        : this(rootDirectory, OperatingSystem.IsWindows() ? WindowsDpapiSecretProtector.Instance : UnavailableSecretProtector.Instance)
    {
    }

    internal ProtectedFileSecretStore(string rootDirectory, ISecretProtector protector)
    {
        if (string.IsNullOrWhiteSpace(rootDirectory))
        {
            throw new ArgumentException("Secret store root is required.", nameof(rootDirectory));
        }

        _rootDirectory = rootDirectory;
        _protector = protector ?? throw new ArgumentNullException(nameof(protector));
    }

    public string BackendName => _protector.BackendName;

    public static ProtectedFileSecretStore CreateDefault()
    {
        string configDirectory = Path.GetDirectoryName(AppConfiguration.DefaultFilePath())
            ?? throw new InvalidOperationException("OpenBurnBar configuration directory could not be resolved.");
        return new ProtectedFileSecretStore(Path.Combine(configDirectory, "protected-secrets"));
    }

    internal static ProtectedFileSecretStore CreateForTests(string rootDirectory) =>
        new(rootDirectory, new TestSecretProtector());

    public SecretWriteReceipt Write(string secretName, string value)
    {
        ValidateSecretName(secretName);
        ArgumentNullException.ThrowIfNull(value);

        try
        {
            Directory.CreateDirectory(_rootDirectory);
            byte[] plaintext = Encoding.UTF8.GetBytes(value);
            byte[] entropy = EntropyFor(secretName);
            byte[] encrypted = _protector.Protect(plaintext, entropy);
            var envelope = new ProtectedSecretEnvelope
            {
                Version = 1,
                Backend = _protector.BackendName,
                SecretName = secretName,
                CiphertextBase64 = Convert.ToBase64String(encrypted),
                WrittenAt = DateTimeOffset.UtcNow,
            };

            string path = PathFor(secretName);
            AtomicWrite(path, JsonSerializer.Serialize(envelope, JsonOptions));

            string? verified = Read(secretName);
            if (!string.Equals(verified, value, StringComparison.Ordinal))
            {
                throw new SecretStoreException(
                    SecretStoreFailureKind.VerificationFailed,
                    "Protected secret write did not round-trip.",
                    secretName);
            }

            SecretRedactor.Shared.Register(value);
            return new SecretWriteReceipt(secretName, _protector.BackendName, path, envelope.WrittenAt);
        }
        catch (SecretStoreException)
        {
            throw;
        }
        catch (UnauthorizedAccessException ex)
        {
            throw new SecretStoreException(
                SecretStoreFailureKind.WriteDenied,
                "Access denied writing protected secret.",
                secretName,
                ex);
        }
        catch (IOException ex)
        {
            throw new SecretStoreException(
                SecretStoreFailureKind.WriteDenied,
                "I/O failure writing protected secret.",
                secretName,
                ex);
        }
    }

    public string? Read(string secretName)
    {
        ValidateSecretName(secretName);
        string path = PathFor(secretName);
        if (!File.Exists(path))
        {
            return null;
        }

        try
        {
            var envelope = JsonSerializer.Deserialize<ProtectedSecretEnvelope>(File.ReadAllText(path), JsonOptions);
            if (envelope is null
                || envelope.Version != 1
                || !string.Equals(envelope.SecretName, secretName, StringComparison.Ordinal)
                || string.IsNullOrWhiteSpace(envelope.CiphertextBase64))
            {
                throw new SecretStoreException(
                    SecretStoreFailureKind.CorruptProtectedPayload,
                    "Protected secret envelope is corrupt.",
                    secretName);
            }

            byte[] encrypted = Convert.FromBase64String(envelope.CiphertextBase64);
            byte[] plaintext = _protector.Unprotect(encrypted, EntropyFor(secretName));
            string value = Encoding.UTF8.GetString(plaintext);
            SecretRedactor.Shared.Register(value);
            return value;
        }
        catch (SecretStoreException)
        {
            throw;
        }
        catch (UnauthorizedAccessException ex)
        {
            throw new SecretStoreException(
                SecretStoreFailureKind.ReadDenied,
                "Access denied reading protected secret.",
                secretName,
                ex);
        }
        catch (Exception ex) when (ex is IOException or JsonException or FormatException)
        {
            throw new SecretStoreException(
                SecretStoreFailureKind.CorruptProtectedPayload,
                "Protected secret envelope could not be decoded.",
                secretName,
                ex);
        }
    }

    public bool Contains(string secretName)
    {
        ValidateSecretName(secretName);
        return File.Exists(PathFor(secretName));
    }

    public void Delete(string secretName)
    {
        ValidateSecretName(secretName);
        try
        {
            string path = PathFor(secretName);
            if (File.Exists(path))
            {
                File.Delete(path);
            }
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
        {
            throw new SecretStoreException(
                SecretStoreFailureKind.WriteDenied,
                "Protected secret could not be deleted.",
                secretName,
                ex);
        }
    }

    internal string PathFor(string secretName)
    {
        ValidateSecretName(secretName);
        string hash = Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(secretName))).ToLowerInvariant();
        return Path.Combine(_rootDirectory, hash + ".secret.json");
    }

    private static byte[] EntropyFor(string secretName) =>
        SHA256.HashData(Encoding.UTF8.GetBytes("OpenBurnBar.Windows.SecretStore.v1:" + secretName));

    private static void ValidateSecretName(string secretName)
    {
        if (string.IsNullOrWhiteSpace(secretName))
        {
            throw new SecretStoreException(
                SecretStoreFailureKind.InvalidSecretName,
                "Secret name is required.");
        }
    }

    private static void AtomicWrite(string path, string contents)
    {
        string? dir = Path.GetDirectoryName(path);
        if (!string.IsNullOrEmpty(dir))
        {
            Directory.CreateDirectory(dir);
        }

        string temp = path + "." + Guid.NewGuid().ToString("N") + ".tmp";
        string backup = path + "." + Guid.NewGuid().ToString("N") + ".bak";
        File.WriteAllText(temp, contents, Encoding.UTF8);
        if (File.Exists(path))
        {
            File.Replace(temp, path, backup, ignoreMetadataErrors: true);
            TryDelete(backup);
        }
        else
        {
            File.Move(temp, path);
        }
    }

    private static void TryDelete(string path)
    {
        try { if (File.Exists(path)) File.Delete(path); }
        catch { /* best effort */ }
    }

    private sealed record ProtectedSecretEnvelope
    {
        public int Version { get; init; }
        public string Backend { get; init; } = string.Empty;
        public string SecretName { get; init; } = string.Empty;
        public string CiphertextBase64 { get; init; } = string.Empty;
        public DateTimeOffset WrittenAt { get; init; }
    }
}
