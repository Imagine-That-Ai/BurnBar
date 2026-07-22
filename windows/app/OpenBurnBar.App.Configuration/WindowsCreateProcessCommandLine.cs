using System.Text;

namespace OpenBurnBar.App.Configuration;

/// <summary>Builds an argv-preserving command line for Windows <c>CreateProcessW</c>.</summary>
public static class WindowsCreateProcessCommandLine
{
    public static string Build(string executable, IReadOnlyList<string> arguments)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(executable);
        ArgumentNullException.ThrowIfNull(arguments);
        return string.Join(" ", new[] { Quote(executable) }.Concat(arguments.Select(Quote)));
    }

    public static string Quote(string value)
    {
        ArgumentNullException.ThrowIfNull(value);
        if (value.Length > 0 && !value.Any(character => char.IsWhiteSpace(character) || character is '"' or '\\'))
        {
            return value;
        }

        var result = new StringBuilder("\"");
        int backslashes = 0;
        foreach (char character in value)
        {
            if (character == '\\')
            {
                backslashes++;
                continue;
            }
            if (character == '"')
            {
                result.Append('\\', backslashes * 2 + 1).Append('"');
                backslashes = 0;
                continue;
            }
            result.Append('\\', backslashes).Append(character);
            backslashes = 0;
        }
        result.Append('\\', backslashes * 2).Append('"');
        return result.ToString();
    }
}
