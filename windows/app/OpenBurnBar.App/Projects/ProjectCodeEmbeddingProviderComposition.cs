using System;
using OpenBurnBar.App.Configuration;
using OpenBurnBar.App.MemorySearch.Search;
using OpenBurnBar.App.Presentation.Projects;
using OpenBurnBar.App.Settings.Winui;

namespace OpenBurnBar.App.Projects;

/// <summary>
/// Selects the same persisted embedding provider ids as macOS. Deterministic is
/// the offline default; OpenAI is opt-in and can only obtain its key from the
/// protected provider secret store. A missing key or invalid configuration falls
/// back to deterministic indexing and records a non-secret diagnostic.
/// </summary>
internal static class ProjectCodeEmbeddingProviderComposition
{
    private const string OpenAiApiKeySecret = "api-key";

    public static IProjectCodeEmbeddingProvider? TryCreate()
    {
        string provider = WindowsSettingsComposition.SharedPersistence
            .Read("indexEmbeddingProvider", "deterministic")
            .Trim()
            .ToLowerInvariant();
        if (provider != "openai")
        {
            return null;
        }

        string model = WindowsSettingsComposition.SharedPersistence
            .Read("indexOpenAIModel", "text-embedding-3-small")
            .Trim();
        string secretName = AppSecretNames.ProviderSecret("openai", "project-code", OpenAiApiKeySecret);
        string apiKey = AppConfiguration.Current.SecretStore.Read(secretName) ?? string.Empty;
        if (apiKey.Length == 0)
        {
            AppDiagnostics.LogEvent("project-code.embedding", "openai_unconfigured");
            return null;
        }

        string baseUrl = Environment.GetEnvironmentVariable("OPENBURNBAR_OPENAI_BASE_URL")
            ?? "https://api.openai.com/v1";
        try
        {
            var providerAdapter = new OpenAIEmbeddingProvider(
                apiKey,
                model,
                baseUrl: baseUrl);
            return new OpenAiProjectCodeEmbeddingProvider(providerAdapter);
        }
        catch (OpenAIEmbeddingProviderException exception)
        {
            AppDiagnostics.LogEvent("project-code.embedding", "openai_invalid_" + exception.Kind);
            return null;
        }
    }

    private sealed class OpenAiProjectCodeEmbeddingProvider : IProjectCodeEmbeddingProvider
    {
        private readonly OpenAIEmbeddingProvider _provider;

        public OpenAiProjectCodeEmbeddingProvider(OpenAIEmbeddingProvider provider)
        {
            _provider = provider;
            Dimensions = provider.Descriptor.Dimensions;
            Version = EmbeddingIdentity.VersionId(provider.Descriptor);
        }

        public int Dimensions { get; }

        public string Version { get; }

        public float[] Embed(string text) =>
            _provider.EmbeddingAsync(text).GetAwaiter().GetResult();
    }
}
