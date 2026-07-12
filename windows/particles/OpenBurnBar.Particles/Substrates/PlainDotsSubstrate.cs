using OpenBurnBar.Particles.Drawing;
using OpenBurnBar.Particles.Model;

namespace OpenBurnBar.Particles.Substrates;

/// <summary>
/// The shared "Plain · DOTS" substrate — the family default for all six families.
/// C# port of Swift <c>PlainDotsSubstrate</c>. It deliberately does nothing and
/// returns <c>false</c>, so the renderer's existing dot + twinkle + glyph render
/// runs unchanged. This guarantees parity with the pre-substrate renderer whenever
/// <c>plain</c> is selected (the default), and is the graceful fallback any
/// unfilled bespoke stub degrades to.
/// </summary>
public sealed class PlainDotsSubstrate : ISwarmSubstrate
{
    public bool Paint(SwarmSubstrateFrame frame, ISubstrateDrawingSession session) => false;
}
