using Xunit;
using OpenBurnBar.App.Configuration;

namespace OpenBurnBar.App.Configuration.Tests;

public sealed class AppConfigurationTests
{
    [Fact]
    public void Effective_sqlcipher_prefers_environment_over_file()
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
            Assert.Equal("C:\\from-env.sqlite", config.EffectiveSqlCipherDbPath());
            Assert.Equal("env-pass", config.EffectiveSqlCipherPassphrase());
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
        }
        finally
        {
            try { Directory.Delete(dir, recursive: true); } catch { /* best effort */ }
        }
    }
}