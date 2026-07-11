using System;
using System.Collections.Generic;
using System.Linq;

namespace OpenBurnBar.Integrations.Mercury.Consent;

/// <summary>
/// Mercury mirror-consent grant ledger ported from
/// <c>AgentLens/Services/Media/MercuryConsentStore.swift</c>.
///
/// A mirror auto-accept grant is scoped to the verified connection and, when
/// present, the viewer-device / control-authority peer identifiers. The security
/// invariants preserved here:
/// <list type="bullet">
///   <item>Auto-accept requires the declared control-authority peer node id to
///     match the actually-connected remote peer (<see cref="PeerNodeIdsMatch"/>);
///     an unbound "always allow" bit is never honored.</item>
///   <item>Grants expire after a fixed TTL and are pruned before every decision.</item>
///   <item>Persistence FAILS CLOSED: a failed encode leaves the stored ledger
///     intact rather than wiping the user's consent record.</item>
/// </list>
/// </summary>
public sealed class MercuryConsentStore
{
    /// <summary>Grant time-to-live: 30 days (parity: grantTTL).</summary>
    public static readonly TimeSpan GrantTtl = TimeSpan.FromDays(30);

    private readonly IMercuryConsentPersistence _persistence;
    private readonly Func<IReadOnlyList<MirrorAutoAcceptGrant>, byte[]> _encodeGrants;
    private readonly Action<string, int>? _encodeFaultLogger;

    private readonly List<MirrorAutoAcceptGrant> _grants;
    private bool _rememberAcceptedMirrorPeers;

    public MercuryConsentStore(
        IMercuryConsentPersistence? persistence = null,
        Func<IReadOnlyList<MirrorAutoAcceptGrant>, byte[]>? encodeGrants = null,
        Func<byte[], IReadOnlyList<MirrorAutoAcceptGrant>>? decodeGrants = null,
        Action<string, int>? encodeFaultLogger = null)
    {
        _persistence = persistence ?? new InMemoryMercuryConsentPersistence();
        _encodeGrants = encodeGrants ?? MercuryConsentCodec.Encode;
        _encodeFaultLogger = encodeFaultLogger;
        var decoder = decodeGrants ?? MercuryConsentCodec.Decode;

        _rememberAcceptedMirrorPeers = _persistence.LoadRememberFlag();
        var stored = _persistence.LoadGrantData();
        _grants = stored is null ? new List<MirrorAutoAcceptGrant>() : new List<MirrorAutoAcceptGrant>(SafeDecode(stored, decoder));

        PruneExpired(DateTimeOffset.UtcNow);
    }

    /// <summary>Whether accepted mirror peers are remembered for auto-accept.</summary>
    public bool RememberAcceptedMirrorPeers
    {
        get => _rememberAcceptedMirrorPeers;
        set
        {
            _rememberAcceptedMirrorPeers = value;
            _persistence.SaveRememberFlag(value);
        }
    }

    public IReadOnlyList<MirrorAutoAcceptGrant> Grants => _grants;

    public int ActiveGrantCount => _grants.Count;

    public void RefreshExpiredMirrorAutoAcceptGrants(DateTimeOffset now) => PruneExpired(now);

    /// <summary>
    /// Whether an incoming mirror request may be auto-accepted (parity:
    /// canAutoAccept). Requires the declared control-authority peer to match the
    /// connected remote peer AND a live, unexpired grant for the exact scope.
    /// On a hit, stamps <c>LastUsedAt</c> and persists.
    /// </summary>
    public bool CanAutoAccept(
        string connectionId,
        string? viewerDeviceId,
        string? controlAuthorityPeerNodeId,
        string? remotePeerNodeId,
        DateTimeOffset now)
    {
        if (!PeerNodeIdsMatch(controlAuthorityPeerNodeId, remotePeerNodeId))
        {
            return false;
        }

        PruneExpired(now);
        var key = GrantKey(connectionId, viewerDeviceId, controlAuthorityPeerNodeId);
        var index = _grants.FindIndex(g => g.Key == key && g.ExpiresAt > now);
        if (index < 0)
        {
            return false;
        }

        _grants[index] = _grants[index].WithLastUsedAt(now);
        Persist();
        return true;
    }

