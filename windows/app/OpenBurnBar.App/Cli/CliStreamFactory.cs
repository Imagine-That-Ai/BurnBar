using System;

namespace OpenBurnBar.App.Cli;

/// <summary>
/// Picks a live CLI stream source: ConPTY on Windows when the agent CLI is available,
/// otherwise the timed <see cref="StubCliStream"/> transcript (design-time, macOS authoring,
/// or <c>OPENBURNBAR_CLI_STUB=1</c>).
/// </summary>
public static class CliStreamFactory
{
    /// <summary>Default command line for the ConPTY session (overridable via <c>OPENBURNBAR_CLI_COMMAND</c>).</summary>
    public const string DefaultCommandLine = "claude --output-format stream-json --print \"\"";

    /// <summary>
    /// Returns <see cref="ConPtyCliStream"/> on Windows unless stub mode is forced;
    /// returns <see cref="StubCliStream"/> on non-Windows hosts or when stub mode is forced.
    /// </summary>
    public static ICliStream CreateDefault()
    {
        if (ForceStub())
        {
            return new StubCliStream();
        }

        if (OperatingSystem.IsWindows())
        {
            var command = Environment.GetEnvironmentVariable("OPENBURNBAR_CLI_COMMAND");
            if (string.IsNullOrWhiteSpace(command))
            {
                command = DefaultCommandLine;
            }

            return new ConPtyCliStream(command);
        }

        return new StubCliStream();
    }

    private static bool ForceStub()
    {
        var flag = Environment.GetEnvironmentVariable("OPENBURNBAR_CLI_STUB");
        return string.Equals(flag, "1", StringComparison.Ordinal)
            || string.Equals(flag, "true", StringComparison.OrdinalIgnoreCase);
    }
}