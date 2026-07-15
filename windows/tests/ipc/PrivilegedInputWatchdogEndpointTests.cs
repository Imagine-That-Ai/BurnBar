using System;
using System.IO;
using OpenBurnBar.Pal.Ipc.Windows;
using Xunit;

namespace OpenBurnBar.Pal.Ipc.Tests;

public sealed class PrivilegedInputWatchdogEndpointTests
{
    [Fact]
    public void UnsignedTestAssemblyCannotSatisfyFirstPartyPublisherGate()
    {
        if (!OperatingSystem.IsWindows())
        {
            return;
        }

        string assembly = typeof(PrivilegedInputWatchdogEndpointTests).Assembly.Location;
        Assert.True(File.Exists(assembly));
        Assert.False(PeerImageValidator.HasPublisherSubject(
            assembly,
            PrivilegedInputWatchdogEndpoint.ExpectedPublisherSubject));
    }

    [Fact]
    public void PipeIdentityIsWindowsOnlyAndBounded()
    {
        if (!OperatingSystem.IsWindows())
        {
            return;
        }

        string pipeName = PrivilegedInputWatchdogEndpoint.CurrentPipeName();
        Assert.StartsWith("OpenBurnBar.PrivilegedInputWatchdog.v1.", pipeName, StringComparison.Ordinal);
        Assert.InRange(pipeName.Length, 45, 80);
    }
}
