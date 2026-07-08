using System.Collections.Generic;
using System.Linq;

namespace OpenBurnBar.App.TextExpansion;

/// <summary>
/// Supplies the active snippet set the runtime controller matches against. This is
/// the "store" seam of the portable core: on Windows the production implementation
/// is DB-backed (windows/storage/OpenBurnBar.Storage/TextExpansionSnippetWriteSeam,
/// the SQLCipher peer of the Mac GRDB <c>TextExpansionSnippetStore</c>); an in-memory
/// or JSON-snapshot implementation is used in tests and for the App-Group cache.
/// </summary>
/// <remarks>
/// Mirrors how the Mac <c>TextExpansionRuntimeController</c> refreshes a cached
/// snippet set off the hot path and reads that cache per keystroke — the controller
/// never blocks on the store during keystroke handling.
/// </remarks>
public interface ITextExpansionSnippetSource
{
    /// <summary>Enabled, non-deleted snippets that are in scope for <paramref name="surface"/> (and app/thread).</summary>
    IReadOnlyList<TextExpansionSnippet> LoadEnabled(
        TextExpansionSurface surface,
        string? bundleIdentifier = null,
        string? threadId = null);
}

/// <summary>
/// A simple in-memory snippet source. Applies the same active + scope filter the Mac
/// controller applies when it bootstraps its cache from the snapshot.
/// </summary>
public sealed class InMemoryTextExpansionSnippetSource : ITextExpansionSnippetSource
{
    private readonly List<TextExpansionSnippet> _snippets;

    public InMemoryTextExpansionSnippetSource(IEnumerable<TextExpansionSnippet>? snippets = null)
    {
        _snippets = snippets?.ToList() ?? new List<TextExpansionSnippet>();
    }

    public void Replace(IEnumerable<TextExpansionSnippet> snippets)
    {
        _snippets.Clear();
        _snippets.AddRange(snippets);
    }

    public IReadOnlyList<TextExpansionSnippet> LoadEnabled(
        TextExpansionSurface surface,
        string? bundleIdentifier = null,
        string? threadId = null)
    {
        return _snippets
            .Where(s => s.IsActive && s.Scope.Allows(surface, bundleIdentifier, threadId))
            .ToList();
    }
}
