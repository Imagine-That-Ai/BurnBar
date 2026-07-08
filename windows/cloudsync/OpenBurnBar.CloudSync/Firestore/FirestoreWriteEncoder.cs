using System;
using System.Collections.Generic;
using System.Linq;
using System.Text.Json.Nodes;
using OpenBurnBar.CloudSync.Gateway;

namespace OpenBurnBar.CloudSync.Firestore;

/// <summary>
/// Builds the Firestore REST/RPC v1 request bodies for the write + query RPCs:
/// <c>documents:commit</c> writes (with field transforms + update masks) and
/// <c>documents:runQuery</c> structured queries. Kept separate from the gateway so
/// the wire shapes are unit-testable in isolation.
/// </summary>
public static class FirestoreWriteEncoder
{
    /// <summary>
    /// Build a single <c>documents:commit</c> "write" for a set/merge on
    /// <paramref name="documentName"/>. Literal fields go under <c>update.fields</c>;
    /// <see cref="CloudSyncValue.ServerTimestamp"/> becomes an <c>updateTransforms</c>
    /// entry (REQUEST_TIME); <see cref="CloudSyncValue.Delete"/> is omitted from the
    /// body and (on merge) named in the <c>updateMask</c> so the server removes it.
    /// On merge, the update mask lists exactly the written + deleted fields.
    /// </summary>
    public static JsonObject BuildSetWrite(string documentName, CloudSyncFields data, bool merge)
    {
        var literalFields = new JsonObject();
        var transforms = new JsonArray();
        var maskPaths = new List<string>();

        foreach (KeyValuePair<string, CloudSyncValue> kv in data.Values.OrderBy(k => k.Key, StringComparer.Ordinal))
        {
            switch (kv.Value)
            {
                case CloudSyncValue.ServerTimestamp:
                    transforms.Add(new JsonObject
                    {
                        ["fieldPath"] = kv.Key,
                        ["setToServerValue"] = "REQUEST_TIME",
                    });
                    break;
                case CloudSyncValue.Delete:
                    // Field deletion: omit from body, name in mask (merge removes it).
                    maskPaths.Add(kv.Key);
                    break;
                default:
                    literalFields[kv.Key] = FirestoreValueCodec.Encode(kv.Value);
                    maskPaths.Add(kv.Key);
                    break;
            }
        }

        var update = new JsonObject { ["name"] = documentName };
        update["fields"] = literalFields;

        var write = new JsonObject { ["update"] = update };

        if (transforms.Count > 0)
        {
            write["updateTransforms"] = transforms;
        }

        // A merge write scopes the change with an updateMask; a full set omits it
        // so unlisted fields are replaced/removed by the server.
        if (merge)
        {
            var fieldPaths = new JsonArray();
            foreach (string path in maskPaths.OrderBy(p => p, StringComparer.Ordinal))
            {
                fieldPaths.Add(path);
            }
            write["updateMask"] = new JsonObject { ["fieldPaths"] = fieldPaths };
        }

        return write;
    }

    /// <summary>Build a <c>documents:commit</c> "delete" write for a document resource name.</summary>
    public static JsonObject BuildDeleteWrite(string documentName) =>
        new() { ["delete"] = documentName };

    /// <summary>Wrap writes into a commit request body, optionally within a transaction.</summary>
    public static JsonObject BuildCommitBody(IEnumerable<JsonObject> writes, string? transactionId = null)
    {
        var writesArray = new JsonArray();
        foreach (JsonObject write in writes) writesArray.Add(write);
        var body = new JsonObject { ["writes"] = writesArray };
        if (transactionId is { Length: > 0 })
        {
            body["transaction"] = transactionId;
        }
        return body;
    }

    /// <summary>
    /// Build a <c>documents:runQuery</c> body for the given spec. The
    /// <c>structuredQuery.from.collectionId</c> is the last segment of the
    /// collection path; the request is parented at the collection's parent path
    /// (see <see cref="FirestoreDatabase.RunQueryUrl"/>).
    /// </summary>
    public static JsonObject BuildRunQueryBody(CloudSyncQuerySpec spec)
    {
        string collectionId = FirestoreDatabase.LeafId(spec.CollectionPath);
        var structured = new JsonObject
        {
            ["from"] = new JsonArray { new JsonObject { ["collectionId"] = collectionId } },
        };

        if (spec.Filters.Count == 1)
        {
            structured["where"] = BuildFieldFilter(spec.Filters[0]);
        }
        else if (spec.Filters.Count > 1)
        {
            var filters = new JsonArray();
            foreach (CloudSyncFieldFilter filter in spec.Filters) filters.Add(BuildFieldFilter(filter));
            structured["where"] = new JsonObject
            {
                ["compositeFilter"] = new JsonObject { ["op"] = "AND", ["filters"] = filters },
            };
        }

        if (spec.Order is { } order)
        {
            structured["orderBy"] = new JsonArray
            {
                new JsonObject
                {
                    ["field"] = new JsonObject { ["fieldPath"] = order.Field },
                    ["direction"] = order.Descending ? "DESCENDING" : "ASCENDING",
                },
            };
        }

        if (spec.Limit is { } limit)
        {
            structured["limit"] = limit;
        }

        return new JsonObject { ["structuredQuery"] = structured };
    }

    /// <summary>The parent path a runQuery is rooted at (collection path minus its leaf).</summary>
    public static string QueryParentPath(string collectionPath)
    {
        string normalized = collectionPath.Trim('/');
        int lastSlash = normalized.LastIndexOf('/');
        return lastSlash < 0 ? string.Empty : normalized[..lastSlash];
    }

    private static JsonObject BuildFieldFilter(CloudSyncFieldFilter filter) => new()
    {
        ["fieldFilter"] = new JsonObject
        {
            ["field"] = new JsonObject { ["fieldPath"] = filter.Field },
            ["op"] = filter.Operator switch
            {
                CloudSyncQueryOperator.GreaterThan => "GREATER_THAN",
                CloudSyncQueryOperator.EqualTo => "EQUAL",
                _ => throw new ArgumentOutOfRangeException(nameof(filter)),
            },
            ["value"] = FirestoreValueCodec.Encode(filter.Value),
        },
    };
}
