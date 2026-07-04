using System;

namespace OpenBurnBar.CloudSync.Firestore;

/// <summary>
/// Firestore project/database identity plus the REST URL + resource-name math.
/// A Firestore document's fully-qualified resource name is
/// <c>projects/{project}/databases/{db}/documents/{path}</c> and its REST URL is
/// <c>{host}/v1/{name}</c>. The default database id is the literal <c>(default)</c>.
/// </summary>
public sealed class FirestoreDatabase
{
    public const string DefaultDatabaseId = "(default)";
    public const string DefaultHost = "https://firestore.googleapis.com";

    public FirestoreDatabase(string projectId, string databaseId = DefaultDatabaseId, string host = DefaultHost)
    {
        if (string.IsNullOrWhiteSpace(projectId))
        {
            throw new ArgumentException("projectId is required.", nameof(projectId));
        }
        ProjectId = projectId;
        DatabaseId = string.IsNullOrWhiteSpace(databaseId) ? DefaultDatabaseId : databaseId;
        Host = host.TrimEnd('/');
    }

    public string ProjectId { get; }
    public string DatabaseId { get; }
    public string Host { get; }

    /// <summary><c>projects/{project}/databases/{db}/documents</c> — the collection-group root.</summary>
    public string DocumentsRoot => $"projects/{ProjectId}/databases/{DatabaseId}/documents";

    /// <summary>The fully-qualified resource name for a document at <paramref name="documentPath"/>.</summary>
    public string DocumentName(string documentPath) => $"{DocumentsRoot}/{NormalizePath(documentPath)}";

    /// <summary>The REST URL <c>{host}/v1/{name}</c> for a document GET / PATCH / DELETE.</summary>
    public string DocumentUrl(string documentPath) => $"{Host}/v1/{DocumentName(documentPath)}";

    /// <summary>The <c>documents:commit</c> RPC URL (batched writes + transforms).</summary>
    public string CommitUrl => $"{Host}/v1/{DocumentsRoot}:commit";

    /// <summary>The <c>documents:runQuery</c> RPC URL, parented at <paramref name="parentPath"/> (empty = root).</summary>
    public string RunQueryUrl(string parentPath)
    {
        string parent = string.IsNullOrEmpty(parentPath) ? DocumentsRoot : $"{DocumentsRoot}/{NormalizePath(parentPath)}";
        return $"{Host}/v1/{parent}:runQuery";
    }

    /// <summary>
    /// Splits a Firestore document path into its parent collection path and the
    /// leaf document id. <c>users/u1/usage/e1</c> -&gt; ("users/u1/usage", "e1").
    /// </summary>
    public static (string CollectionPath, string DocumentId) SplitDocumentPath(string documentPath)
    {
        string normalized = NormalizePath(documentPath);
        int lastSlash = normalized.LastIndexOf('/');
        if (lastSlash < 0)
        {
            throw new ArgumentException(
                $"'{documentPath}' is not a document path (needs collection/doc segments).", nameof(documentPath));
        }
        return (normalized[..lastSlash], normalized[(lastSlash + 1)..]);
    }

    /// <summary>The last path segment (document id) of a resource name or path.</summary>
    public static string LeafId(string pathOrName)
    {
        string normalized = pathOrName.TrimEnd('/');
        int lastSlash = normalized.LastIndexOf('/');
        return lastSlash < 0 ? normalized : normalized[(lastSlash + 1)..];
    }

    internal static string NormalizePath(string path) => path.Trim('/');
}
