using OpenBurnBar.Particles.Drawing;
using OpenBurnBar.Particles.Model;

namespace OpenBurnBar.Particles.Substrates;

/// <summary>
/// A full-field painter that draws over the resolved particle cloud for one frame
/// — C# port of the Swift <c>SwarmSubstrate</c> protocol. Instances are created
/// once and reused across frames, so they may hold per-layout caches (sprites,
/// kNN graphs). Substrates NEVER touch the simulation; positions, velocities and
/// colors are all resolved by the engine (Swift Core) and vended in the
/// <see cref="SwarmSubstrateFrame"/>. A substrate only restyles how the resolved
/// dots are painted.
/// </summary>
public interface ISwarmSubstrate
{
    /// <summary>
    /// Paint the whole field into <paramref name="session"/>. Return <c>true</c>
    /// when fully handled — the renderer then skips its own dot/twinkle loops.
    /// Return <c>false</c> to defer to the default dot render (what
    /// <see cref="PlainDotsSubstrate"/> does).
    /// </summary>
    bool Paint(SwarmSubstrateFrame frame, ISubstrateDrawingSession session);

    /// <summary>
    /// Whether this substrate also wants the renderer to skip the glyph pass
    /// (the <c>$</c>/<c>tok</c>/<c>429</c> brand glyphs). Default <c>false</c>.
    /// </summary>
    bool SuppressesGlyphs => false;
}
