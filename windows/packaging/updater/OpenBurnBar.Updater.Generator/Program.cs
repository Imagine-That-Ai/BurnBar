// Release-side Windows appcast generator — the mirror of
// scripts/generate-macos-appcast.mjs. Signs the artifact BYTES with the pinned
// Ed25519 PRIVATE seed and emits appcast XML + latest-windows.json.
//
// Usage:
//   dotnet run --project OpenBurnBar.Updater.Generator -- \
//     --version 1.4.2 --build 1420 --bundle-id com.openburnbar.app \
//     --artifact path/to/OpenBurnBar-Setup-1.4.2.msix \
//     --download-url https://dl.openburnbar.app/OpenBurnBar-Setup-1.4.2.msix \
//     --appcast-url https://dl.openburnbar.app/appcast-windows.xml \
//     --ed-seed-base64-env WINDOWS_UPDATE_SIGNING_KEY \
//     --appcast-out appcast-windows.xml --json-out latest-windows.json \
//     [--critical] [--min-system-version 10.0.19041] [--release-notes-url URL] \
//     [--commit SHA] [--pub-date "Fri, 04 Jul 2026 00:00:00 GMT"] \
//     [--created-at 2026-07-04T00:00:00Z] [--package OpenBurnBar-Setup-1.4.2.msix]
//
// At release time the private seed is read as base64 from the W0 CI secret.
// Local sample generation can still use a 64-hex-char (32-byte) seed via
// --ed-seed or --ed-seed-file.

using System;
using System.Collections.Generic;
using System.IO;
using OpenBurnBar.Updater.Core.Crypto;
using OpenBurnBar.Updater.Core.Feed;
using OpenBurnBar.Updater.Core.Verification;

namespace OpenBurnBar.Updater.Generator;

internal static class Program
{
    private static int Main(string[] args)
    {
        try
        {
            var options = ParseArgs(args);
            var artifactPath = Require(options, "artifact");
            var artifactBytes = File.ReadAllBytes(artifactPath);

            var keyPair = LoadKeyPair(options);
            var descriptor = new UpdateReleaseDescriptor
            {
                Version = Require(options, "version"),
                Build = Require(options, "build"),
                BundleId = Require(options, "bundle-id"),
                DownloadUrl = Require(options, "download-url"),
                PackageName = options.GetValueOrDefault("package") ?? Path.GetFileName(artifactPath),
                Length = artifactBytes.LongLength,
                Sha256 = Sha256Digest.HexOf(artifactBytes),
                EdSignatureBase64 = keyPair.SignBase64(artifactBytes),
                Critical = options.ContainsKey("critical"),
                MinimumSystemVersion =
                    options.GetValueOrDefault("min-system-version") ?? "10.0.19041",
                ReleaseNotesUrl = options.GetValueOrDefault("release-notes-url"),
                AppcastUrl = options.GetValueOrDefault("appcast-url"),
                Commit = options.GetValueOrDefault("commit"),
                Channel = options.GetValueOrDefault("channel") ?? "direct-download",
                PubDate = options.GetValueOrDefault("pub-date"),
                CreatedAt = options.GetValueOrDefault("created-at"),
            };

            var appcastOut = Require(options, "appcast-out");
            var jsonOut = Require(options, "json-out");
            File.WriteAllText(appcastOut, AppcastFeedWriter.Write(descriptor));
            File.WriteAllText(jsonOut, JsonFeedWriter.Write(descriptor));
            VerifyGeneratedFeed(
                appcastOut,
                FeedFormat.Appcast,
                keyPair.PublicKeyBase64,
                artifactBytes);
            VerifyGeneratedFeed(
                jsonOut,
                FeedFormat.Json,
                keyPair.PublicKeyBase64,
                artifactBytes);

            Console.Error.WriteLine(
                $"generate-windows-appcast: wrote {appcastOut} + {jsonOut} " +
                $"(version={descriptor.Version} length={descriptor.Length} " +
                $"sha256={descriptor.Sha256} pinnedKey={keyPair.PublicKeyBase64} " +
                "verified=appcast,json)");
            return 0;
        }
        catch (Exception ex)
        {
            Console.Error.WriteLine($"generate-windows-appcast: {ex.Message}");
            return 1;
        }
    }

