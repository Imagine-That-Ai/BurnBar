import Foundation

// MARK: - SendableFileSystem

/// A `Sendable` abstraction over the filesystem operations OpenBurnBar performs.
///
/// `FileManager` is documented as safe for concurrent use, but Foundation does
/// not (yet) mark it `Sendable`, so any type that stores a `FileManager` is
/// forced to declare `@unchecked Sendable`. This protocol replaces that escape
/// hatch with a genuine, compiler-verified `Sendable` seam: production code holds
/// a `any SendableFileSystem` (defaulting to `DefaultSendableFileSystem`, which
/// forwards to `FileManager.default`), and tests inject an in-memory double.
///
/// Only the operations actually used across the codebase are exposed; every one
/// is a stat/read/write/delete syscall documented as thread-safe.
public protocol SendableFileSystem: Sendable {
    /// The temporary directory for the current user.
    var temporaryDirectory: URL { get }

    /// The home directory for the current user.
    var homeDirectoryForCurrentUser: URL { get }

    /// Whether a file or directory exists at `path`.
    func fileExists(atPath path: String) -> Bool

    /// Whether a file or directory exists at `path`, reporting directory-ness.
    func fileExists(atPath path: String, isDirectory: inout ObjCBool) -> Bool

    /// Creates a directory, optionally creating intermediate directories.
    func createDirectory(
        at url: URL,
        withIntermediateDirectories createIntermediates: Bool,
        attributes: [FileAttributeKey: Any]?
    ) throws

    /// Removes the file or directory at `url`.
    func removeItem(at url: URL) throws

    /// Sets attributes on the item at `path`.
    func setAttributes(
        _ attributes: [FileAttributeKey: Any],
        ofItemAtPath path: String
    ) throws

    /// Returns the attributes of the item at `path`.
    func attributesOfItem(atPath path: String) throws -> [FileAttributeKey: Any]

    /// A directory enumerator rooted at `url`.
    func enumerator(
        at url: URL,
        includingPropertiesForKeys keys: [URLResourceKey]?,
        options mask: FileManager.DirectoryEnumerationOptions
    ) -> FileManager.DirectoryEnumerator?
}

extension SendableFileSystem {
    /// Convenience: create a directory with no explicit attributes.
    public func createDirectory(
        at url: URL,
        withIntermediateDirectories createIntermediates: Bool
    ) throws {
        try createDirectory(
            at: url,
            withIntermediateDirectories: createIntermediates,
            attributes: nil
        )
    }
}

// MARK: - DefaultSendableFileSystem

/// The production `SendableFileSystem`, forwarding to `FileManager.default`.
///
/// `FileManager.default` is a thread-safe shared instance, so this struct is
/// genuinely `Sendable` — it carries no mutable state.
public struct DefaultSendableFileSystem: SendableFileSystem {
    public init() {}

    private var fileManager: FileManager { .default }

    public var temporaryDirectory: URL { fileManager.temporaryDirectory }

    public var homeDirectoryForCurrentUser: URL {
        URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
    }

    public func fileExists(atPath path: String) -> Bool {
        fileManager.fileExists(atPath: path)
    }

    public func fileExists(atPath path: String, isDirectory: inout ObjCBool) -> Bool {
        fileManager.fileExists(atPath: path, isDirectory: &isDirectory)
    }

    public func createDirectory(
        at url: URL,
        withIntermediateDirectories createIntermediates: Bool,
        attributes: [FileAttributeKey: Any]?
    ) throws {
        try fileManager.createDirectory(
            at: url,
            withIntermediateDirectories: createIntermediates,
            attributes: attributes
        )
    }

    public func removeItem(at url: URL) throws {
        try fileManager.removeItem(at: url)
    }

    public func setAttributes(
        _ attributes: [FileAttributeKey: Any],
        ofItemAtPath path: String
    ) throws {
        try fileManager.setAttributes(attributes, ofItemAtPath: path)
    }

    public func attributesOfItem(atPath path: String) throws -> [FileAttributeKey: Any] {
        try fileManager.attributesOfItem(atPath: path)
    }

    public func enumerator(
        at url: URL,
        includingPropertiesForKeys keys: [URLResourceKey]?,
        options mask: FileManager.DirectoryEnumerationOptions
    ) -> FileManager.DirectoryEnumerator? {
        fileManager.enumerator(at: url, includingPropertiesForKeys: keys, options: mask)
    }
}
