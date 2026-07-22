using OpenBurnBar.ComputerUse.Core.Browser;
using Xunit;

namespace OpenBurnBar.App.Configuration.Tests;

public sealed class WindowsBrowserComputerUseServiceTests
{
    [Fact]
    public void ExplicitDirectProcessConfigurationMakesRuntimeAvailable()
    {
        string? priorExecutable = Environment.GetEnvironmentVariable(ProcessBrowserDriver.ExecutableEnv);
        string? priorArguments = Environment.GetEnvironmentVariable(ProcessBrowserDriver.ArgumentsEnv);
        try
        {
            Environment.SetEnvironmentVariable(ProcessBrowserDriver.ExecutableEnv, "browser-bridge.exe");
            Environment.SetEnvironmentVariable(ProcessBrowserDriver.ArgumentsEnv, "[\"--stdio\",\"jsonl\"]");

            var service = new WindowsBrowserComputerUseService();

            Assert.True(service.IsAvailable);
            Assert.Contains("explicit", service.RuntimeStatus, StringComparison.OrdinalIgnoreCase);
        }
        finally
        {
            Environment.SetEnvironmentVariable(ProcessBrowserDriver.ExecutableEnv, priorExecutable);
            Environment.SetEnvironmentVariable(ProcessBrowserDriver.ArgumentsEnv, priorArguments);
        }
    }

    [Fact]
    public void MalformedExplicitArgumentsFailClosed()
    {
        string? priorExecutable = Environment.GetEnvironmentVariable(ProcessBrowserDriver.ExecutableEnv);
        string? priorArguments = Environment.GetEnvironmentVariable(ProcessBrowserDriver.ArgumentsEnv);
        try
        {
            Environment.SetEnvironmentVariable(ProcessBrowserDriver.ExecutableEnv, "browser-bridge.exe");
            Environment.SetEnvironmentVariable(ProcessBrowserDriver.ArgumentsEnv, "not-json");

            var service = new WindowsBrowserComputerUseService();

            Assert.False(service.IsAvailable);
            Assert.Contains("valid JSON", service.RuntimeStatus, StringComparison.Ordinal);
        }
        finally
        {
            Environment.SetEnvironmentVariable(ProcessBrowserDriver.ExecutableEnv, priorExecutable);
            Environment.SetEnvironmentVariable(ProcessBrowserDriver.ArgumentsEnv, priorArguments);
        }
    }
}
