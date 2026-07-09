// SPDX-License-Identifier: AGPL-3.0-only
//
// K1 kernel extraction: the pure catalog model types moved to
// `OpenBurnBarKernel/OpenBurnBarCatalog.swift`. This loader stays in
// OpenBurnBarCore because `Bundle.module` here resolves to
// `OpenBurnBarCore_OpenBurnBarCore.bundle` (which carries `catalog.json`) —
// the exact bundle name the AgentLens daemon installer stages at runtime.

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
