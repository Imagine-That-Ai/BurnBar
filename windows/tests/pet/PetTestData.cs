using System;
using System.IO;
using OpenBurnBar.App.Pet.Behavior;
using OpenBurnBar.App.Pet.Definition;

namespace OpenBurnBar.App.Pet.Tests;

/// Shared loaders for the REAL committed claudecode petdef fixture, so the
/// behavior-graph tests run against genuine shipped data rather than a hand-made
/// graph.
internal static class PetTestData
{
    internal const string ClaudeCodeFixture = "Fixtures/claudecode.petdef.json";

    internal static string ReadClaudeCodeJson()
    {
        var path = Path.Combine(AppContext.BaseDirectory, ClaudeCodeFixture);
        if (!File.Exists(path))
        {
            throw new FileNotFoundException($"Fixture not found (was it copied to output?): {path}");
        }
        return File.ReadAllText(path);
    }

    internal static PetDefinition LoadClaudeCode() => PetDefinition.Parse(ReadClaudeCodeJson());

    internal static PetBehaviorGraph LoadClaudeCodeGraph() =>
        LoadClaudeCode().Behavior ?? throw new InvalidOperationException("claudecode fixture has no behavior graph.");

    /// A tiny hand-made weighted graph for deterministic-selection tests:
    ///   s --t(w=wa)--> a
    ///   s --t(w=wb)--> b
    ///   a --r--> s
    ///   b --r--> s
    internal static PetBehaviorGraph TwoWayWeighted(int wa, int wb)
    {
        var t = PetBehaviorTrigger.CooldownElapsed;
        var r = PetBehaviorTrigger.ResultLanded;
        return new PetBehaviorGraph("s", new[]
        {
            new PetBehaviorTransition("s", "a", t, wa),
            new PetBehaviorTransition("s", "b", t, wb),
            new PetBehaviorTransition("a", "s", r),
            new PetBehaviorTransition("b", "s", r),
        });
    }
}
