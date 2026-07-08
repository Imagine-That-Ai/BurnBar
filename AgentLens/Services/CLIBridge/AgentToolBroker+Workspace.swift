import CryptoKit
import Foundation
import os
import OSLog
#if canImport(Darwin)
import Darwin
#endif
import OpenBurnBarCore
import OpenBurnBarComputerUseCore

extension AgentToolBroker {
    private enum WorkspaceAccessMode {
        case read
        case write
    }

    func readWorkspaceFile(arguments: [String: Any]) throws -> AgentToolExecutionPayload {
        let path = try requiredString("path", in: arguments)
        let url = try workspaceFileURL(path, mode: .read)
        let data = try Data(contentsOf: url)
        let text = String(decoding: data.prefix(200_000), as: UTF8.self)
        return jsonPayload([
            "ok": true,
            "path": path,
            "truncated": data.count > 200_000,
            "content": text
        ], detail: path)
    }

    func listWorkspaceFiles(arguments: [String: Any]) throws -> AgentToolExecutionPayload {
        let path = (arguments["path"] as? String) ?? "."
        let limit = max(1, min((arguments["limit"] as? Int) ?? 200, 500))
        let root = try workspaceFileURL(path, mode: .read)
        var rows: [[String: Any]] = []
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .fileSizeKey]
        if let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: Array(keys)) {
            for case let fileURL as URL in enumerator {
                let values = try? fileURL.resourceValues(forKeys: keys) // try?-ok(metadata skip fallback)
                rows.append([
                    "path": relativeWorkspacePath(for: fileURL),
                    "isDirectory": values?.isDirectory ?? false,
                    "sizeBytes": values?.fileSize ?? 0
                ])
                if rows.count >= limit { break }
            }
        }
        return jsonPayload(["ok": true, "root": path, "files": rows], detail: "\(rows.count) files")
    }

    func writeWorkspaceFile(arguments: [String: Any]) throws -> AgentToolExecutionPayload {
        let path = try requiredString("path", in: arguments)
        guard let content = arguments["content"] as? String else {
            throw NSError(domain: "AgentToolBroker", code: 3, userInfo: [NSLocalizedDescriptionKey: "Missing required string: content"])
        }
        let append = (arguments["append"] as? Bool) ?? false
        let url = try workspaceFileURL(path, mode: .write)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let data = Data(content.utf8)
        if append, FileManager.default.fileExists(atPath: url.path) {
            let handle = try FileHandle(forWritingTo: url)
            defer { try? handle.close() } // try?-ok(handle teardown)
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
        } else {
            try data.write(to: url, options: [.atomic])
        }
        return jsonPayload(["ok": true, "path": path, "bytesWritten": data.count], detail: path)
    }

    func exportDesktopFile(arguments: [String: Any]) throws -> AgentToolExecutionPayload {
        let sourcePath = try requiredString("sourcePath", in: arguments)
        let sourceURL = try workspaceFileURL(sourcePath, mode: .read)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: sourceURL.path, isDirectory: &isDirectory),
              !isDirectory.boolValue else {
            throw NSError(domain: "AgentToolBroker", code: 6, userInfo: [NSLocalizedDescriptionKey: "Source file does not exist or is a directory"])
        }

        let requestedName = (arguments["targetName"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let filename = Self.safeDesktopFilename(requestedName?.nonEmpty ?? sourceURL.lastPathComponent)
        let safeThread = Self.safeDesktopFilename(grant.threadID)
        let dropDirectory = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Desktop", isDirectory: true)
            .appendingPathComponent("OpenBurnBar Agent Drops", isDirectory: true)
            .appendingPathComponent(safeThread, isDirectory: true)
        try FileManager.default.createDirectory(at: dropDirectory, withIntermediateDirectories: true)
        let destinationURL = dropDirectory.appendingPathComponent(filename, isDirectory: false)
        if FileManager.default.fileExists(atPath: destinationURL.path) {
            try FileManager.default.removeItem(at: destinationURL)
        }
        try FileManager.default.copyItem(at: sourceURL, to: destinationURL)
        return jsonPayload([
            "ok": true,
            "sourcePath": sourcePath,
            "desktopPath": destinationURL.path,
            "bytesCopied": (try? destinationURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0 // try?-ok(byte count fallback)
        ], detail: destinationURL.path)
    }

    private func workspaceFileURL(_ relativePath: String, mode: WorkspaceAccessMode) throws -> URL {
        let trimmed = relativePath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("/") else {
            throw NSError(domain: "AgentToolBroker", code: 1, userInfo: [NSLocalizedDescriptionKey: "Path must be workspace-relative"])
        }
        let candidate = workspaceURL.appendingPathComponent(trimmed).standardizedFileURL
        guard isInsideWorkspace(candidate) else {
            throw NSError(domain: "AgentToolBroker", code: 2, userInfo: [NSLocalizedDescriptionKey: "Path escapes the chat workspace"])
        }
        switch mode {
        case .read:
            let resolved = Self.canonicalFileURL(candidate)
            guard isInsideWorkspace(resolved) else {
                throw NSError(domain: "AgentToolBroker", code: 2, userInfo: [NSLocalizedDescriptionKey: "Path escapes the chat workspace"])
            }
            return resolved
        case .write:
            if FileManager.default.fileExists(atPath: candidate.path) {
                let resolved = Self.canonicalFileURL(candidate)
                guard isInsideWorkspace(resolved) else {
                    throw NSError(domain: "AgentToolBroker", code: 2, userInfo: [NSLocalizedDescriptionKey: "Path escapes the chat workspace"])
                }
                return resolved
            }

            let nearestAncestor = nearestExistingAncestor(for: candidate.deletingLastPathComponent())
            let resolvedAncestor = Self.canonicalFileURL(nearestAncestor)
            guard isInsideWorkspace(resolvedAncestor) else {
                throw NSError(domain: "AgentToolBroker", code: 2, userInfo: [NSLocalizedDescriptionKey: "Path escapes the chat workspace"])
            }
            return candidate
        }
    }

    private func relativeWorkspacePath(for url: URL) -> String {
        let root = workspaceURL.path.hasSuffix("/") ? workspaceURL.path : workspaceURL.path + "/"
        guard url.path.hasPrefix(root) else { return url.lastPathComponent }
        return String(url.path.dropFirst(root.count))
    }

    private func isInsideWorkspace(_ url: URL) -> Bool {
        let rootPath = workspaceURL.path.hasSuffix("/") ? workspaceURL.path : workspaceURL.path + "/"
        return url.path == workspaceURL.path || url.path.hasPrefix(rootPath)
    }

    private func nearestExistingAncestor(for url: URL) -> URL {
        var current = url.standardizedFileURL
        while !FileManager.default.fileExists(atPath: current.path) {
            let parent = current.deletingLastPathComponent()
            if parent.path == current.path {
                return workspaceURL
            }
            current = parent
        }
        return current
    }

    func requiredString(_ key: String, in object: [String: Any]) throws -> String {
        guard let value = object[key] as? String, !value.isEmpty else {
            throw NSError(domain: "AgentToolBroker", code: 3, userInfo: [NSLocalizedDescriptionKey: "Missing required string: \(key)"])
        }
        return value
    }

    /// Human-readable, one-line description of a privileged tool call, shown to
    /// the operator in the approval prompt so consent is informed (not blind).
    static func approvalSummary(tool: String, arguments: [String: Any]) -> String {
        switch tool {
        case "shell_run":
            let command = (arguments["command"] as? String) ?? "(missing command)"
            return "Run shell command: \(command)"
        case "workspace_write_file":
            let path = (arguments["path"] as? String) ?? "(missing path)"
            let append = (arguments["append"] as? Bool) ?? false
            return "\(append ? "Append to" : "Write") workspace file: \(path)"
        case "desktop_export_file":
            let source = (arguments["sourcePath"] as? String) ?? "(missing source)"
            return "Export \(source) to your Desktop"
        default:
            return tool
        }
    }

    func denied(name: String, reason: String) -> AgentToolExecutionPayload {
        jsonPayload(["ok": false, "tool": name, "status": "denied", "reason": reason], detail: reason)
    }

    func errorPayload(name: String, error: String) -> AgentToolExecutionPayload {
        jsonPayload(["ok": false, "tool": name, "status": "error", "error": error], detail: error)
    }

    func jsonPayload(_ object: [String: Any], detail: String?) -> AgentToolExecutionPayload {
        let data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) // try?-ok(JSON encode fallback)
            ?? Data("{}".utf8)
        return AgentToolExecutionPayload(content: String(decoding: data, as: UTF8.self), detail: detail)
    }
    private static func safeDesktopFilename(_ value: String) -> String {
        let invalid = CharacterSet(charactersIn: "/:\\").union(.newlines)
        let components = value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .components(separatedBy: invalid)
            .filter { !$0.isEmpty }
        let joined = components.joined(separator: "-")
        let clipped = String(joined.prefix(96)).trimmingCharacters(in: .whitespacesAndNewlines)
        return clipped.nonEmpty ?? "agent-file"
    }
}
