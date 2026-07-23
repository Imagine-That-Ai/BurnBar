// SPDX-License-Identifier: AGPL-3.0-only
//
// K1 kernel extraction: the pure catalog model types moved to
// `OpenBurnBarCatalog.swift`. K2 (Phase-2 WS-K) carried this loader AND the
// `Resources/` bundle (catalog.json + secret-pattern-corpus.json) into
// OpenBurnBarKernelModels, so `Bundle.module` here now resolves to
// `OpenBurnBarCore_OpenBurnBarKernelModels.bundle` (the SwiftPM
// `<package>_<target>` bundle that carries `catalog.json`). The AgentLens daemon
// installer stages that new bundle name IN ADDITION to the old
// `OpenBurnBarCore_OpenBurnBarKernel.bundle` during the K2 transition.

import Foundation

public enum BurnBarCatalogLoader {
    public static let bundledCatalog: BurnBarCatalog = {
        do {
            return try loadBundledCatalog()
        } catch {
            assertionFailure("Failed to load bundled OpenBurnBar catalog: \(error)")
            return BurnBarCatalog(schemaVersion: 1, providers: [])
        }
    }()

    public static func loadBundledCatalog() throws -> BurnBarCatalog {
        guard let url = Bundle.module.url(forResource: "catalog", withExtension: "json") else {
            throw BurnBarCatalogError.missingBundledCatalog
        }
        let data = try Data(contentsOf: url)
        return try decode(data)
    }

    public static func decode(_ data: Data) throws -> BurnBarCatalog {
        let decoder = JSONDecoder()
        let catalog = try decoder.decode(BurnBarCatalog.self, from: data)
        try catalog.validate()
        return catalog
    }
}
