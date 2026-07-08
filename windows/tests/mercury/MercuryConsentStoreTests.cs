using System;
using System.Collections.Generic;
using OpenBurnBar.Integrations.Mercury.Consent;
using Xunit;

namespace OpenBurnBar.Integrations.Mercury.Tests;

public sealed class MercuryConsentStoreTests
{
    private static readonly DateTimeOffset Now = new(2026, 7, 3, 12, 0, 0, TimeSpan.Zero);

    private const string Conn = "conn-1";
    private const string Viewer = "viewer-1";
    private const string Peer = "PeerNodeABC";

    private static void Remember(MercuryConsentStore store) => store.RememberAcceptedPeer(
        Conn, Viewer, Peer, remotePeerNodeId: Peer, requesterName: "iPhone", now: Now);

    [Fact]
    public void CanAutoAccept_RequiresMatchingUnexpiredGrant()
    {
        var store = new MercuryConsentStore { RememberAcceptedMirrorPeers = true };
        Remember(store);

        var accepted = store.CanAutoAccept(Conn, Viewer, Peer, remotePeerNodeId: Peer, now: Now.AddMinutes(1));
        Assert.True(accepted);
    }

    [Fact]
    public void CanAutoAccept_NoGrant_ReturnsFalse()
    {
        var store = new MercuryConsentStore { RememberAcceptedMirrorPeers = true };
        Assert.False(store.CanAutoAccept(Conn, Viewer, Peer, remotePeerNodeId: Peer, now: Now));
    }

    [Fact]
    public void CanAutoAccept_PeerMismatch_ReturnsFalse()
    {
        var store = new MercuryConsentStore { RememberAcceptedMirrorPeers = true };
        Remember(store);

        // A different connected remote peer than the one the grant is bound to
        // must never auto-accept, even though the connection/viewer match.
        var accepted = store.CanAutoAccept(Conn, Viewer, Peer, remotePeerNodeId: "SomeOtherPeer", now: Now);
        Assert.False(accepted);
    }

    [Fact]
    public void CanAutoAccept_ExpiredGrant_ReturnsFalseAndPrunes()
    {
        var store = new MercuryConsentStore { RememberAcceptedMirrorPeers = true };
        Remember(store);

        var afterTtl = Now.Add(MercuryConsentStore.GrantTtl).AddSeconds(1);
        Assert.False(store.CanAutoAccept(Conn, Viewer, Peer, remotePeerNodeId: Peer, now: afterTtl));
        Assert.Equal(0, store.ActiveGrantCount);
    }

    [Fact]
    public void RememberAcceptedPeer_NoOpWhenToggleOff()
    {
        var store = new MercuryConsentStore { RememberAcceptedMirrorPeers = false };
        Remember(store);
        Assert.Equal(0, store.ActiveGrantCount);
    }

    [Fact]
    public void RememberAcceptedPeer_NoOpWhenPeerMismatch()
    {
        var store = new MercuryConsentStore { RememberAcceptedMirrorPeers = true };
        store.RememberAcceptedPeer(Conn, Viewer, Peer, remotePeerNodeId: "Other", requesterName: "x", now: Now);
        Assert.Equal(0, store.ActiveGrantCount);
    }

    [Fact]
    public void RememberAcceptedPeer_ReplacesGrantForSameScope()
    {
        var store = new MercuryConsentStore { RememberAcceptedMirrorPeers = true };
        Remember(store);
        Remember(store);
        Assert.Equal(1, store.ActiveGrantCount);
    }

    [Fact]
    public void RevokeAll_ClearsGrants()
    {
        var store = new MercuryConsentStore { RememberAcceptedMirrorPeers = true };
        Remember(store);
        store.RevokeAllMirrorAutoAcceptGrants();
        Assert.Equal(0, store.ActiveGrantCount);
        Assert.False(store.CanAutoAccept(Conn, Viewer, Peer, remotePeerNodeId: Peer, now: Now));
    }

    [Fact]
    public void PeerNodeIdsMatch_IsCaseAndWhitespaceInsensitive()
    {
        Assert.True(MercuryConsentStore.PeerNodeIdsMatch("  ABC  ", "abc"));
        Assert.False(MercuryConsentStore.PeerNodeIdsMatch("ABC", "abd"));
        Assert.False(MercuryConsentStore.PeerNodeIdsMatch(null, "abc"));
        Assert.False(MercuryConsentStore.PeerNodeIdsMatch("abc", "  "));
    }

    [Fact]
    public void GrantKey_CanonicalizesEmptiesToUnderscore()
    {
        Assert.Equal("_|_|_", MercuryConsentStore.GrantKey(null, "", "   "));
        Assert.Equal("conn|_|peer", MercuryConsentStore.GrantKey("conn", null, "PEER"));
    }

    [Fact]
    public void Persistence_SurvivesReload()
    {
        var persistence = new InMemoryMercuryConsentPersistence();
        var first = new MercuryConsentStore(persistence) { RememberAcceptedMirrorPeers = true };
        Remember(first);

        var reloaded = new MercuryConsentStore(persistence);
        Assert.Equal(1, reloaded.ActiveGrantCount);
        Assert.True(reloaded.CanAutoAccept(Conn, Viewer, Peer, remotePeerNodeId: Peer, now: Now.AddMinutes(1)));
    }

    [Fact]
    public void FailClosedEncode_LeavesStoredLedgerIntact()
    {
        var persistence = new InMemoryMercuryConsentPersistence();

        // Seed a healthy ledger with the default encoder.
        var seed = new MercuryConsentStore(persistence) { RememberAcceptedMirrorPeers = true };
        Remember(seed);
        var storedBefore = persistence.LoadGrantData();
        Assert.NotNull(storedBefore);

        // Reopen with an encoder that always throws; any mutation's persist()
        // must NOT overwrite the previously stored ledger (fail closed).
        var faultCount = 0;
        var faulting = new MercuryConsentStore(
            persistence,
            encodeGrants: _ => throw new InvalidOperationException("encode boom"),
            encodeFaultLogger: (_, _) => faultCount++)
        {
            RememberAcceptedMirrorPeers = true,
        };
        faulting.RememberAcceptedPeer("conn-2", "viewer-2", "peer2", remotePeerNodeId: "peer2", requesterName: "y", now: Now);

        var storedAfter = persistence.LoadGrantData();
        Assert.Equal(storedBefore, storedAfter); // unchanged — not wiped
        Assert.True(faultCount > 0);
    }

    [Fact]
    public void CorruptStoredData_DecodesToEmptyLedger()
    {
        var persistence = new InMemoryMercuryConsentPersistence();
        persistence.SaveGrantData(new byte[] { 0xFF, 0x00, 0x12 }); // not valid JSON

        var store = new MercuryConsentStore(persistence);
        Assert.Equal(0, store.ActiveGrantCount);
    }
}
