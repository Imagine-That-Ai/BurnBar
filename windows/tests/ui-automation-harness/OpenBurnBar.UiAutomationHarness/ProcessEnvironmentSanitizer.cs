using System;
using System.Collections.Generic;
using System.Diagnostics;

namespace OpenBurnBar.UiAutomationHarness;

internal static class ProcessEnvironmentSanitizer
{
    private static readonly string[] AdditionalSecretKeys =
    {
        "ANTHROPIC_API_KEY",
    };

    public static void RemoveOpenBurnBarEnvironment(ProcessStartInfo startInfo)
    {
        var keys = new List<string>();
        foreach (string key in startInfo.Environment.Keys)
        {
            if (key.StartsWith("OPENBURNBAR_", StringComparison.OrdinalIgnoreCase) || IsAdditionalSecretKey(key))
            {
                keys.Add(key);
            }
        }

        foreach (string key in keys)
        {
            startInfo.Environment.Remove(key);
        }
    }

    private static bool IsAdditionalSecretKey(string key)
    {
        foreach (string secretKey in AdditionalSecretKeys)
        {
            if (string.Equals(key, secretKey, StringComparison.OrdinalIgnoreCase))
            {
                return true;
            }
        }

        return false;
    }
}
