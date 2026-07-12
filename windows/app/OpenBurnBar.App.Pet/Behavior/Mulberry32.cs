using System;

namespace OpenBurnBar.App.Pet.Behavior;

// MARK: - Seeded RNG (deterministic, portable)
//
// C# peer of `AgentLens/PetCompanion/Core/Behavior.swift` `Mulberry32`.
//
// The same tiny, well-distributed 32-bit generator used by the shared TS petcore
// and the Swift port, so a shared seed reproduces an identical transition
// sequence across the TS golden vectors, the Swift interpreter, and this C# port
// (PLAN C3). Determinism is the contract the behavior tests rest on.

/// Mulberry32 — a deterministic 32-bit PRNG. `unchecked` arithmetic mirrors the
/// Swift `&+` / `&*` wrapping operators exactly, so the bit sequence is identical.
public struct Mulberry32
{
    private uint _state;

    public Mulberry32(uint seed)
    {
        _state = seed;
    }

    /// One 32-bit step. Matches the canonical mulberry32 reference (and the Swift
    /// `nextUInt32`).
    public uint NextUInt32()
    {
        unchecked
        {
            _state += 0x6D2B_79F5u;
            uint z = _state;
            z = (z ^ (z >> 15)) * (z | 1u);
            z ^= z + ((z ^ (z >> 7)) * (z | 61u));
            return z ^ (z >> 14);
        }
    }

    /// A 64-bit value assembled from two 32-bit steps (low word first), matching
    /// the Swift `RandomNumberGenerator.next()` conformance.
    public ulong Next()
    {
        ulong lo = NextUInt32();
        ulong hi = NextUInt32();
        return (hi << 32) | lo;
    }

    /// Float in [0, 1), matching the TS `next() / 2**32` convention (peer of the
    /// Swift `nextUnit()`).
    public double NextUnit()
    {
        return NextUInt32() / 4_294_967_296.0;
    }
}
