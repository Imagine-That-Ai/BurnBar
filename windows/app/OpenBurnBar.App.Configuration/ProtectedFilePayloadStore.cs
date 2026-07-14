using System.Security.Cryptography;
using System.Text;

namespace OpenBurnBar.App.Configuration;

/// <summary>
/// DPAPI-backed binary state storage. Unlike the short-value secret store, this
/// deliberately does not register opaque payloads with the log redactor.
/// </summary>
public sealed class ProtectedFilePayloadStore
{
    public const int MaximumPayloadBytes = 2 * 1024 * 1024;
    private const int MaximumEnvelopeBytes = MaximumPayloadBytes + (64 * 1024);
    private static readonly byte[] Header = "OPENBURNBAR-PROTECTED-PAYLOAD-V1\n"u8.ToArray();
    private readonly string _rootDirectory;
    private readonly ISecretProtector _protector;

    public ProtectedFilePayloadStore(string rootDirectory)
        : this(
            rootDirectory,
            OperatingSystem.IsWindows()
                ? WindowsDpapiSecretProtector.Instance
                : UnavailableSecretProtector.Instance)
    {
    }

    internal ProtectedFilePayloadStore(string rootDirectory, ISecretProtector protector)
    {
        if (string.IsNullOrWhiteSpace(rootDirectory))
        {
            throw new ArgumentException("Protected payload root is required.", nameof(rootDirectory));
        }
        _rootDirectory = rootDirectory;
        _protector = protector ?? throw new ArgumentNullException(nameof(protector));
    }

    public string BackendName => _protector.BackendName;

    internal string RootDirectory => _rootDirectory;

    public static ProtectedFilePayloadStore CreateDefault()
    {
        string configDirectory = Path.GetDirectoryName(AppConfiguration.DefaultFilePath())
            ?? throw new InvalidOperationException("OpenBurnBar configuration directory could not be resolved.");
        return new ProtectedFilePayloadStore(Path.Combine(configDirectory, "protected-state"));
    }

    internal static ProtectedFilePayloadStore CreateForTests(string rootDirectory) =>
        new(rootDirectory, new TestSecretProtector());

    public void Write(string payloadName, ReadOnlySpan<byte> payload)
    {
        ValidatePayloadName(payloadName);
        if (payload.Length == 0 || payload.Length > MaximumPayloadBytes)
        {
            throw new SecretStoreException(
                SecretStoreFailureKind.WriteDenied,
                "Protected payload has an invalid size.",
                payloadName);
        }

        try
        {
            Directory.CreateDirectory(_rootDirectory);
            byte[] encrypted = _protector.Protect(payload.ToArray(), EntropyFor(payloadName));
            if (encrypted.Length == 0 || encrypted.Length + Header.Length > MaximumEnvelopeBytes)
            {
                throw new SecretStoreException(
                    SecretStoreFailureKind.WriteDenied,
                    "Protected payload envelope exceeds the size limit.",
                    payloadName);
            }
            byte[] envelope = new byte[Header.Length + encrypted.Length];
            Header.CopyTo(envelope, 0);
            encrypted.CopyTo(envelope, Header.Length);
            AtomicWrite(PathFor(payloadName), envelope);

            byte[]? verified = Read(payloadName);
            if (verified is null || !payload.SequenceEqual(verified))
            {
                throw new SecretStoreException(
                    SecretStoreFailureKind.VerificationFailed,
                    "Protected payload write did not round-trip.",
                    payloadName);
            }
        }
        catch (SecretStoreException)
        {
            throw;
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException)
        {
            throw new SecretStoreException(
                SecretStoreFailureKind.WriteDenied,
                "Protected payload could not be written.",
                payloadName,
                error);
        }
    }

    public byte[]? Read(string payloadName)
    {
        ValidatePayloadName(payloadName);
        string path = PathFor(payloadName);
        if (!File.Exists(path)) return null;
        try
        {
            byte[] envelope = ReadEnvelope(path, payloadName);
            if (!envelope.AsSpan(0, Header.Length).SequenceEqual(Header))
            {
                throw Corrupt(payloadName, "Protected payload envelope has an invalid header.");
            }
            byte[] plaintext = _protector.Unprotect(
                envelope.AsSpan(Header.Length).ToArray(),
                EntropyFor(payloadName));
            if (plaintext.Length == 0 || plaintext.Length > MaximumPayloadBytes)
            {
                throw Corrupt(payloadName, "Protected payload plaintext has an invalid size.");
            }
            return plaintext;
        }
        catch (SecretStoreException)
        {
            throw;
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException)
        {
            throw new SecretStoreException(
                SecretStoreFailureKind.ReadDenied,
                "Protected payload could not be read.",
                payloadName,
                error);
        }
    }

    public void Delete(string payloadName)
    {
        ValidatePayloadName(payloadName);
        try
        {
            string path = PathFor(payloadName);
            if (File.Exists(path)) File.Delete(path);
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException)
        {
            throw new SecretStoreException(
                SecretStoreFailureKind.WriteDenied,
                "Protected payload could not be deleted.",
                payloadName,
                error);
        }
    }

    internal string PathFor(string payloadName)
    {
        ValidatePayloadName(payloadName);
        string hash = Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(payloadName)))
            .ToLowerInvariant();
        return Path.Combine(_rootDirectory, hash + ".state");
    }

    private static void ValidatePayloadName(string payloadName)
    {
        if (string.IsNullOrWhiteSpace(payloadName)
            || payloadName.Length > 256
            || payloadName.Any(char.IsControl))
        {
            throw new SecretStoreException(
                SecretStoreFailureKind.InvalidSecretName,
                "A bounded protected payload name is required.");
        }
    }

    private static byte[] EntropyFor(string payloadName) =>
        SHA256.HashData(Encoding.UTF8.GetBytes("OpenBurnBar.Windows.ProtectedPayload.v1:" + payloadName));

    private static SecretStoreException Corrupt(string payloadName, string message) =>
        new(SecretStoreFailureKind.CorruptProtectedPayload, message, payloadName);

    private static byte[] ReadEnvelope(string path, string payloadName)
    {
        using var stream = new FileStream(
            path,
            FileMode.Open,
            FileAccess.Read,
            FileShare.Read,
            bufferSize: 4096,
            FileOptions.SequentialScan);
        if (stream.Length <= Header.Length || stream.Length > MaximumEnvelopeBytes)
        {
            throw Corrupt(payloadName, "Protected payload envelope has an invalid size.");
        }
        var envelope = new byte[(int)stream.Length];
        stream.ReadExactly(envelope);
        return envelope;
    }

    private static void AtomicWrite(string path, byte[] contents)
    {
        string? directory = Path.GetDirectoryName(path);
        if (!string.IsNullOrEmpty(directory)) Directory.CreateDirectory(directory);
        string temporary = path + "." + Guid.NewGuid().ToString("N") + ".tmp";
        string backup = path + "." + Guid.NewGuid().ToString("N") + ".bak";
        File.WriteAllBytes(temporary, contents);
        if (File.Exists(path))
        {
            File.Replace(temporary, path, backup, ignoreMetadataErrors: true);
            TryDelete(backup);
        }
        else
        {
            File.Move(temporary, path);
        }
    }

    private static void TryDelete(string path)
    {
        try { if (File.Exists(path)) File.Delete(path); }
        catch { }
    }
}
