namespace OpenBurnBar.App.Configuration;

public enum SecretStoreFailureKind
{
    InvalidSecretName,
    ProtectedStorageUnavailable,
    WriteDenied,
    ReadDenied,
    VerificationFailed,
    CorruptProtectedPayload,
    SecretMissing,
    MigrationFailed,
}

public sealed class SecretStoreException : Exception
{
    public SecretStoreFailureKind Failure { get; }
    public string? SecretName { get; }

    public SecretStoreException(SecretStoreFailureKind failure, string message, string? secretName = null, Exception? innerException = null)
        : base(message, innerException)
    {
        Failure = failure;
        SecretName = secretName;
    }
}

public sealed record SecretWriteReceipt(
    string SecretName,
    string Backend,
    string StoragePath,
    DateTimeOffset WrittenAt);

public interface IAppSecretStore
{
    string BackendName { get; }
    SecretWriteReceipt Write(string secretName, string value);
    string? Read(string secretName);
    bool Contains(string secretName);
    void Delete(string secretName);
}

internal interface ISecretProtector
{
    string BackendName { get; }
    byte[] Protect(byte[] plaintext, byte[] entropy);
    byte[] Unprotect(byte[] protectedBytes, byte[] entropy);
}

internal sealed class UnavailableSecretProtector : ISecretProtector
{
    public static readonly UnavailableSecretProtector Instance = new();

    public string BackendName => "unavailable";

    public byte[] Protect(byte[] plaintext, byte[] entropy) =>
        throw new SecretStoreException(
            SecretStoreFailureKind.ProtectedStorageUnavailable,
            "Windows protected storage is unavailable on this host.");

    public byte[] Unprotect(byte[] protectedBytes, byte[] entropy) =>
        throw new SecretStoreException(
            SecretStoreFailureKind.ProtectedStorageUnavailable,
            "Windows protected storage is unavailable on this host.");
}

internal sealed class TestSecretProtector : ISecretProtector
{
    private static readonly byte[] Prefix = "OPENBURNBAR-TEST-PROTECTED:"u8.ToArray();

    public string BackendName => "test-protected";

    public byte[] Protect(byte[] plaintext, byte[] entropy)
    {
        var output = new byte[Prefix.Length + plaintext.Length];
        Buffer.BlockCopy(Prefix, 0, output, 0, Prefix.Length);
        for (int i = 0; i < plaintext.Length; i++)
        {
            output[Prefix.Length + i] = (byte)(plaintext[i] ^ entropy[i % entropy.Length] ^ 0x5A);
        }

        return output;
    }

    public byte[] Unprotect(byte[] protectedBytes, byte[] entropy)
    {
        if (protectedBytes.Length < Prefix.Length
            || !protectedBytes.AsSpan(0, Prefix.Length).SequenceEqual(Prefix))
        {
            throw new SecretStoreException(
                SecretStoreFailureKind.CorruptProtectedPayload,
                "The protected test payload is corrupt.");
        }

        var output = new byte[protectedBytes.Length - Prefix.Length];
        for (int i = 0; i < output.Length; i++)
        {
            output[i] = (byte)(protectedBytes[Prefix.Length + i] ^ entropy[i % entropy.Length] ^ 0x5A);
        }

        return output;
    }
}
