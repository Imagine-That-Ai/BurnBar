using OpenBurnBar.App.Configuration;
using Xunit;

namespace OpenBurnBar.App.Configuration.Tests;

public sealed class RuntimeDataModeTests
{
    private const string SampleEnv = "OPENBURNBAR_SAMPLE_MODE";

    [Theory]
    [InlineData(null)]
    [InlineData("")]
    [InlineData("0")]
    [InlineData("false")]
    public void SampleModeEnabled_is_false_when_env_unset_or_not_truthy(string? value)
    {
        try
        {
            Environment.SetEnvironmentVariable(SampleEnv, value);
            Assert.False(RuntimeDataMode.SampleModeEnabled);
        }
        finally
        {
            Environment.SetEnvironmentVariable(SampleEnv, null);
        }
    }

    [Theory]
    [InlineData("1")]
    [InlineData("true")]
    [InlineData("TRUE")]
    [InlineData("yes")]
    [InlineData("sample")]
    [InlineData("demo")]
    public void SampleModeEnabled_is_true_for_opt_in_truthy_values(string value)
    {
        try
        {
            Environment.SetEnvironmentVariable(SampleEnv, value);
            Assert.True(RuntimeDataMode.SampleModeEnabled);
        }
        finally
        {
            Environment.SetEnvironmentVariable(SampleEnv, null);
        }
    }

    [Fact]
    public void EmptyStateDetail_without_sample_mode_names_missing_source_and_opt_in_path()
    {
        try
        {
            Environment.SetEnvironmentVariable(SampleEnv, null);
            string detail = RuntimeDataMode.EmptyStateDetail("Firebase quota snapshots");
            Assert.Contains("Firebase quota snapshots", detail);
            Assert.Contains("OPENBURNBAR_SAMPLE_MODE=1", detail);
            Assert.DoesNotContain("Sample mode is enabled", detail);
        }
        finally
        {
            Environment.SetEnvironmentVariable(SampleEnv, null);
        }
    }

    [Fact]
    public void EmptyStateDetail_with_sample_mode_warns_demo_data_is_labeled()
    {
        try
        {
            Environment.SetEnvironmentVariable(SampleEnv, "1");
            string detail = RuntimeDataMode.EmptyStateDetail("SQLCipher usage database");
            Assert.Equal(
                "Sample mode is enabled. Demo data is labeled and should not be treated as live usage.",
                detail);
        }
        finally
        {
            Environment.SetEnvironmentVariable(SampleEnv, null);
        }
    }

    [Fact]
    public void EmptyStateDetail_sample_mode_with_live_data_uses_connect_copy_not_demo_labeled()
    {
        try
        {
            Environment.SetEnvironmentVariable(SampleEnv, "1");
            string detail = RuntimeDataMode.EmptyStateDetail("SQLCipher usage database", hasLiveData: true);
            Assert.Contains("Connect SQLCipher usage database", detail);
            Assert.DoesNotContain("Demo data is labeled", detail);
            Assert.DoesNotContain("Sample mode is enabled", detail);
        }
        finally
        {
            Environment.SetEnvironmentVariable(SampleEnv, null);
        }
    }
}