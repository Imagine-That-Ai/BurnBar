using System;
using System.Collections.Generic;
using System.Security.Cryptography;
using OpenBurnBar.App.CloudSync.Pensieve;
using OpenBurnBar.App.Configuration;
using OpenBurnBar.App.Diagnostics;

namespace OpenBurnBar.App;

public partial class App
{
    private PensieveKnowledgeWatcher? _pensieveKnowledgeWatcher;

    private void StartPensieveKnowledgeWatcher()
    {
        try
        {
            IReadOnlyList<PensieveWatchRoot> roots = PensieveKnowledgeWatcher.StandardRoots(
                Environment.GetEnvironmentVariable(PensieveKnowledgeWatcher.RepoDocsEnvironmentVariable),
                Environment.GetEnvironmentVariable(PensieveKnowledgeWatcher.NotesEnvironmentVariable));
            var watcher = new PensieveKnowledgeWatcher(
                roots,
                PensieveKnowledgeWatcher.DefaultQueueDirectory(),
                LoadPensieveVaultKey,
                errorSink: exception => AppDiagnostics.LogException("pensieve-watcher", exception));
            watcher.Start();
            _pensieveKnowledgeWatcher = watcher;
            byte[]? keyProbe = LoadPensieveVaultKey();
            bool vaultKeyPresent = keyProbe is not null;
            if (keyProbe is not null)
            {
                CryptographicOperations.ZeroMemory(keyProbe);
            }
            AppDiagnostics.LogEvent(
                "pensieve-watcher.configured",
                $"roots={roots.Count} vault_key_present={vaultKeyPresent}");
        }
        catch (Exception exception)
        {
            AppDiagnostics.LogException("pensieve-watcher.start", exception);
            _pensieveKnowledgeWatcher = null;
        }
    }

    private static byte[]? LoadPensieveVaultKey()
    {
        try
        {
            string? encoded = AppConfiguration.Current.EffectiveVaultKeyB64();
            if (string.IsNullOrWhiteSpace(encoded))
            {
                return null;
            }
            byte[] key = Convert.FromBase64String(encoded);
            if (key.Length == 32)
            {
                return key;
            }
            CryptographicOperations.ZeroMemory(key);
            return null;
        }
        catch (Exception exception) when (exception is FormatException or SecretStoreException)
        {
            return null;
        }
    }
}