    private static void VerifyGeneratedFeed(
        string feedPath,
        FeedFormat format,
        string publicKeyBase64,
        byte[] artifactBytes)
    {
        var verifier = UpdateFeedVerifier.TryCreate(publicKeyBase64)
            ?? throw new InvalidDataException("Generated update-feed public key is invalid.");
        var feedText = File.ReadAllText(feedPath);
        var manifest = format switch
        {
            FeedFormat.Appcast => AppcastFeedReader.TryParse(feedText),
            FeedFormat.Json => JsonFeedReader.TryParse(feedText),
            _ => null,
        };
        if (manifest is null)
        {
            throw new InvalidDataException($"Generated {format} feed could not be parsed.");
        }

        var verification = verifier.VerifyArtifact(manifest, artifactBytes);
        if (!verification.Verified)
        {
            throw new InvalidDataException(
                $"Generated {format} feed failed artifact verification: {verification.Reason}.");
        }
    }

    private static Ed25519UpdateKeyPair LoadKeyPair(IReadOnlyDictionary<string, string> options)
    {
        if (options.TryGetValue("ed-seed-base64-env", out var seedEnvironmentVariable))
        {
            var encodedSeed = Environment.GetEnvironmentVariable(seedEnvironmentVariable);
            if (string.IsNullOrWhiteSpace(encodedSeed))
            {
                throw new ArgumentException(
                    $"Environment variable {seedEnvironmentVariable} is empty.");
            }

            byte[] decodedSeed;
            try
            {
                decodedSeed = Convert.FromBase64String(encodedSeed.Trim());
            }
            catch (FormatException)
            {
                throw new ArgumentException(
                    $"Environment variable {seedEnvironmentVariable} must contain a base64 Ed25519 seed.");
            }

            if (decodedSeed.Length != Ed25519Sizes.KeySize)
            {
                throw new ArgumentException(
                    $"Environment variable {seedEnvironmentVariable} must decode to exactly 32 bytes.");
            }

            return Ed25519UpdateKeyPair.FromSeed(decodedSeed);
        }

        var seedHex = options.GetValueOrDefault("ed-seed");
        if (seedHex is null && options.TryGetValue("ed-seed-file", out var seedFile))
        {
            seedHex = File.ReadAllText(seedFile).Trim();
        }

        if (string.IsNullOrWhiteSpace(seedHex))
        {
            throw new ArgumentException(
                "Missing --ed-seed-base64-env, --ed-seed, or --ed-seed-file.");
        }

        byte[] seed;
        try
        {
            seed = Convert.FromHexString(seedHex.Trim());
        }
        catch (FormatException)
        {
            throw new ArgumentException("--ed-seed must be 64 hex chars (a 32-byte Ed25519 seed).");
        }

        if (seed.Length != Ed25519Sizes.KeySize)
        {
            throw new ArgumentException("--ed-seed must decode to exactly 32 bytes.");
        }

        return Ed25519UpdateKeyPair.FromSeed(seed);
    }

    private static Dictionary<string, string> ParseArgs(string[] args)
    {
        var flagsWithoutValue = new HashSet<string>(StringComparer.Ordinal) { "critical" };
        var result = new Dictionary<string, string>(StringComparer.Ordinal);
        for (var i = 0; i < args.Length; i++)
        {
            var name = args[i];
            if (!name.StartsWith("--", StringComparison.Ordinal))
            {
                throw new ArgumentException($"Unexpected argument: {name}");
            }

            var key = name[2..];
            if (flagsWithoutValue.Contains(key))
            {
                result[key] = "true";
                continue;
            }

            if (i + 1 >= args.Length || args[i + 1].StartsWith("--", StringComparison.Ordinal))
            {
                throw new ArgumentException($"Missing value for --{key}");
            }

            result[key] = args[++i];
        }

        return result;
    }

    private static string Require(IReadOnlyDictionary<string, string> options, string key)
    {
        if (!options.TryGetValue(key, out var value) || string.IsNullOrWhiteSpace(value))
        {
            throw new ArgumentException($"Missing required argument --{key}");
        }

        return value;
    }
}
