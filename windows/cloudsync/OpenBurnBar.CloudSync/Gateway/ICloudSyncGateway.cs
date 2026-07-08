using System;
using System.Collections.Generic;
using System.Threading;
using System.Threading.Tasks;
using OpenBurnBar.CloudSync.Firestore;

namespace OpenBurnBar.CloudSync.Gateway;

// C# port of AgentLens/Services/CloudSync/CloudSyncFirestoreGateway.swift.
//
// The macOS protocols are synchronous-looking but async at the call sites; C#
// makes the async explicit (Task + CancellationToken). Swift's untyped
// `[String: Any]` document body becomes the typed CloudSyncFields, and the
// untyped `Any` query operand becomes CloudSyncValue.

/// <summary>Abstract gateway for Firestore operations used by CloudSync domain services.</summary>
public interface ICloudSyncGateway
{
    ICloudSyncCollection Collection(string collectionPath);

    ICloudSyncWriteBatch Batch();

    /// <summary>
    /// Runs <paramref name="updateBlock"/> inside a transaction; the block returns
    /// <c>true</c> to commit its buffered writes, <c>false</c> to abort. Returns the
    /// block's commit decision (parity with the Swift <c>runTransaction</c> Bool).
    /// </summary>
    Task<bool> RunTransactionAsync(
        Func<ICloudSyncTransaction, Task<bool>> updateBlock,
        CancellationToken cancellationToken = default);
}

public interface ICloudSyncCollection
{
    ICloudSyncDocument Document(string documentPath);
    ICloudSyncQuery WhereGreaterThan(string field, CloudSyncValue value);
    ICloudSyncQuery WhereEqualTo(string field, CloudSyncValue value);
    ICloudSyncQuery OrderBy(string field, bool descending);
    ICloudSyncQuery Limit(int limit);
    Task<ICloudSyncQuerySnapshot> GetDocumentsAsync(CancellationToken cancellationToken = default);
}

public interface ICloudSyncDocument
{
    /// <summary>The document's path (e.g. <c>users/u1/usage/e1</c>).</summary>
    string Path { get; }

    ICloudSyncCollection Collection(string collectionPath);
    Task<CloudSyncFields?> GetDataAsync(CancellationToken cancellationToken = default);
    Task SetDataAsync(CloudSyncFields data, bool merge, CancellationToken cancellationToken = default);
    Task DeleteDocumentAsync(CancellationToken cancellationToken = default);
}

public interface ICloudSyncQuery
{
    ICloudSyncQuery WhereGreaterThan(string field, CloudSyncValue value);
    ICloudSyncQuery WhereEqualTo(string field, CloudSyncValue value);
    ICloudSyncQuery OrderBy(string field, bool descending);
    ICloudSyncQuery Limit(int limit);
    Task<ICloudSyncQuerySnapshot> GetDocumentsAsync(CancellationToken cancellationToken = default);
}

public interface ICloudSyncWriteBatch
{
    void SetData(CloudSyncFields data, ICloudSyncDocument document, bool merge);
    void DeleteDocument(ICloudSyncDocument document);
    Task CommitAsync(CancellationToken cancellationToken = default);
}

public interface ICloudSyncTransaction
{
    Task<CloudSyncFields?> GetDataAsync(ICloudSyncDocument document, CancellationToken cancellationToken = default);
    void SetData(CloudSyncFields data, ICloudSyncDocument document, bool merge);
}

public interface ICloudSyncQuerySnapshot
{
    IReadOnlyList<ICloudSyncDocumentSnapshot> Documents { get; }
}

public interface ICloudSyncDocumentSnapshot
{
    string DocumentId { get; }
    CloudSyncFields Data { get; }
}

// ── Shared query spec value types (used by both the REST and Fake gateways) ──

public enum CloudSyncQueryOperator
{
    GreaterThan,
    EqualTo,
}

public sealed record CloudSyncFieldFilter(string Field, CloudSyncQueryOperator Operator, CloudSyncValue Value);

public sealed record CloudSyncOrder(string Field, bool Descending);

/// <summary>An immutable, composable description of a collection query.</summary>
public sealed record CloudSyncQuerySpec(
    string CollectionPath,
    IReadOnlyList<CloudSyncFieldFilter> Filters,
    CloudSyncOrder? Order,
    int? Limit)
{
    public static CloudSyncQuerySpec ForCollection(string collectionPath) =>
        new(collectionPath, Array.Empty<CloudSyncFieldFilter>(), Order: null, Limit: null);

    public CloudSyncQuerySpec With(CloudSyncFieldFilter filter)
    {
        var filters = new List<CloudSyncFieldFilter>(Filters) { filter };
        return this with { Filters = filters };
    }

    public CloudSyncQuerySpec With(CloudSyncOrder order) => this with { Order = order };

    public CloudSyncQuerySpec WithLimit(int limit) => this with { Limit = limit };
}
