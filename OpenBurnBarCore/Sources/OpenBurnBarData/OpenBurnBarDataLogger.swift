import Foundation

struct AppLogger: Sendable {
    static let dataStore = AppLogger(category: "data")

    let category: String

    func debug(_ message: String, metadata: [String: String] = [:]) {
        log(level: "debug", message: message, metadata: metadata)
    }

    func info(_ message: String, metadata: [String: String] = [:]) {
        log(level: "info", message: message, metadata: metadata)
    }

    func notice(_ message: String, metadata: [String: String] = [:]) {
        log(level: "notice", message: message, metadata: metadata)
    }

    func error(_ message: String, metadata: [String: String] = [:]) {
        log(level: "error", message: message, metadata: metadata)
    }

    func silentFailure(_ message: String, error: Error, context: [String: String] = [:]) {
        var metadata = context
        metadata["error"] = String(describing: error)
        log(level: "error", message: message, metadata: metadata)
    }

    private func log(level: String, message: String, metadata: [String: String]) {
        let suffix = metadata.isEmpty
            ? ""
            : " " + metadata.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: " ")
        FileHandle.standardError.write(Data("[OpenBurnBarData:\(category):\(level)] \(message)\(suffix)\n".utf8))
    }
}
