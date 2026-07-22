using System;
using System.Collections.Generic;
using OpenBurnBar.App.CursorConnector;
using Xunit;

namespace OpenBurnBar.App.CursorConnector.Tests;

/// <summary>Portable preflight validation for connector startup.</summary>
public sealed class ConnectorConfigurationValidatorTests
{
    [Fact]
    public void Validate_AcceptsEnabledProviderWithSelectedOrCustomModel()
    {
        var selected = CursorConnectorConfig.CreateDefault();
        selected.ProviderConfigs[0].Enabled = true;
        ConnectorConfigurationValidator.Validate(selected);

        var custom = CursorConnectorConfig.CreateDefault();
        custom.ProviderConfigs[1].Enabled = true;
        custom.ProviderConfigs[1].SelectedModels = new List<string>();
        custom.ProviderConfigs[1].CustomModels = new List<string> { "custom-model" };
        ConnectorConfigurationValidator.Validate(custom);
    }

    [Fact]
    public void Validate_RejectsNullOrEmptyProviderSet()
    {
        Assert.Throws<ArgumentNullException>(() => ConnectorConfigurationValidator.Validate(null!));

        var config = CursorConnectorConfig.CreateDefault();
        config.ProviderConfigs.Clear();
        var error = Assert.Throws<ConnectorConfigException>(() => ConnectorConfigurationValidator.Validate(config));
        Assert.Equal("Enable at least one provider before connecting.", error.Message);
    }

    [Fact]
    public void Validate_RejectsEnabledProvidersWithNoModels()
    {
        var config = CursorConnectorConfig.CreateDefault();
        config.ProviderConfigs[2].Enabled = true;
        config.ProviderConfigs[2].SelectedModels.Clear();
        config.ProviderConfigs[2].CustomModels.Clear();

        var error = Assert.Throws<ConnectorConfigException>(() => ConnectorConfigurationValidator.Validate(config));

        Assert.Equal("Choose at least one supported model to expose to Cursor.", error.Message);
    }
}
