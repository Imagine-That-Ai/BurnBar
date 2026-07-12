using Xunit;

namespace OpenBurnBar.App.Storage.Tests;

[CollectionDefinition(Name, DisableParallelization = true)]
public sealed class WindowsStorageTestCollection
{
    public const string Name = "WindowsStorageDevHost";
}