    /// <summary>
    /// Remember an accepted peer as an auto-accept grant (parity:
    /// rememberAcceptedPeer). No-op unless the toggle is on AND the peer node ids
    /// match. Replaces any prior grant for the same scope.
    /// </summary>
    public void RememberAcceptedPeer(
        string connectionId,
        string? viewerDeviceId,
        string? controlAuthorityPeerNodeId,
        string? remotePeerNodeId,
        string requesterName,
        DateTimeOffset now)
    {
        if (!_rememberAcceptedMirrorPeers)
        {
            return;
        }

        if (!PeerNodeIdsMatch(controlAuthorityPeerNodeId, remotePeerNodeId))
        {
            return;
        }

        var key = GrantKey(connectionId, viewerDeviceId, controlAuthorityPeerNodeId);
        var grant = new MirrorAutoAcceptGrant(
            key,
            connectionId,
            NilIfEmpty(viewerDeviceId),
            CanonicalPeerNodeId(controlAuthorityPeerNodeId),
            NilIfEmpty(requesterName) ?? "Mirror peer",
            now,
            now.Add(GrantTtl),
            lastUsedAt: null);

        _grants.RemoveAll(g => g.Key == key);
        _grants.Add(grant);
        Persist();
    }

    /// <summary>Revoke every mirror auto-accept grant (parity: revokeAllMirrorAutoAcceptGrants).</summary>
    public void RevokeAllMirrorAutoAcceptGrants()
    {
        _grants.Clear();
        Persist();
    }

    private void PruneExpired(DateTimeOffset now)
    {
        if (!_grants.Any(g => g.ExpiresAt <= now))
        {
            return;
        }

        _grants.RemoveAll(g => g.ExpiresAt <= now);
        Persist();
    }

    private void Persist()
    {
        // Fail closed: a failed encode must NOT erase the persisted ledger.
        // TryEncode returns null on an encode fault (logging); we then leave the
        // stored bytes intact rather than overwriting with an empty value.
        var data = MercuryConsentCodec.TryEncode(_grants, _encodeGrants, _encodeFaultLogger);
        if (data is null)
        {
            return;
        }

        _persistence.SaveGrantData(data);
    }

    private static IReadOnlyList<MirrorAutoAcceptGrant> SafeDecode(
        byte[] data,
        Func<byte[], IReadOnlyList<MirrorAutoAcceptGrant>> decoder)
    {
        try
        {
            return decoder(data);
        }
        catch
        {
            // Fail-closed empty ledger on a corrupt decode (parity: try? ?? []).
            return Array.Empty<MirrorAutoAcceptGrant>();
        }
    }

    /// <summary>Parity: grantKey — canonicalized "conn|viewer|peer" join with "_" for empties.</summary>
    public static string GrantKey(string? connectionId, string? viewerDeviceId, string? controlAuthorityPeerNodeId) =>
        string.Join(
            "|",
            NilIfEmpty(connectionId) ?? "_",
            NilIfEmpty(viewerDeviceId) ?? "_",
            CanonicalPeerNodeId(controlAuthorityPeerNodeId) ?? "_");

    /// <summary>Parity: peerNodeIDsMatch — both canonical, non-empty, equal.</summary>
    public static bool PeerNodeIdsMatch(string? declaredPeerNodeId, string? remotePeerNodeId)
    {
        var declared = CanonicalPeerNodeId(declaredPeerNodeId);
        var remote = CanonicalPeerNodeId(remotePeerNodeId);
        if (declared is null || remote is null)
        {
            return false;
        }

        return string.Equals(declared, remote, StringComparison.Ordinal);
    }

