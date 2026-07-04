import Foundation

extension Foundation.Bundle {
    static let module: Bundle = {
        let mainPath = Bundle.main.bundleURL.appendingPathComponent("OpenBurnBarCore_OpenBurnBarCore.resources").path
        let buildPath = "/workspace/OpenBurnBarCore/.build-linux-security/aarch64-unknown-linux-gnu/debug/OpenBurnBarCore_OpenBurnBarCore.resources"

        let preferredBundle = Bundle(path: mainPath)

        guard let bundle = preferredBundle ?? Bundle(path: buildPath) else {
            // Users can write a function called fatalError themselves, we should be resilient against that.
            Swift.fatalError("could not load resource bundle: from \(mainPath) or \(buildPath)")
        }

        return bundle
    }()
}