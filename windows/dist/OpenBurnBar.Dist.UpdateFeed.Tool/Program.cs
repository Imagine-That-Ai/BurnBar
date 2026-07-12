// Release-pipeline CLI for the Windows update feed (Phase 5 · signed distribution).
//
// See the csproj header for the command surface. This process runs only in CI / offline setup,
// never in the shipped app. Exit codes: 0 = success, non-zero = failure (fail-closed).

using System;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Text;
using OpenBurnBar.Dist.UpdateFeed;

namespace OpenBurnBar.Dist.UpdateFeed.Tool;

internal static class Program
{
    private static int Main(string[] args)
    {
        try
        {
            if (args.Length == 0)
            {
                return Usage("no command given");
            }

            var command = args[0];
            var options = ParseOptions(args, 1);
            return command switch
            {
                "gen-key" => GenKey(),
                "derive-pubkey" => DerivePubkey(options),
                "sign-entry" => SignEntry(options),
                "build-feed" => BuildFeed(options),
                "verify-feed" => VerifyFeed(options),
                _ => Usage($"unknown command '{command}'"),
            };
        }
        catch (ToolException ex)
        {
            Console.Error.WriteLine($"error: {ex.Message}");
            return 1;
        }
    }

    // ── gen-key ──────────────────────────────────────────────────────────────
    private static int GenKey()
    {
        var pair = new UpdateFeedSigner().GenerateKeyPair();
        Console.WriteLine("{");
        Console.WriteLine($"  \"publicKeyBase64\": \"{pair.PublicKeyBase64}\",");
        Console.WriteLine($"  \"privateKeyBase64\": \"{pair.PrivateKeyBase64}\"");
        Console.WriteLine("}");
        Console.Error.WriteLine("Store publicKeyBase64 as the PINNED key in the app; store privateKeyBase64 as the WINDOWS_UPDATE_SIGNING_KEY secret.");
        return 0;
    }

    // ── derive-pubkey ────────────────────────────────────────────────────────
    private static int DerivePubkey(IReadOnlyDictionary<string, string> options)
    {
        var seed = ReadPrivateSeed(options);
        var pub = new UpdateFeedSigner().DerivePublicKey(seed);
        // Print ONLY the base64 public key on stdout so a workflow can capture it directly.
        Console.WriteLine(Convert.ToBase64String(pub));
        return 0;
    }

    // ── sign-entry ───────────────────────────────────────────────────────────
    private static int SignEntry(IReadOnlyDictionary<string, string> options)
    {
        var versionText = Require(options, "version");
        var platformToken = Require(options, "platform");
        if (!UpdateEnumTokens.TryParsePlatform(platformToken, out var platform))
        {
            throw new ToolException($"unknown --platform '{platformToken}' (win-x64|win-arm64|win-x86)");
        }

        var channelToken = Optional(options, "channel", "stable");
        if (!UpdateEnumTokens.TryParseChannel(channelToken, out var channel))
        {
            throw new ToolException($"unknown --channel '{channelToken}' (stable|beta)");
        }

        var entry = new UpdateFeedEntry
        {
            Version = versionText,
            Platform = platform,
            Channel = channel,
            Url = Require(options, "url"),
            SizeBytes = RequireLong(options, "size"),
            Sha256 = Require(options, "sha256"),
            MinimumOsBuild = OptionalInt(options, "min-os-build", 0),
            Critical = options.ContainsKey("critical"),
            PublishedAtUtc = ParseTimestamp(Optional(options, "published-at", DateTimeOffset.UtcNow.ToString("yyyy-MM-ddTHH:mm:ssZ", CultureInfo.InvariantCulture))),
            ReleaseNotesUrl = Optional(options, "release-notes", string.Empty),
        };

        var seed = ReadPrivateSeed(options);
        var signed = new UpdateFeedSigner().Sign(entry, seed);

        var output = SerializeSingleEntry(signed);
        WriteOutput(options, output);
        return 0;
    }

