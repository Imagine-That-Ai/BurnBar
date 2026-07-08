using OpenBurnBar.App.Pet.Behavior;
using Xunit;

namespace OpenBurnBar.App.Pet.Tests;

public sealed class Mulberry32Tests
{
    [Fact]
    public void SameSeed_ProducesIdenticalSequence()
    {
        var a = new Mulberry32(12345);
        var b = new Mulberry32(12345);
        for (var i = 0; i < 64; i++)
        {
            Assert.Equal(a.NextUInt32(), b.NextUInt32());
        }
    }

    [Fact]
    public void DifferentSeeds_Diverge()
    {
        var a = new Mulberry32(1);
        var b = new Mulberry32(2);
        var same = true;
        for (var i = 0; i < 8; i++)
        {
            if (a.NextUInt32() != b.NextUInt32())
            {
                same = false;
                break;
            }
        }
        Assert.False(same);
    }

    [Fact]
    public void NextUnit_IsInUnitInterval()
    {
        var rng = new Mulberry32(99);
        for (var i = 0; i < 1000; i++)
        {
            var u = rng.NextUnit();
            Assert.InRange(u, 0.0, 0.9999999999);
        }
    }

    [Fact]
    public void KnownSeed_MatchesCanonicalReference()
    {
        // Pin the exact bit math against the canonical mulberry32 reference (computed
        // independently), so a regression in the wrapping arithmetic is caught. These
        // values are stable across the TS/Swift/C# ports.
        Assert.Equal(1_144_304_738u, new Mulberry32(0).NextUInt32());
        Assert.Equal(50_271_532u, new Mulberry32(7).NextUInt32());

        var seq = new Mulberry32(0);
        Assert.Equal(1_144_304_738u, seq.NextUInt32());
        Assert.Equal(1_416_247u, seq.NextUInt32());
        Assert.Equal(958_946_056u, seq.NextUInt32());
    }
}
