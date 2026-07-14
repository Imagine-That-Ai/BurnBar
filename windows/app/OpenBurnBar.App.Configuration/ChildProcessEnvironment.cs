using System.Collections;
using System.Diagnostics;

namespace OpenBurnBar.App.Configuration;

public enum ChildProcessProfile
{
    BrowserActivation,
    Chat,
    Updater,
    Gateway,
    Mission,
    ComputerUse,
    ProjectTool,
    ReleaseTool,
    Diagnostics,
}

public static class ChildProcessEnvironment
{
    private static readonly string[] WindowsRuntimeAllowlist =
    {
        "ALLUSERSPROFILE",
        "APPDATA",
        "COMSPEC",
        "CommonProgramFiles",
        "CommonProgramFiles(x86)",
        "CommonProgramW6432",
        "DOTNET_BUNDLE_EXTRACT_BASE_DIR",
        "DOTNET_ROOT",
        "LOCALAPPDATA",
        "NUMBER_OF_PROCESSORS",
        "OS",
        "PATH",
        "PATHEXT",
        "PROCESSOR_ARCHITECTURE",
        "PROCESSOR_IDENTIFIER",
        "PROCESSOR_LEVEL",
        "PROCESSOR_REVISION",
        "ProgramData",
        "ProgramFiles",
        "ProgramFiles(x86)",
        "ProgramW6432",
        "PSModulePath",
        "PUBLIC",
        "SystemDrive",
        "SystemRoot",
        "TEMP",
        "TMP",
        "USERDOMAIN",
        "USERNAME",
        "USERPROFILE",
        "WINDIR",
    };

    private static readonly string[] PortableRuntimeAllowlist =
    {
        "HOME",
        "LANG",
        "LC_ALL",
        "LC_CTYPE",
        "PATH",
        "SHELL",
        "TMPDIR",
        "TMP",
        "TEMP",
        "USER",
    };

    private static readonly string[] ForbiddenNameFragments =
    {
        "APP_CHECK",
        "APPCHECK",
        "AUTH",
        "CANARY",
        "CREDENTIAL",
        "FACTORY_API_KEY",
        "FIREBASE",
        "GOOGLE_SERVICES",
        "ID_TOKEN",
        "OPENAI",
        "OPENBURNBAR_SQLCIPHER_PATH",
        "OPENBURNBAR_SQLCIPHER_PASSPHRASE",
        "PASSWORD",
        "PASSPHRASE",
        "PRIVATE",
        "REFRESH_TOKEN",
        "SECRET",
        "SIGNING",
        "TOKEN",
        "VAULT",
        "WINDOWS_CODESIGN",
        "WINDOWS_UPDATE_SIGNING_KEY",
    };

    public static IReadOnlyDictionary<string, string> CreateAllowlisted(
        ChildProcessProfile profile,
        IEnumerable<KeyValuePair<string, string?>>? source = null,
        IEnumerable<KeyValuePair<string, string?>>? required = null,
        ChildProcessHost? host = null)
    {
        source ??= Environment.GetEnvironmentVariables()
            .Cast<DictionaryEntry>()
            .Select(entry => new KeyValuePair<string, string?>((string)entry.Key, entry.Value?.ToString()));

        ChildProcessHost targetHost = host
            ?? (OperatingSystem.IsWindows() ? ChildProcessHost.Windows : ChildProcessLaunchPolicy.CurrentHost);
        StringComparer comparer = targetHost == ChildProcessHost.Windows
            ? StringComparer.OrdinalIgnoreCase
            : StringComparer.Ordinal;
        var allowed = new HashSet<string>(
            AllowedEnvironmentVariableNames(profile, targetHost),
            comparer);

        var result = new SortedDictionary<string, string>(
            comparer);
        foreach (var pair in source)
        {
            if (string.IsNullOrWhiteSpace(pair.Key) || pair.Value is null)
            {
                continue;
            }

            if (allowed.Contains(pair.Key) && !IsForbidden(pair.Key))
            {
                result[pair.Key] = pair.Value;
            }
        }

        if (required is not null)
        {
            foreach (var pair in required)
            {
                if (string.IsNullOrWhiteSpace(pair.Key) || pair.Value is null)
                {
                    continue;
                }

                if (IsForbidden(pair.Key) && !IsRequiredSecretAllowed(profile, pair.Key))
                {
                    throw new SecretStoreException(
                        SecretStoreFailureKind.WriteDenied,
                        $"Child process required environment '{pair.Key}' is forbidden.",
                        pair.Key);
                }

                result[pair.Key] = pair.Value;
            }
        }

        return result;
    }

    public static void Apply(
        ProcessStartInfo startInfo,
        ChildProcessProfile profile,
        IEnumerable<KeyValuePair<string, string?>>? required = null,
        IEnumerable<KeyValuePair<string, string?>>? source = null,
        ChildProcessHost? host = null)
    {
        ArgumentNullException.ThrowIfNull(startInfo);
        startInfo.UseShellExecute = false;
        startInfo.Environment.Clear();
        foreach (var pair in CreateAllowlisted(profile, source, required, host))
        {
            startInfo.Environment[pair.Key] = pair.Value;
        }
    }

    public static bool IsForbidden(string name)
    {
        string normalized = name.Replace("-", "_", StringComparison.Ordinal).ToUpperInvariant();
        return ForbiddenNameFragments.Any(fragment => normalized.Contains(fragment, StringComparison.Ordinal));
    }

    public static bool IsRequiredSecretAllowed(ChildProcessProfile profile, string name) =>
        profile == ChildProcessProfile.Gateway
        && (string.Equals(name, "OPENAI_API_KEY", StringComparison.OrdinalIgnoreCase)
            || string.Equals(name, "FACTORY_API_KEY", StringComparison.OrdinalIgnoreCase));

    public static IReadOnlyList<string> AllowedEnvironmentVariableNames(
        ChildProcessProfile profile,
        ChildProcessHost host)
    {
        IEnumerable<string> baseAllowlist = host == ChildProcessHost.Windows
            ? WindowsBaseAllowlist(profile)
            : PortableBaseAllowlist(profile);
        StringComparer comparer = host == ChildProcessHost.Windows
            ? StringComparer.OrdinalIgnoreCase
            : StringComparer.Ordinal;
        return baseAllowlist
            .Concat(ProfileAllowlist(profile))
            .Where(name => !IsForbidden(name))
            .Distinct(comparer)
            .OrderBy(name => name, comparer)
            .ToArray();
    }

    private static IEnumerable<string> WindowsBaseAllowlist(ChildProcessProfile profile) =>
        profile switch
        {
            ChildProcessProfile.BrowserActivation => new[]
            {
                "LOCALAPPDATA",
                "SystemRoot",
                "TEMP",
                "TMP",
                "USERPROFILE",
                "WINDIR",
            },
            _ => WindowsRuntimeAllowlist,
        };

    private static IEnumerable<string> PortableBaseAllowlist(ChildProcessProfile profile) =>
        profile switch
        {
            ChildProcessProfile.BrowserActivation => new[]
            {
                "HOME",
                "LANG",
                "LC_ALL",
                "LC_CTYPE",
                "PATH",
                "TMPDIR",
                "TMP",
                "TEMP",
                "USER",
            },
            _ => PortableRuntimeAllowlist,
        };

    private static IEnumerable<string> ProfileAllowlist(ChildProcessProfile profile) =>
        profile switch
        {
            ChildProcessProfile.ReleaseTool => new[] { "SWIFT_EXEC", "SDKROOT" },
            _ => Array.Empty<string>(),
        };
}
