using System.Collections;
using System.Diagnostics;

namespace OpenBurnBar.App.Configuration;

public enum ChildProcessProfile
{
    Chat,
    Updater,
    Gateway,
    Mission,
    ComputerUse,
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
        "FIREBASE",
        "GOOGLE_SERVICES",
        "ID_TOKEN",
        "OPENAI",
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
        IEnumerable<KeyValuePair<string, string?>>? required = null)
    {
        source ??= Environment.GetEnvironmentVariables()
            .Cast<DictionaryEntry>()
            .Select(entry => new KeyValuePair<string, string?>((string)entry.Key, entry.Value?.ToString()));

        var allowed = new HashSet<string>(
            OperatingSystem.IsWindows() ? WindowsRuntimeAllowlist : PortableRuntimeAllowlist,
            OperatingSystem.IsWindows() ? StringComparer.OrdinalIgnoreCase : StringComparer.Ordinal);

        foreach (string name in ProfileAllowlist(profile))
        {
            allowed.Add(name);
        }

        var result = new SortedDictionary<string, string>(
            OperatingSystem.IsWindows() ? StringComparer.OrdinalIgnoreCase : StringComparer.Ordinal);
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

                if (IsForbidden(pair.Key))
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
        IEnumerable<KeyValuePair<string, string?>>? required = null)
    {
        ArgumentNullException.ThrowIfNull(startInfo);
        startInfo.UseShellExecute = false;
        startInfo.Environment.Clear();
        foreach (var pair in CreateAllowlisted(profile, required: required))
        {
            startInfo.Environment[pair.Key] = pair.Value;
        }
    }

    public static bool IsForbidden(string name)
    {
        string normalized = name.Replace("-", "_", StringComparison.Ordinal).ToUpperInvariant();
        return ForbiddenNameFragments.Any(fragment => normalized.Contains(fragment, StringComparison.Ordinal));
    }

    private static IEnumerable<string> ProfileAllowlist(ChildProcessProfile profile) =>
        profile switch
        {
            ChildProcessProfile.ReleaseTool => new[] { "SWIFT_EXEC", "SDKROOT" },
            _ => Array.Empty<string>(),
        };
}