    /// <summary>Parity: canonicalPeerNodeID — trim + lowercase + nilIfEmpty.</summary>
    public static string? CanonicalPeerNodeId(string? value) => NilIfEmpty(value?.ToLowerInvariant());

    private static string? NilIfEmpty(string? value)
    {
        if (value is null)
        {
            return null;
        }

        var trimmed = value.Trim();
        return trimmed.Length == 0 ? null : trimmed;
    }
}

/// <summary>A single mirror auto-accept grant (parity: MirrorAutoAcceptGrant).</summary>
public sealed class MirrorAutoAcceptGrant : IEquatable<MirrorAutoAcceptGrant>
{
    public string Key { get; }

    public string ConnectionId { get; }

    public string? ViewerDeviceId { get; }

    public string? ControlAuthorityPeerNodeId { get; }

    public string RequesterName { get; }

    public DateTimeOffset GrantedAt { get; }

    public DateTimeOffset ExpiresAt { get; }

    public DateTimeOffset? LastUsedAt { get; }

    public MirrorAutoAcceptGrant(
        string key,
        string connectionId,
        string? viewerDeviceId,
        string? controlAuthorityPeerNodeId,
        string requesterName,
        DateTimeOffset grantedAt,
        DateTimeOffset expiresAt,
        DateTimeOffset? lastUsedAt)
    {
        Key = key;
        ConnectionId = connectionId;
        ViewerDeviceId = viewerDeviceId;
        ControlAuthorityPeerNodeId = controlAuthorityPeerNodeId;
        RequesterName = requesterName;
        GrantedAt = grantedAt;
        ExpiresAt = expiresAt;
        LastUsedAt = lastUsedAt;
    }

    public MirrorAutoAcceptGrant WithLastUsedAt(DateTimeOffset lastUsedAt) => new(
        Key,
        ConnectionId,
        ViewerDeviceId,
        ControlAuthorityPeerNodeId,
        RequesterName,
        GrantedAt,
        ExpiresAt,
        lastUsedAt);

    public bool Equals(MirrorAutoAcceptGrant? other)
    {
        if (other is null)
        {
            return false;
        }

        return Key == other.Key
            && ConnectionId == other.ConnectionId
            && ViewerDeviceId == other.ViewerDeviceId
            && ControlAuthorityPeerNodeId == other.ControlAuthorityPeerNodeId
            && RequesterName == other.RequesterName
            && GrantedAt.Equals(other.GrantedAt)
            && ExpiresAt.Equals(other.ExpiresAt)
            && Nullable.Equals(LastUsedAt, other.LastUsedAt);
    }

    public override bool Equals(object? obj) => Equals(obj as MirrorAutoAcceptGrant);

    public override int GetHashCode()
    {
        var hash = new HashCode();
        hash.Add(Key);
        hash.Add(ConnectionId);
        hash.Add(ViewerDeviceId);
        hash.Add(ControlAuthorityPeerNodeId);
        hash.Add(RequesterName);
        hash.Add(GrantedAt);
        hash.Add(ExpiresAt);
        hash.Add(LastUsedAt);
        return hash.ToHashCode();
    }
}

/// <summary>Persistence seam for the consent ledger (parity: the UserDefaults keys).</summary>
public interface IMercuryConsentPersistence
{
    byte[]? LoadGrantData();

    void SaveGrantData(byte[] data);

    bool LoadRememberFlag();

    void SaveRememberFlag(bool remember);
}

/// <summary>Default in-memory persistence used by tests and cold hosts.</summary>
public sealed class InMemoryMercuryConsentPersistence : IMercuryConsentPersistence
{
    private byte[]? _grantData;
    private bool _remember;

    public byte[]? LoadGrantData() => _grantData;

    public void SaveGrantData(byte[] data) => _grantData = data;

    public bool LoadRememberFlag() => _remember;

    public void SaveRememberFlag(bool remember) => _remember = remember;
}
