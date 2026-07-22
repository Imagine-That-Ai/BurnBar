using Xunit;

namespace OpenBurnBar.App.ManagedAgentRuntime.Tests;

/// <summary>
/// Serializes live gateway tests that derive their listener port from the test
/// process. These classes otherwise race for the same HttpListener prefix when
/// the solution runner executes them concurrently.
/// </summary>
[CollectionDefinition(Name, DisableParallelization = true)]
public sealed class LoopbackGatewayCollection
{
    public const string Name = "LoopbackGateway";
}
