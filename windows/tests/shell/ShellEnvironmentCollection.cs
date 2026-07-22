using Xunit;

namespace OpenBurnBar.App.Shell.Tests;

/// <summary>
/// Serializes tests that temporarily modify process-wide profile and app-data
/// environment variables.
/// </summary>
[CollectionDefinition(Name, DisableParallelization = true)]
public sealed class ShellEnvironmentCollection
{
    public const string Name = "Shell environment";
}
