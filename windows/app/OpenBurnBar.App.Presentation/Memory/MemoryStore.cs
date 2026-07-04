using System;
using System.Collections.Generic;
using System.Linq;
using System.Threading.Tasks;

namespace OpenBurnBar.App.Presentation.Memories;

/// <summary>
/// Read-only memory store for Windows v1: surfaces synced approved chat facts.
/// Approve/reject stays Mac-owned (G4); <see cref="SetStatusAsync"/> is disabled.
/// Defaults to an empty fact list — never invents demo memories.
/// </summary>
public sealed class MemoryStore
{
    private readonly IReadOnlyList<SyncedMemoryFact> _facts;

    public MemoryStore(IReadOnlyList<SyncedMemoryFact>? facts = null)
    {
        _facts = facts ?? Array.Empty<SyncedMemoryFact>();
    }

    public Task<MemoryPage> LoadPageAsync(MemoryPageRequest request)
    {
        var filtered = _facts
            .Where(f => MatchesScope(f, request.Scope))
            .Select(ToMemory)
            .Where(m => request.IncludeQuarantined || m.ReviewStatus == MemoryReviewStatus.Approved)
            .OrderByDescending(m => m.UpdatedAt)
            .ToList();

        var page = Math.Max(1, request.Page);
        var pageSize = Math.Max(1, request.PageSize);
        var skip = (page - 1) * pageSize;
        var slice = filtered.Skip(skip).Take(pageSize).ToList();
        return Task.FromResult(new MemoryPage(slice, page, pageSize, filtered.Count));
    }

    public Task<string?> OpenBodyAsync(string memoryId)
    {
        var fact = _facts.FirstOrDefault(f => f.Id == memoryId);
        return Task.FromResult(fact?.PlaintextBody);
    }

    public Task<bool> SetStatusAsync(string memoryId, MemoryReviewStatus status)
    {
        _ = memoryId;
        _ = status;
        throw new MemoryReviewMacOnlyException();
    }

    private static bool MatchesScope(SyncedMemoryFact fact, MemoryScope scope)
    {
        if (scope.UserId is not null && fact.Scope.UserId != scope.UserId) return false;
        if (scope.AgentId is not null && fact.Scope.AgentId != scope.AgentId) return false;
        if (scope.AppId is not null && fact.Scope.AppId != scope.AppId) return false;
        return true;
    }

    private static Memory ToMemory(SyncedMemoryFact fact)
    {
        return new Memory(
            Id: fact.Id,
            Kind: fact.Kind,
            Scope: fact.Scope,
            Confidence: fact.Confidence,
            BodyRedacted: fact.BodyRedacted,
            ReviewStatus: fact.ReviewStatus,
            Citations: fact.Citations,
            ValidFrom: fact.ValidFrom,
            CreatedAt: fact.CreatedAt,
            UpdatedAt: fact.UpdatedAt,
            SourceKind: MemorySourceKind.Chat);
    }
}

/// <summary>Approve/reject is Mac-owned; Windows surfaces the honest message via <see cref="IFriendlyError"/>.</summary>
public sealed class MemoryReviewMacOnlyException : InvalidOperationException, IFriendlyError
{
    public MemoryReviewMacOnlyException()
        : base("Review on your Mac — quarantined facts never leave the device by design.")
    {
    }

    public string? FriendlyMessage => Message;
}

public sealed record SyncedMemoryFact(
    string Id,
    MemoryKind Kind,
    MemoryScope Scope,
    double Confidence,
    string BodyRedacted,
    string PlaintextBody,
    MemoryReviewStatus ReviewStatus,
    IReadOnlyList<MemoryCitation> Citations,
    DateTimeOffset ValidFrom,
    DateTimeOffset CreatedAt,
    DateTimeOffset UpdatedAt);
