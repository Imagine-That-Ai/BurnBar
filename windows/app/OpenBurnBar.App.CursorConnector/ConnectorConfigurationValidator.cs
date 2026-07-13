using System;
using System.Collections.Generic;
using System.Linq;

namespace OpenBurnBar.App.CursorConnector;

/// <summary>
/// Validates the configuration invariants that can be checked without touching
/// Windows-only secrets or processes. Provider API-key validation remains in the
/// injected session step, which owns the DPAPI/CNG-backed secret store.
/// </summary>
public static class ConnectorConfigurationValidator
{
    /// <summary>Matches the Mac connector's preflight validation contract.</summary>
    public static void Validate(CursorConnectorConfig config)
    {
        ArgumentNullException.ThrowIfNull(config);

        var providerConfigs = config.ProviderConfigs ?? new List<ConnectorProviderConfig>();
        var enabledProviders = providerConfigs
            .Where(provider => provider is not null && provider.Enabled)
            .ToArray();

        if (enabledProviders.Length == 0)
        {
            throw new ConnectorConfigException("Enable at least one provider before connecting.");
        }

        var exposedModels = enabledProviders
            .SelectMany(provider => ExposedModels(provider!))
            .ToArray();
        if (exposedModels.Length == 0)
        {
            throw new ConnectorConfigException("Choose at least one supported model to expose to Cursor.");
        }
    }

    private static IEnumerable<string> ExposedModels(ConnectorProviderConfig provider)
    {
        if (provider.SelectedModels is not null)
        {
            foreach (var model in provider.SelectedModels)
            {
                if (model is not null)
                {
                    yield return model;
                }
            }
        }

        if (provider.CustomModels is not null)
        {
            foreach (var model in provider.CustomModels)
            {
                if (model is not null)
                {
                    yield return model;
                }
            }
        }
    }
}
