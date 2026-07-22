using System;

namespace OpenBurnBar.App.Presentation.Projects;

/// <summary>
/// Synchronous embedding boundary used by the durable project-code store.
/// The store runs indexing and query work off the UI thread; adapters may bridge
/// an async provider, but they must preserve the descriptor identity and vector
/// dimensions for the lifetime of one store instance.
/// </summary>
public interface IProjectCodeEmbeddingProvider
{
    int Dimensions { get; }

    string Version { get; }

    float[] Embed(string text);
}
