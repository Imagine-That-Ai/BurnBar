using System;
using System.Collections.Generic;
using System.Diagnostics;

namespace OpenBurnBar.UiAutomationHarness;

internal static class ProcessEnvironmentSanitizer
{
    public static void RemoveOpenBurnBarEnvironment(ProcessStartInfo startInfo)
    {
        var keys = new List<string>();
        foreach (string key in startInfo.Environment.Keys)
        {
            if (key.StartsWith("OPENBURNBAR_", StringComparison.OrdinalIgnoreCase))
            {
                keys.Add(key);
            }
        }

        foreach (string key in keys)
        {
            startInfo.Environment.Remove(key);
        }
    }
}