    // ── build-feed ───────────────────────────────────────────────────────────
    private static int BuildFeed(IReadOnlyDictionary<string, string> options)
    {
        if (!options.TryGetValue("entry", out var entryList) || entryList.Length == 0)
        {
            throw new ToolException("build-feed requires one or more --entry <file> (comma-separated for many)");
        }

        var entries = new List<UpdateFeedEntry>();
        foreach (var path in entryList.Split(',', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries))
        {
            var json = ReadFile(path);
            if (!UpdateFeedJson.TryParse(WrapAsFeed(json), out var doc, out var error) || doc is null)
            {
                throw new ToolException($"entry '{path}' did not parse: {error}");
            }

            entries.AddRange(doc.Entries);
        }

        var feed = new UpdateFeedDocument
        {
            SchemaVersion = UpdateFeedDocument.CurrentSchemaVersion,
            Feed = UpdateFeedDocument.FeedId,
            GeneratedAtUtc = DateTimeOffset.UtcNow,
            Entries = entries,
        };

        WriteOutput(options, UpdateFeedJson.Serialize(feed) + "\n");
        return 0;
    }

    // ── verify-feed ──────────────────────────────────────────────────────────
    private static int VerifyFeed(IReadOnlyDictionary<string, string> options)
    {
        var feedJson = ReadFile(Require(options, "feed"));
        if (!UpdateFeedJson.TryParse(feedJson, out var doc, out var error) || doc is null)
        {
            throw new ToolException($"feed did not parse: {error}");
        }

        var pinnedBase64 = ResolvePinnedPublicKey(options);
        var pinned = PinnedUpdateKey.FromBase64(pinnedBase64);
        var verifier = new Ed25519UpdateFeedVerifier(pinned);

        if (doc.Entries.Count == 0)
        {
            throw new ToolException("feed has no entries to verify");
        }

        var failures = 0;
        foreach (var entry in doc.Entries)
        {
            var result = verifier.VerifyDescriptor(entry);
            var status = result.IsAuthentic ? "OK" : $"FAIL ({result.Failure}: {result.Message})";
            Console.WriteLine($"{entry.Version} {entry.Platform.ToToken()} {entry.Channel.ToToken()} -> {status}");
            if (!result.IsAuthentic)
            {
                failures++;
            }
        }

        if (failures > 0)
        {
            Console.Error.WriteLine($"verify-feed: {failures} entr(y/ies) failed pinned verification");
            return 2;
        }

        Console.WriteLine($"verify-feed: all {doc.Entries.Count} entr(y/ies) authenticated under the pinned key");
        return 0;
    }

    // ── helpers ──────────────────────────────────────────────────────────────
    private static string SerializeSingleEntry(UpdateFeedEntry entry)
    {
        // Emit a one-entry feed and slice out the entry object so build-feed can recombine.
        var feed = new UpdateFeedDocument
        {
            GeneratedAtUtc = DateTimeOffset.UtcNow,
            Entries = new[] { entry },
        };
        return UpdateFeedJson.Serialize(feed) + "\n";
    }

    private static string WrapAsFeed(string json)
    {
        var trimmed = json.TrimStart();
        if (trimmed.StartsWith("{", StringComparison.Ordinal) && trimmed.Contains("\"entries\"", StringComparison.Ordinal))
        {
            return json; // already a feed document
        }

        // A bare entry object or array — wrap it in a minimal feed envelope for parsing.
        var now = DateTimeOffset.UtcNow.ToString("yyyy-MM-ddTHH:mm:ssZ", CultureInfo.InvariantCulture);
        var entriesJson = trimmed.StartsWith("[", StringComparison.Ordinal) ? json : $"[{json}]";
        return "{\"schemaVersion\":" + UpdateFeedDocument.CurrentSchemaVersion +
               ",\"feed\":\"" + UpdateFeedDocument.FeedId +
               "\",\"generatedAtUtc\":\"" + now +
               "\",\"entries\":" + entriesJson + "}";
    }

    private static byte[] ReadPrivateSeed(IReadOnlyDictionary<string, string> options)
    {
        // Prefer an env var so the secret never lands in argv / process listings.
        if (options.TryGetValue("private-key-env", out var envName))
        {
            var value = Environment.GetEnvironmentVariable(envName);
            if (string.IsNullOrWhiteSpace(value))
            {
                throw new ToolException($"env var '{envName}' (private seed) is empty");
            }

            return DecodeSeed(value);
        }

        if (options.TryGetValue("private-key-base64", out var inline))
        {
            return DecodeSeed(inline);
        }

        throw new ToolException("sign-entry requires --private-key-env <VAR> (preferred) or --private-key-base64 <b64>");
    }

    private static byte[] DecodeSeed(string base64)
    {
        try
        {
            return Convert.FromBase64String(base64.Trim());
        }
        catch (FormatException ex)
        {
            throw new ToolException($"private seed is not valid base64: {ex.Message}");
        }
    }

