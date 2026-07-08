using System;
using System.Collections.Generic;
using System.IO;
using OpenBurnBar.Integrations.HomeAssistant;
using OpenBurnBar.Integrations.HomeAssistant.Stores;
using Xunit;

namespace OpenBurnBar.Integrations.Tests;

public class HomeAssistantUrlNormalizerTests
{
    [Theory]
    [InlineData("homeassistant.local", "http://homeassistant.local:8123")]
    [InlineData("homeassistant.local:8123", "http://homeassistant.local:8123")]
    [InlineData("http://homeassistant.local:8123/", "http://homeassistant.local:8123")]
    [InlineData("http://192.168.1.5:8123/lovelace/0", "http://192.168.1.5:8123")]
    [InlineData("x.duckdns.org", "https://x.duckdns.org")]
    [InlineData("https://x.duckdns.org", "https://x.duckdns.org")]
    [InlineData("https://my.example.com:8443/path?q=1", "https://my.example.com:8443")]
    [InlineData("  homeassistant.local  ", "http://homeassistant.local:8123")]
    public void Normalize_ProducesCanonicalOrigin(string raw, string expected)
    {
        Assert.Equal(expected, HomeAssistantUrlNormalizer.Normalize(raw));
    }

    [Theory]
    [InlineData("")]
    [InlineData("   ")]
    public void Normalize_EmptyInput_ReturnsNull(string raw)
    {
        Assert.Null(HomeAssistantUrlNormalizer.Normalize(raw));
    }
}

public class HomeAssistantWebhookIdTests
{
    [Fact]
    public void Generate_MapsBytesThroughAlphabet_Deterministically()
    {
        byte[] Bytes()
        {
            var b = new byte[32];
            for (var i = 0; i < 32; i++) b[i] = (byte)i;
            return b;
        }
        var id = HomeAssistantWebhookId.Generate(Bytes);
        Assert.Equal("openburnbar_cast_recover_abcdefghijklmnopqrstuvwxyz012345", id);
    }

    [Fact]
    public void Generate_WrapsByteModuloAlphabet()
    {
        // 36 -> 'a' again, 37 -> 'b'.
        var id = HomeAssistantWebhookId.Generate(() =>
        {
            var b = new byte[32];
            b[0] = 36;
            b[1] = 37;
            return b;
        });
        Assert.StartsWith("openburnbar_cast_recover_ab", id);
    }

    [Fact]
    public void IsOurs_MatchesPrefixAndLength()
    {
        var id = HomeAssistantWebhookId.Generate(() =>
        {
            var b = new byte[32];
            return b;
        });
        Assert.True(HomeAssistantWebhookId.IsOurs(id));
        Assert.False(HomeAssistantWebhookId.IsOurs("openburnbar_cast_recover_short"));
        Assert.False(HomeAssistantWebhookId.IsOurs("someone_else_" + new string('a', 32)));
    }

    [Fact]
    public void DefaultRandomBytes_ProduceUniqueHighEntropyIds()
    {
        var a = HomeAssistantWebhookId.Generate();
        var b = HomeAssistantWebhookId.Generate();
        Assert.NotEqual(a, b);
        Assert.True(HomeAssistantWebhookId.IsOurs(a));
    }
}

public class HomeAssistantBlueprintInstallerTests
{
    [Fact]
    public void ImportDeepLink_EncodesBlueprintUrl()
    {
        var link = HomeAssistantBlueprintInstaller.ImportDeepLink();
        Assert.StartsWith("https://my.home-assistant.io/redirect/blueprint_import/?blueprint_url=", link);
        var value = link.Substring(link.IndexOf("blueprint_url=", StringComparison.Ordinal) + "blueprint_url=".Length);
        Assert.Equal(HomeAssistantBlueprintInstaller.DefaultBlueprintUrl, Uri.UnescapeDataString(value));
    }

    [Fact]
    public void BlueprintYaml_ContainsRecoveryContract()
    {
        var yaml = HomeAssistantBlueprintInstaller.BlueprintYaml;
        Assert.Contains("name: OpenBurnBar Smart Display Recovery", yaml);
        Assert.Contains("platform: webhook", yaml);
        Assert.Contains("media_player.media_stop", yaml);
        Assert.Contains("media_player.play_media", yaml);
        Assert.Contains("mode: restart", yaml);
    }

    [Fact]
    public void WriteYamlToTemp_WritesReadableFile()
    {
        var path = HomeAssistantBlueprintInstaller.WriteYamlToTemp();
        try
        {
            Assert.True(File.Exists(path));
            Assert.Equal(HomeAssistantBlueprintInstaller.BlueprintYaml, File.ReadAllText(path));
        }
        finally
        {
            File.Delete(path);
        }
    }
}

public class HomeAssistantConfigTests
{
    [Fact]
    public void WebhookUrl_ComposesFromBaseAndId()
    {
        var config = new HomeAssistantConfig("http://homeassistant.local:8123", webhookId: "openburnbar_cast_recover_abc");
        Assert.Equal("http://homeassistant.local:8123/api/webhook/openburnbar_cast_recover_abc", config.WebhookUrl);
    }

    [Fact]
    public void WebhookUrl_NullWhenNoId()
    {
        Assert.Null(new HomeAssistantConfig("http://h:8123").WebhookUrl);
    }

