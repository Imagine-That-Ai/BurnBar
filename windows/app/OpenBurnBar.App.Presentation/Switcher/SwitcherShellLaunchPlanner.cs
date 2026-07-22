using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;

namespace OpenBurnBar.App.Presentation.Switcher;

/// <summary>A validated, shell-free launch description for one switcher CLI profile.</summary>
public sealed record SwitcherShellLaunchPlan(
    string ProfileId,
    SwitcherCLIProfileType CliType,
    string ExecutableName,
    IReadOnlyList<string> Arguments,
    IReadOnlyDictionary<string, string?> RequiredEnvironment,
    string? WorkingDirectory);

/// <summary>
/// Converts encrypted switcher profile metadata into a bounded CreateProcess/ConPTY plan.
/// User data never selects an arbitrary executable and only reviewed CLI configuration
/// variables may cross the child-process boundary.
/// </summary>
public static class SwitcherShellLaunchPlanner
{
    private const int MaxArgumentCount = 64;
    private const int MaxArgumentCharacters = 4 * 1024;

    private static readonly HashSet<string> PassThroughEnvironmentKeys = new(
        new[]
        {
            "LANG", "LC_ALL", "TERM", "EDITOR", "VISUAL", "PAGER",
            "GIT_EDITOR", "HG_EDITOR", "SSH_AUTH_SOCK",
        },
        StringComparer.OrdinalIgnoreCase);

    public static SwitcherShellLaunchPlan CreateForProfile(
        ISwitcherProfileStore store,
        string profileId,
        IReadOnlyList<string>? forwardedArguments = null,
        IReadOnlyDictionary<string, string?>? sourceEnvironment = null)
    {
        ArgumentNullException.ThrowIfNull(store);
        ArgumentException.ThrowIfNullOrWhiteSpace(profileId);

        SwitcherProfileRecord profile = store.FetchAllProfiles()
            .FirstOrDefault(candidate => string.Equals(candidate.Id, profileId, StringComparison.Ordinal))
            ?? throw new InvalidOperationException($"Switcher profile '{profileId}' was not found.");
        return Create(profile, forwardedArguments, sourceEnvironment);
    }

    public static SwitcherShellLaunchPlan Create(
        SwitcherProfileRecord profile,
        IReadOnlyList<string>? forwardedArguments = null,
        IReadOnlyDictionary<string, string?>? sourceEnvironment = null)
    {
        ArgumentNullException.ThrowIfNull(profile);
        if (profile.TargetKind != SwitcherProfileTargetKind.Cli || profile.CliType is not { } cliType)
        {
            throw new InvalidOperationException("Only CLI switcher profiles can start a shell.");
        }
        if (profile.IsDisabled)
        {
            throw new InvalidOperationException("This switcher profile is paused.");
        }

        SwitcherCLIProfileMetadata metadata = profile.CliMetadata ?? new SwitcherCLIProfileMetadata();
        string[] arguments = metadata.AdditionalArgs
            .Concat(forwardedArguments ?? Array.Empty<string>())
            .Select(ValidateArgument)
            .ToArray();
        if (arguments.Length > MaxArgumentCount)
        {
            throw new InvalidOperationException($"A switcher launch accepts at most {MaxArgumentCount} arguments.");
        }

        string? workingDirectory = ValidateDirectory(metadata.WorkingDirectory, "working directory");
        string? configDirectory = ValidateDirectory(metadata.ConfigDirectory, "configuration directory");
        var requiredEnvironment = BuildEnvironment(cliType, metadata, configDirectory, sourceEnvironment);

        return new SwitcherShellLaunchPlan(
            profile.Id,
            cliType,
            cliType.ExecutableName(),
            arguments,
            requiredEnvironment,
            workingDirectory);
    }

    private static IReadOnlyDictionary<string, string?> BuildEnvironment(
        SwitcherCLIProfileType cliType,
        SwitcherCLIProfileMetadata metadata,
        string? configDirectory,
        IReadOnlyDictionary<string, string?>? sourceEnvironment)
    {
        var environment = new SortedDictionary<string, string?>(StringComparer.OrdinalIgnoreCase);
        if (sourceEnvironment is not null)
        {
            foreach (string key in metadata.EnvKeysToPass.Distinct(StringComparer.OrdinalIgnoreCase))
            {
                if (!PassThroughEnvironmentKeys.Contains(key))
                {
                    throw new InvalidOperationException($"Switcher environment key '{key}' is not allowlisted.");
                }
                if (sourceEnvironment.TryGetValue(key, out string? value) && !string.IsNullOrEmpty(value))
                {
                    environment[key] = ValidateEnvironmentValue(key, value);
                }
            }
        }

        if (configDirectory is not null)
        {
            foreach (string key in ConfigurationEnvironmentKeys(cliType))
            {
                environment[key] = configDirectory;
            }
        }
        return environment;
    }

    private static IReadOnlyList<string> ConfigurationEnvironmentKeys(SwitcherCLIProfileType cliType) => cliType switch
    {
        SwitcherCLIProfileType.Codex => new[] { "CODEX_HOME", "CODEX_CONFIG_PATH" },
        SwitcherCLIProfileType.Claude => new[] { "CLAUDE_CONFIG_DIR", "CLAUDE_CONFIG_PATH" },
        SwitcherCLIProfileType.OpenCode => new[] { "OPENCODE_CONFIG_PATH" },
        SwitcherCLIProfileType.Antigravity => new[] { "AGY_CONFIG_HOME", "ANTIGRAVITY_HOME" },
        SwitcherCLIProfileType.CursorAgent => new[] { "CURSOR_AGENT_HOME", "CURSOR_AGENT_CONFIG_PATH" },
        SwitcherCLIProfileType.Gemini => new[] { "GEMINI_HOME" },
        _ => Array.Empty<string>(),
    };

    private static string ValidateArgument(string argument)
    {
        if (argument.Length > MaxArgumentCharacters || HasControlCharacter(argument))
        {
            throw new InvalidOperationException("Switcher argument is invalid or exceeds the size limit.");
        }
        return argument;
    }

    private static string? ValidateDirectory(string? path, string label)
    {
        if (string.IsNullOrWhiteSpace(path))
        {
            return null;
        }
        if (HasControlCharacter(path))
        {
            throw new InvalidOperationException($"Switcher {label} contains control characters.");
        }

        string fullPath = Path.GetFullPath(path.Trim());
        if (!Directory.Exists(fullPath))
        {
            throw new InvalidOperationException($"Switcher {label} does not exist.");
        }
        return fullPath;
    }

    private static string ValidateEnvironmentValue(string key, string value)
    {
        if (value.Length > MaxArgumentCharacters || HasControlCharacter(value))
        {
            throw new InvalidOperationException($"Switcher environment value '{key}' is invalid.");
        }
        return value;
    }

    private static bool HasControlCharacter(string value) =>
        value.Any(character => character == '\0' || (char.IsControl(character) && character != '\t'));
}