    private static string ResolvePinnedPublicKey(IReadOnlyDictionary<string, string> options)
    {
        if (options.TryGetValue("pinned-public-env", out var envName))
        {
            var value = Environment.GetEnvironmentVariable(envName);
            if (string.IsNullOrWhiteSpace(value))
            {
                throw new ToolException($"env var '{envName}' (pinned public key) is empty");
            }

            return value;
        }

        return Require(options, "pinned-public-base64");
    }

    private static void WriteOutput(IReadOnlyDictionary<string, string> options, string content)
    {
        if (options.TryGetValue("out", out var path) && path.Length > 0)
        {
            File.WriteAllText(path, content, new UTF8Encoding(false));
            Console.Error.WriteLine($"wrote {path}");
        }
        else
        {
            Console.Out.Write(content);
        }
    }

    private static string ReadFile(string path)
    {
        if (!File.Exists(path))
        {
            throw new ToolException($"file not found: {path}");
        }

        return File.ReadAllText(path);
    }

    private static DateTimeOffset ParseTimestamp(string value)
    {
        if (!DateTimeOffset.TryParse(value, CultureInfo.InvariantCulture, DateTimeStyles.AssumeUniversal | DateTimeStyles.AdjustToUniversal, out var parsed))
        {
            throw new ToolException($"--published-at is not an ISO-8601 timestamp: '{value}'");
        }

        return parsed;
    }

    private static Dictionary<string, string> ParseOptions(string[] args, int start)
    {
        var options = new Dictionary<string, string>(StringComparer.Ordinal);
        for (var i = start; i < args.Length; i++)
        {
            var arg = args[i];
            if (!arg.StartsWith("--", StringComparison.Ordinal))
            {
                throw new ToolException($"unexpected argument '{arg}'");
            }

            var key = arg.Substring(2);
            if (i + 1 < args.Length && !args[i + 1].StartsWith("--", StringComparison.Ordinal))
            {
                options[key] = args[i + 1];
                i++;
            }
            else
            {
                options[key] = string.Empty; // a bare flag such as --critical
            }
        }

        return options;
    }

    private static string Require(IReadOnlyDictionary<string, string> options, string key)
    {
        if (!options.TryGetValue(key, out var value) || value.Length == 0)
        {
            throw new ToolException($"missing required --{key}");
        }

        return value;
    }

    private static string Optional(IReadOnlyDictionary<string, string> options, string key, string fallback) =>
        options.TryGetValue(key, out var value) && value.Length > 0 ? value : fallback;

    private static long RequireLong(IReadOnlyDictionary<string, string> options, string key)
    {
        var raw = Require(options, key);
        if (!long.TryParse(raw, NumberStyles.None, CultureInfo.InvariantCulture, out var value))
        {
            throw new ToolException($"--{key} must be a non-negative integer, got '{raw}'");
        }

        return value;
    }

    private static int OptionalInt(IReadOnlyDictionary<string, string> options, string key, int fallback)
    {
        if (!options.TryGetValue(key, out var raw) || raw.Length == 0)
        {
            return fallback;
        }

        if (!int.TryParse(raw, NumberStyles.None, CultureInfo.InvariantCulture, out var value))
        {
            throw new ToolException($"--{key} must be a non-negative integer, got '{raw}'");
        }

        return value;
    }

    private static int Usage(string reason)
    {
        Console.Error.WriteLine($"OpenBurnBar.Dist.UpdateFeed.Tool: {reason}");
        Console.Error.WriteLine("commands:");
        Console.Error.WriteLine("  gen-key");
        Console.Error.WriteLine("  derive-pubkey (--private-key-env VAR | --private-key-base64 B64)");
        Console.Error.WriteLine("  sign-entry --version V --platform win-x64 --channel stable --url U --size N --sha256 HEX");
        Console.Error.WriteLine("             [--min-os-build N] [--critical] [--published-at ISO] [--release-notes U]");
        Console.Error.WriteLine("             (--private-key-env VAR | --private-key-base64 B64) [--out FILE]");
        Console.Error.WriteLine("  build-feed --entry a.json,b.json [--out FILE]");
        Console.Error.WriteLine("  verify-feed --feed feed.json (--pinned-public-env VAR | --pinned-public-base64 B64)");
        return 64; // EX_USAGE
    }

    private sealed class ToolException : Exception
    {
        public ToolException(string message) : base(message)
        {
        }
    }
}
