using System;
using System.Collections.Generic;

namespace OpenBurnBar.App.Shell;

internal static class CommandLineParts
{
    public static IReadOnlyList<string> Split(string? arguments)
    {
        if (string.IsNullOrWhiteSpace(arguments))
        {
            return Array.Empty<string>();
        }

        var parts = new List<string>();
        var current = new System.Text.StringBuilder();
        var quoted = false;
        foreach (char c in arguments)
        {
            if (c == '"')
            {
                quoted = !quoted;
                continue;
            }

            if (char.IsWhiteSpace(c) && !quoted)
            {
                Flush();
                continue;
            }

            current.Append(c);
        }

        Flush();
        return parts;

        void Flush()
        {
            if (current.Length == 0)
            {
                return;
            }

            parts.Add(current.ToString());
            current.Clear();
        }
    }
}
