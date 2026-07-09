using Xunit;
using OpenBurnBar.App.Configuration;
using System.Text;

namespace OpenBurnBar.App.Configuration.Tests;

public sealed class AppConfigurationTests
{
    [Fact]
    public void Sqlcipher_environment_is_rejected_by_release_guard_and_ignored_by_configuration()
    {
        string dir = Path.Combine(Path.GetTempPath(), "obb-config-test-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(dir);
        string path = Path.Combine(dir, "app_config.json");
        File.WriteAllText(path, """{"sqlCipherDbPath":"C:\\from-file.sqlite","sqlCipherPassphrase":"file-pass"}""");

        try
        {
            Environment.SetEnvironmentVariable("OPENBURNBAR_SQLCIPHER_PATH", "C:\\from-env.sqlite");
            Environment.SetEnvironmentVariable("OPENBURNBAR_SQLCIPHER_PASSPHRASE", "env-pass");

            var config = new AppConfiguration(path);
            Assert.Equal("C:\\from-file.sqlite", config.EffectiveSqlCipherDbPath());
            Assert.Equal("file-pass", config.EffectiveSqlCipherPassphrase());

            var ex = Assert.Throws<SecretStoreException>(() =>
                ReleaseConfigurationGuard.ThrowIfPlaintextCredentialEnvironmentPresent(new[]
                {
                    new KeyValuePair<string, string?>("OPENBURNBAR_SQLCIPHER_PATH", "C:\\from-env.sqlite"),
                    new KeyValuePair<string, string?>("OPENBURNBAR_SQLCIPHER_PASSPHRASE", "env-pass"),
                }));
            Assert.Equal(SecretStoreFailureKind.WriteDenied, ex.Failure);
        }
        finally
        {
            Environment.SetEnvironmentVariable("OPENBURNBAR_SQLCIPHER_PATH", null);
            Environment.SetEnvironmentVariable("OPENBURNBAR_SQLCIPHER_PASSPHRASE", null);
            try { Directory.Delete(dir, recursive: true); } catch { /* best effort */ }
        }
    }

    [Fact]
    public void Save_and_reload_round_trips_file_values()
    {
        string dir = Path.Combine(Path.GetTempPath(), "obb-config-test-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(dir);
        string path = Path.Combine(dir, "app_config.json");

        try
        {
            var config = new AppConfiguration(path);
            config.Save(new AppConfigurationModel
            {
                SqlCipherDbPath = "/data/ob.sqlite",
                SqlCipherPassphrase = "secret",
                FirebaseUid = "uid-1",
                FirebaseIdToken = "token-1",
            });

            var reloaded = new AppConfiguration(path);
            Assert.Equal("/data/ob.sqlite", reloaded.EffectiveSqlCipherDbPath());
            Assert.Equal("secret", reloaded.EffectiveSqlCipherPassphrase());
            Assert.Equal("uid-1", reloaded.EffectiveFirebaseUid());
            Assert.Equal("token-1", reloaded.EffectiveFirebaseIdToken());

            string json = File.ReadAllText(path);
            Assert.DoesNotContain("secret", json, StringComparison.Ordinal);
            Assert.DoesNotContain("token-1", json, StringComparison.Ordinal);
            Assert.Contains("sqlCipherPassphraseRef", json, StringComparison.Ordinal);
            Assert.Contains("firebaseIdTokenRef", json, StringComparison.Ordinal);
        }
        finally
        {
            try { Directory.Delete(dir, recursive: true); } catch { /* best effort */ }
        }
    }

    [Fact]
    public void Legacy_plaintext_config_migrates_to_protected_refs_atomically()
    {
        string dir = Path.Combine(Path.GetTempPath(), "obb-config-test-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(dir);
        string path = Path.Combine(dir, "app_config.json");
        File.WriteAllText(path, """
        {
          "sqlCipherDbPath": "C:\\data\\openburnbar.sqlite",
          "sqlCipherPassphrase": "legacy-db-pass-canary",
          "firebaseUid": "uid-1",
          "firebaseIdToken": "legacy-firebase-id-token-canary",
          "appCheckToken": "legacy-app-check-canary",
          "vaultKeyB64": "bGVnYWN5LXZhdWx0LWtleS1jYW5hcnk="
        }
        """);

        try
        {
            var store = ProtectedFileSecretStore.CreateForTests(Path.Combine(dir, "protected-secrets"));
            var config = new AppConfiguration(path, store);

            Assert.Equal(AppConfigurationSecurityStatus.MigratedLegacySecrets, config.SecurityState.Status);
            Assert.Equal("legacy-db-pass-canary", config.EffectiveSqlCipherPassphrase());
            Assert.Equal("legacy-firebase-id-token-canary", config.EffectiveFirebaseIdToken());
            Assert.Equal("legacy-app-check-canary", config.EffectiveAppCheckToken());
            Assert.Equal("bGVnYWN5LXZhdWx0LWtleS1jYW5hcnk=", config.EffectiveVaultKeyB64());

            string migrated = File.ReadAllText(path);
            Assert.DoesNotContain("legacy-db-pass-canary", migrated, StringComparison.Ordinal);
            Assert.DoesNotContain("legacy-firebase-id-token-canary", migrated, StringComparison.Ordinal);
            Assert.DoesNotContain("legacy-app-check-canary", migrated, StringComparison.Ordinal);
            Assert.Contains("\"sqlCipherPassphraseRef\"", migrated, StringComparison.Ordinal);
            Assert.Contains("\"firebaseIdTokenRef\"", migrated, StringComparison.Ordinal);
            Assert.False(File.Exists(path + ".secret-migration.json"));
        }
        finally
        {
            try { Directory.Delete(dir, recursive: true); } catch { /* best effort */ }
        }
    }

    [Theory]
    [InlineData(SecretMigrationBoundary.AfterJournalWritten)]
    [InlineData(SecretMigrationBoundary.AfterSecretWritten)]
    [InlineData(SecretMigrationBoundary.AfterSecretVerified)]
    [InlineData(SecretMigrationBoundary.AfterConfigReplaced)]
    public void Legacy_migration_recovers_after_interruption(SecretMigrationBoundary boundary)
    {
        string dir = Path.Combine(Path.GetTempPath(), "obb-config-test-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(dir);
        string path = Path.Combine(dir, "app_config.json");
        File.WriteAllText(path, """{"sqlCipherPassphrase":"legacy-pass-after-crash"}""");

        try
        {
            var store = ProtectedFileSecretStore.CreateForTests(Path.Combine(dir, "protected-secrets"));
            Assert.Throws<SecretStoreException>(() =>
                new AppConfiguration(path, store, new SecretMigrationFaults { Boundary = boundary }));

            var recovered = new AppConfiguration(path, store);
            Assert.Equal("legacy-pass-after-crash", recovered.EffectiveSqlCipherPassphrase());
            string json = File.ReadAllText(path);
            Assert.DoesNotContain("legacy-pass-after-crash", json, StringComparison.Ordinal);
            Assert.Contains("sqlCipherPassphraseRef", json, StringComparison.Ordinal);
            Assert.False(File.Exists(path + ".secret-migration.json"));
        }
        finally
        {
            try { Directory.Delete(dir, recursive: true); } catch { /* best effort */ }
        }
    }

    [Fact]
    public void Migration_denied_keeps_plaintext_file_but_fails_closed()
    {
        string dir = Path.Combine(Path.GetTempPath(), "obb-config-test-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(dir);
        string path = Path.Combine(dir, "app_config.json");
        File.WriteAllText(path, """{"firebaseIdToken":"legacy-token-denied"}""");

        try
        {
            var ex = Assert.Throws<SecretStoreException>(() =>
                new AppConfiguration(path, new ThrowingSecretStore()));
            Assert.Equal(SecretStoreFailureKind.WriteDenied, ex.Failure);
            Assert.Contains("legacy-token-denied", File.ReadAllText(path), StringComparison.Ordinal);
        }
        finally
        {
            try { Directory.Delete(dir, recursive: true); } catch { /* best effort */ }
        }
    }

    [Fact]
    public void Missing_protected_ref_fails_closed_instead_of_empty_fallback()
    {
        string dir = Path.Combine(Path.GetTempPath(), "obb-config-test-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(dir);
        string path = Path.Combine(dir, "app_config.json");
        File.WriteAllText(path, """{"appCheckTokenRef":"missing-ref"}""");

        try
        {
            var store = ProtectedFileSecretStore.CreateForTests(Path.Combine(dir, "protected-secrets"));
            var ex = Assert.Throws<SecretStoreException>(() => new AppConfiguration(path, store));
            Assert.Equal(SecretStoreFailureKind.SecretMissing, ex.Failure);
        }
        finally
        {
            try { Directory.Delete(dir, recursive: true); } catch { /* best effort */ }
        }
    }

    [Fact]
    public void Redactor_and_scanner_cover_exact_encoded_substring_structured_and_entropy()
    {
        string secret = "canary-secret-value-1234567890";
        var redactor = new SecretRedactor();
        redactor.Register(secret);

        string text = "token=" + secret
            + " b64=" + Convert.ToBase64String(Encoding.UTF8.GetBytes(secret))
            + " mid=" + secret.Substring(4, 16)
            + " api_key=sk-live-abcdefghijklmnopqrstuvwxyz123456";
        string redacted = redactor.Redact(text);

        Assert.DoesNotContain(secret, redacted, StringComparison.Ordinal);
        Assert.DoesNotContain(Convert.ToBase64String(Encoding.UTF8.GetBytes(secret)), redacted, StringComparison.Ordinal);
        Assert.DoesNotContain(secret.Substring(4, 16), redacted, StringComparison.Ordinal);
        Assert.DoesNotContain("sk-live-abcdefghijklmnopqrstuvwxyz123456", redacted, StringComparison.Ordinal);

        IReadOnlyList<SecretLeakFinding> leaks = SecretLeakScanner.ScanText("artifact.log", text, new[] { secret });
        Assert.Contains(leaks, f => f.Kind == SecretLeakKind.Exact);
        Assert.Contains(leaks, f => f.Kind == SecretLeakKind.Encoded);
        Assert.Contains(leaks, f => f.Kind == SecretLeakKind.Substring);
        Assert.Contains(leaks, f => f.Kind == SecretLeakKind.StructuredField);
        Assert.Contains(leaks, f => f.Kind == SecretLeakKind.HighEntropy);

        Assert.Empty(SecretLeakScanner.ScanText("artifact.log", redacted, new[] { secret }));
    }

    [Fact]
    public void Child_process_environment_preserves_runtime_values_and_excludes_secret_canaries()
    {
        var source = new[]
        {
            new KeyValuePair<string, string?>("PATH", "C:\\Windows\\System32"),
            new KeyValuePair<string, string?>("SystemRoot", "C:\\Windows"),
            new KeyValuePair<string, string?>("OPENAI_API_KEY", "forbidden"),
            new KeyValuePair<string, string?>("OPENBURNBAR_SQLCIPHER_PATH", "forbidden"),
            new KeyValuePair<string, string?>("OPENBURNBAR_SQLCIPHER_PASSPHRASE", "forbidden"),
            new KeyValuePair<string, string?>("WINDOWS_UPDATE_SIGNING_KEY", "forbidden"),
            new KeyValuePair<string, string?>("DIAGNOSTIC_CANARY_SECRET", "forbidden"),
        };

        IReadOnlyDictionary<string, string> env = ChildProcessEnvironment.CreateAllowlisted(
            ChildProcessProfile.Chat,
            source);

        Assert.Equal("C:\\Windows\\System32", env["PATH"]);
        Assert.DoesNotContain("OPENAI_API_KEY", env.Keys);
        Assert.DoesNotContain("OPENBURNBAR_SQLCIPHER_PATH", env.Keys);
        Assert.DoesNotContain("OPENBURNBAR_SQLCIPHER_PASSPHRASE", env.Keys);
        Assert.DoesNotContain("WINDOWS_UPDATE_SIGNING_KEY", env.Keys);
        Assert.DoesNotContain("DIAGNOSTIC_CANARY_SECRET", env.Keys);
    }

    private sealed class ThrowingSecretStore : IAppSecretStore
    {
        public string BackendName => "throwing";
        public SecretWriteReceipt Write(string secretName, string value) =>
            throw new SecretStoreException(SecretStoreFailureKind.WriteDenied, "denied", secretName);
        public string? Read(string secretName) => null;
        public bool Contains(string secretName) => false;
        public void Delete(string secretName) { }
    }
}