    [Fact]
    public void SetupMode_RawValueRoundTrips()
    {
        Assert.Equal("manualWebhook", HomeAssistantSetupMode.ManualWebhook.RawValue());
        Assert.Equal(HomeAssistantSetupMode.Blueprint, HomeAssistantSetupModeExtensions.ParseSetupMode("blueprint"));
        Assert.Equal(HomeAssistantSetupMode.Rest, HomeAssistantSetupModeExtensions.ParseSetupMode("bogus"));
    }
}

public class HomeAssistantTokenStoreTests
{
    [Fact]
    public void InMemory_SaveLoadDelete()
    {
        var store = new InMemoryHomeAssistantTokenStore();
        Assert.Null(store.LoadAccessToken());
        store.SaveAccessToken("token");
        Assert.Equal("token", store.LoadAccessToken());
        store.SaveAccessToken("");
        Assert.Null(store.LoadAccessToken()); // empty -> delete
        store.SaveWebhookSecret("secret");
        Assert.Equal("secret", store.LoadWebhookSecret());
        store.DeleteWebhookSecret();
        Assert.Null(store.LoadWebhookSecret());
    }

    [Fact]
    public void SecretStoreBacked_TrimsAndDeletesOnEmpty()
    {
        var secrets = new DictionarySecretStore();
        var store = new HomeAssistantTokenStore(secrets);
        store.SaveAccessToken("  spaced-token  ");
        Assert.Equal("spaced-token", store.LoadAccessToken());
        Assert.Equal("spaced-token", secrets.Get(HomeAssistantSecretAccounts.AccessToken));
        store.SaveAccessToken("   ");
        Assert.Null(store.LoadAccessToken());
    }

    private sealed class DictionarySecretStore : IHomeAssistantSecretStore
    {
        private readonly Dictionary<string, string> _store = new();
        public string? Get(string account) => _store.TryGetValue(account, out var v) ? v : null;
        public string? GetSecret(string account) => Get(account);
        public void SetSecret(string account, string value) => _store[account] = value;
        public void DeleteSecret(string account) => _store.Remove(account);
    }
}

public class HomeAssistantConfigStoreTests
{
    private sealed class DictionaryKeyValueStore : IHomeAssistantKeyValueStore
    {
        public readonly Dictionary<string, string> Store = new();
        public int Flushes;
        public string GetString(string key, string defaultValue) => Store.TryGetValue(key, out var v) ? v : defaultValue;
        public void SetString(string key, string value) => Store[key] = value;
        public void Flush() => Flushes++;
    }

    private sealed class NullEncoder : IHomeAssistantConfigEncoder
    {
        public string? Encode(HomeAssistantConfig config) => null;
    }

    [Fact]
    public void SaveThenLoad_RoundTrips()
    {
        var settings = new DictionaryKeyValueStore();
        var store = new HomeAssistantConfigStore(settings);
        var config = new HomeAssistantConfig(
            "http://homeassistant.local:8123",
            mediaPlayerEntityId: "media_player.nest",
            mediaPlayerFriendlyName: "Nest Hub",
            webhookId: "openburnbar_cast_recover_abc",
            automationInstalled: true,
            lastTestPassed: true,
            lastVerifiedAt: new DateTimeOffset(2026, 7, 3, 12, 0, 0, TimeSpan.Zero),
            setupMode: HomeAssistantSetupMode.Blueprint);

        store.SaveConfig(config);
        var loaded = store.LoadConfig();

        Assert.Equal(config, loaded);
        Assert.True(settings.Flushes >= 1);
    }

    [Fact]
    public void Save_MirrorsWebhookUrlToLegacyKey()
    {
        var settings = new DictionaryKeyValueStore();
        var store = new HomeAssistantConfigStore(settings);
        store.SaveConfig(new HomeAssistantConfig("http://h:8123", webhookId: "openburnbar_cast_recover_abc"));
        Assert.Equal("http://h:8123/api/webhook/openburnbar_cast_recover_abc", store.LegacyWebhookUrlString);
    }

    [Fact]
    public void Load_MissingOrCorrupt_ReturnsNull()
    {
        var settings = new DictionaryKeyValueStore();
        var store = new HomeAssistantConfigStore(settings);
        Assert.Null(store.LoadConfig());
        settings.Store[HomeAssistantConfigStore.ConfigKey] = "{ not valid json";
        Assert.Null(store.LoadConfig());
    }

    [Fact]
    public void Save_EncodeFailure_SkipsWrite()
    {
        var settings = new DictionaryKeyValueStore();
        var store = new HomeAssistantConfigStore(settings, new NullEncoder());
        store.SaveConfig(new HomeAssistantConfig("http://h:8123"));
        Assert.False(settings.Store.ContainsKey(HomeAssistantConfigStore.ConfigKey));
    }

    [Fact]
    public void Clear_EmptiesBothKeys()
    {
        var settings = new DictionaryKeyValueStore();
        var store = new HomeAssistantConfigStore(settings);
        store.SaveConfig(new HomeAssistantConfig("http://h:8123", webhookId: "openburnbar_cast_recover_abc"));
        store.Clear();
        Assert.Equal(string.Empty, store.LegacyWebhookUrlString);
        Assert.Null(store.LoadConfig());
    }
}
