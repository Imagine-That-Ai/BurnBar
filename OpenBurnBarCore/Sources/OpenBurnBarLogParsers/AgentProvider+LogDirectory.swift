import Foundation
import OpenBurnBarKernel
import OpenBurnBarParserSupport

// MARK: - Provider log-directory resolution (Windows-buildable Engine seam)
//
// Windows-port Phase-2 (G2 parser lift, `docs/WINDOWS_PORT_MASTER_PLAN.md`).
//
// `logDirectory` was a macOS-app extension on the Engine's
// `AgentProvider`. The lifted log parsers read `provider.logDirectory` to locate a
// provider's session logs, so the accessor remains beside the parsers. The logical
// path comes from the generated provider-ingestion catalog: Linux receives its XDG
// form, macOS its Application Support form, and Windows remaps the macOS form through
// `LogPathPlatform` to `%USERPROFILE%`/`%APPDATA%`/`%LOCALAPPDATA%`.
public extension AgentProvider {
    /// Filesystem directory where the provider writes session logs the file
    /// watcher can scrape, resolved for the current host.
    var logDirectory: String {
        LogPathPlatform.resolveLogDirectory(logDirectoryPlatformForm)
    }

    /// One generated catalog owns the path used by both discovery and parser
    /// registration. Windows continues to remap the macOS logical form.
    private var logDirectoryPlatformForm: String {
        let entry = OpenBurnBarParserSupport.AgentProviderIngestionCatalog.entry(for: self)
        #if os(Linux)
        return entry.linuxLogicalPath
        #else
        return entry.macOSLogicalPath
        #endif
    }
}
